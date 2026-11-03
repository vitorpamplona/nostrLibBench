//! What every binary of the Zig harness shares: the HARNESS.md flags, the manifest, the
//! client table, the per-run recorder and the run loop a child process drives.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const harness_id = "zig";

// ---------------------------------------------------------------------------------------------
// Clients. The driver only needs this table (no library code), so it lives here.
// ---------------------------------------------------------------------------------------------

pub const Verify = enum { library, explicit, harness };

pub const ClientMeta = struct {
    id: []const u8,
    /// Executable (next to the driver) that implements the client.
    binary: []const u8,
    library: []const u8,
    version: []const u8,
    license: []const u8,
    api: []const u8,
    websocket: []const u8,
    crypto: []const u8,
    verify: Verify,
    notes: []const u8,
    variant: bool,
};

const zig_nostr_ws = "zig-nostr's own RFC 6455 client (relay.Connection over std.Io.net TCP; std.crypto.tls for wss)";
const zig_nostr_crypto = "libsecp256k1 0.7.1 (C, bitcoin-core commit 1a53f496, compiled from source by the package)";
const libnostr_z_ws = "libnostr-z's own RFC 6455 client (src/ws: blocking posix reads, OpenSSL for wss)";
const libnostr_z_crypto = "libsecp256k1 0.2.0 (C, Ubuntu libsecp256k1-dev, static) via noscrypt 0.1.14 NCVerifyDigest; SHA-256 by StringZilla 4.5.1";

pub const clients = [_]ClientMeta{
    .{
        .id = "zig-nostr-relay",
        .binary = "libbench-zignostr",
        .library = "zig-nostr/nostr",
        .version = "0.16.0",
        .license = "MIT",
        .api = "nostr.relay.dial + Relay.subscribe + Relay.receiveTimeout loop (one relay)",
        .websocket = zig_nostr_ws,
        .crypto = zig_nostr_crypto,
        .verify = .explicit,
        .notes = "Parsing does not verify (ARCHITECTURE.md); the harness calls nostr.event.verify (recomputes the id with event.computeId, then BIP-340 via keys.Signer) on every delivered event, as the library's README and skill tell apps to. Events whose JSON the parser rejects (the \"sig\":\"\" rumors) are skipped by Relay.receive and counted in Relay.unreadable(). One keys.Signer (secp256k1 context) per run, created in setup.",
        .variant = false,
    },
    .{
        .id = "libnostr-z-relay",
        .binary = "libbench-libnostrz",
        .library = "privkeyio/libnostr-z",
        .version = "0.5.0",
        .license = "MIT",
        .api = "nostr.relay.Relay.init/connect + Relay.subscribe + Relay.receive loop (one relay)",
        .websocket = libnostr_z_ws,
        .crypto = libnostr_z_crypto,
        .verify = .explicit,
        .notes = "Relay.receive parses but does not verify; the harness calls Event.validate (id check, then noscrypt NCVerifyDigest; also rejects created_at > now+900 s) on every delivered event, as the noz CLI does. auto_reconnect off; read_timeout_ms (SO_RCVTIMEO, default 60 s) raised to --timeout-ms. Event.validate hashes the RAW JSON text of tags and content as the relay sent it instead of re-serializing the decoded fields, so every valid event whose JSON uses escapes the canonical form does not (\\uD83C surrogate pairs, \\u2019, \\/) fails IdMismatch and is dropped (82 of 994 valid events on smoke): accepted_ok is false. The Event is lazy (offsets into the raw JSON; content/tags decoded on access). Relay.receive also parses every message twice with std.json.Value besides the event scanner.",
        .variant = false,
    },
    .{
        .id = "libnostr-z-pool-query",
        .binary = "libbench-libnostrz",
        .library = "privkeyio/libnostr-z",
        .version = "0.5.0",
        .license = "MIT",
        .api = "nostr.pool.Pool + Pool.queryParallel (fetch-all: returns []Event after EOSE; one relay)",
        .websocket = libnostr_z_ws,
        .crypto = libnostr_z_crypto,
        .verify = .explicit,
        .notes = "Variant: fetch-all API. A reader thread per relay (the library's own) parses each event for dedup and queues the raw message; queryParallel parses it again into an Event and returns the list after EOSE; the harness then calls Event.validate on each (inside the timed part), so it shares libnostr-z-relay's IdMismatch on escaped JSON. PoolOptions.queue_size raised from 10000 to the workload size (a full queue silently drops its oldest message). Setup sets a 200 ms SO_RCVTIMEO on the pool's socket (RelayHandle.client.setReadTimeout, public API): with the default (none) the reader thread stays blocked in read() once the relay is quiet after EOSE, and queryParallel (stopReceiving) and Pool.deinit join it forever. The consumer side polls the queue with 1 ms sleeps.",
        .variant = true,
    },
};

pub fn findClient(id: []const u8) ?*const ClientMeta {
    for (&clients) |*c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

// ---------------------------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------------------------

pub const Settings = struct {
    relay: []const u8 = "ws://127.0.0.1:7777",
    corpus: []const u8 = ".corpus",
    out: []const u8 = "results/zig.json",
    workloads: ?[]const u8 = null,
    clients: ?[]const u8 = null,
    warmup_runs: u32 = 2,
    min_runs: u32 = 5,
    min_time_ms: u64 = 10000,
    max_runs: u32 = 30,
    timeout_ms: u64 = 300000,
    list: bool = false,
    /// Child mode: run this one client on `workload` and print its row as JSON on stdout.
    child: ?[]const u8 = null,
    workload: ?[]const u8 = null,
};

pub fn parseArgs(args: []const [:0]const u8) !Settings {
    var s: Settings = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var name: []const u8 = args[i];
        var inline_val: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            inline_val = name[eq + 1 ..];
            name = name[0..eq];
        }
        if (std.mem.eql(u8, name, "--quick")) {
            s.warmup_runs = 1;
            s.min_runs = 2;
            s.min_time_ms = 0;
            continue;
        }
        if (std.mem.eql(u8, name, "--list")) {
            s.list = true;
            continue;
        }
        const val: []const u8 = inline_val orelse blk: {
            i += 1;
            if (i >= args.len) {
                std.debug.print("zig: {s} needs a value\n", .{name});
                return error.BadArgs;
            }
            break :blk args[i];
        };
        if (std.mem.eql(u8, name, "--relay")) {
            s.relay = std.mem.trimEnd(u8, val, "/");
        } else if (std.mem.eql(u8, name, "--corpus")) {
            s.corpus = val;
        } else if (std.mem.eql(u8, name, "--out")) {
            s.out = val;
        } else if (std.mem.eql(u8, name, "--workloads")) {
            s.workloads = val;
        } else if (std.mem.eql(u8, name, "--clients")) {
            s.clients = val;
        } else if (std.mem.eql(u8, name, "--warmup-runs")) {
            s.warmup_runs = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, name, "--min-runs")) {
            s.min_runs = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, name, "--min-time-ms")) {
            s.min_time_ms = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, name, "--max-runs")) {
            s.max_runs = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            s.timeout_ms = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, name, "--child")) {
            s.child = val;
        } else if (std.mem.eql(u8, name, "--workload")) {
            s.workload = val;
        } else {
            std.debug.print("zig: unknown flag {s}\n", .{name});
            return error.BadArgs;
        }
    }
    if (s.max_runs < s.min_runs) s.max_runs = s.min_runs;
    return s;
}

// ---------------------------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------------------------

pub const Workload = struct {
    name: []const u8,
    events: u64,
    bytes: u64,
    valid_events: u64,
    valid_id_xor: [32]u8,
    ambiguous_ids: []const [32]u8,
    expired_ids: []const [32]u8,
};

pub const Manifest = struct {
    fingerprint: []const u8,
    workloads: []const Workload,

    pub fn find(m: Manifest, name: []const u8) ?Workload {
        for (m.workloads) |w| if (std.mem.eql(u8, w.name, name)) return w;
        return null;
    }
};

fn hex32(s: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (s.len != 64) return error.BadHex;
    _ = try std.fmt.hexToBytes(&out, s);
    return out;
}

fn idList(arena: Allocator, v: ?std.json.Value) ![]const [32]u8 {
    const arr = (v orelse return &.{}).array.items;
    const out = try arena.alloc([32]u8, arr.len);
    for (arr, 0..) |x, i| out[i] = try hex32(x.string);
    return out;
}

/// Reads `<corpus>/manifest.json`; everything is allocated in `arena`.
pub fn loadManifest(arena: Allocator, io: Io, corpus: []const u8) !Manifest {
    const path = try std.fs.path.join(arena, &.{ corpus, "manifest.json" });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const obj = root.object;
    const ws = obj.get("workloads").?.array.items;
    const out = try arena.alloc(Workload, ws.len);
    for (ws, 0..) |w, i| {
        const o = w.object;
        out[i] = .{
            .name = o.get("name").?.string,
            .events = @intCast(o.get("events").?.integer),
            .bytes = @intCast(o.get("bytes").?.integer),
            .valid_events = @intCast(o.get("valid_events").?.integer),
            .valid_id_xor = try hex32(o.get("valid_id_xor").?.string),
            .ambiguous_ids = try idList(arena, o.get("ambiguous_ids")),
            .expired_ids = try idList(arena, o.get("expired_ids")),
        };
    }
    return .{ .fingerprint = obj.get("fingerprint").?.string, .workloads = out };
}

// ---------------------------------------------------------------------------------------------
// Output row (HARNESS.md "Output"); field order is the JSON key order.
// ---------------------------------------------------------------------------------------------

pub const Row = struct {
    client: []const u8,
    library: []const u8,
    version: []const u8,
    license: []const u8,
    api: []const u8,
    websocket: []const u8,
    crypto: []const u8,
    verify: []const u8,
    notes: []const u8,
    variant: bool,
    workload: []const u8,
    events: u64,
    bytes: u64,
    accepted: ?u64 = null,
    accepted_xor: ?[]const u8 = null,
    ambiguous_accepted: ?u64 = null,
    expired_accepted: ?u64 = null,
    accepted_ok: bool = false,
    errors: u64 = 0,
    @"error": ?[]const u8 = null,
    warmup_runs: u32 = 0,
    runs: u32 = 0,
    first_run_ms: ?f64 = null,
    median_ms: ?f64 = null,
    min_ms: ?f64 = null,
    p90_ms: ?f64 = null,
    run_ms: []const f64 = &.{},
    events_per_s: ?f64 = null,
    us_per_event: ?f64 = null,
    cpu_ms: ?f64 = null,
    peak_rss_mb: ?f64 = null,

    pub fn init(meta: *const ClientMeta, w: Workload) Row {
        return .{
            .client = meta.id,
            .library = meta.library,
            .version = meta.version,
            .license = meta.license,
            .api = meta.api,
            .websocket = meta.websocket,
            .crypto = meta.crypto,
            .verify = @tagName(meta.verify),
            .notes = meta.notes,
            .variant = meta.variant,
            .workload = w.name,
            .events = w.events,
            .bytes = w.bytes,
        };
    }
};

// ---------------------------------------------------------------------------------------------
// Clocks
// ---------------------------------------------------------------------------------------------

/// Monotonic nanoseconds (CLOCK_MONOTONIC via std.Io's awake clock).
pub inline fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).toNanoseconds();
}

/// Process CPU time, user + system, all threads, in microseconds (getrusage RUSAGE_SELF).
pub fn cpuUs() i64 {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    return @as(i64, ru.utime.sec + ru.stime.sec) * 1_000_000 + ru.utime.usec + ru.stime.usec;
}

/// Peak resident set of this process in MiB (ru_maxrss is KiB on Linux).
pub fn peakRssMb() f64 {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    return @as(f64, @floatFromInt(ru.maxrss)) / 1024.0;
}

// ---------------------------------------------------------------------------------------------
// One run
// ---------------------------------------------------------------------------------------------

/// What a client calls during one run: `begin` right before the library's subscription call,
/// `accept` for every event the library delivered and that passed verification, `eose` when the
/// library hands the app the EOSE.
pub const Recorder = struct {
    io: Io,
    timeout_ns: i96,
    t0: i96 = 0,
    deadline: i96 = 0,
    cpu0: i64 = 0,
    cpu_end: i64 = 0,
    last_ns: i96 = 0,
    eose_ns: ?i96 = null,
    count: u64 = 0,
    xor: @Vector(32, u8) = @splat(0),
    gpa: Allocator,
    ids: std.ArrayList([32]u8),

    pub fn init(gpa: Allocator, io: Io, timeout_ms: u64, capacity: usize) !Recorder {
        return .{
            .io = io,
            .gpa = gpa,
            .timeout_ns = @as(i96, timeout_ms) * std.time.ns_per_ms,
            .ids = try .initCapacity(gpa, capacity + 16),
        };
    }

    pub fn deinit(r: *Recorder) void {
        r.ids.deinit(r.gpa);
    }

    pub fn begin(r: *Recorder) void {
        r.cpu0 = cpuUs();
        r.t0 = nowNs(r.io);
        r.deadline = r.t0 + r.timeout_ns;
        r.last_ns = r.t0;
    }

    pub inline fn accept(r: *Recorder, id: *const [32]u8) void {
        r.count += 1;
        r.xor ^= @as(@Vector(32, u8), id.*);
        r.ids.append(r.gpa, id.*) catch {}; // capacity is reserved; a failure only loses the id list
        r.last_ns = nowNs(r.io);
    }

    pub fn eose(r: *Recorder) void {
        r.eose_ns = nowNs(r.io);
        r.cpu_end = cpuUs();
    }

    /// For clients that keep delivering after EOSE: call after the last event.
    pub fn end(r: *Recorder) void {
        r.cpu_end = cpuUs();
    }

    /// Nanoseconds left before the run's --timeout-ms deadline (<= 0: timed out).
    pub fn remainingNs(r: *const Recorder) i96 {
        return r.deadline - nowNs(r.io);
    }

    pub fn remainingTimeout(r: *const Recorder) Io.Timeout {
        const left = @max(r.remainingNs(), 1);
        return .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } };
    }

    pub fn elapsedMs(r: *const Recorder) f64 {
        const t_end = @max(r.eose_ns orelse r.last_ns, r.last_ns);
        return @as(f64, @floatFromInt(t_end - r.t0)) / 1e6;
    }

    pub fn cpuMs(r: *const Recorder) f64 {
        return @as(f64, @floatFromInt(r.cpu_end - r.cpu0)) / 1000.0;
    }
};

/// Everything a client implementation gets for one run.
pub const RunCtx = struct {
    gpa: Allocator,
    io: Io,
    /// `<relay>/<workload>`
    url: [:0]const u8,
    /// `{"limit": <events in the workload>}`
    limit: u32,
    timeout_ms: u64,
    rec: *Recorder,
};

/// A library binary's client table: `run` dispatches on the client id.
pub const RunFn = *const fn (client_id: []const u8, ctx: *RunCtx) anyerror!void;

const V = @Vector(32, u8);
const SetResult = struct { count: u64, xor: [32]u8, ambiguous: u64, expired: u64, amb_xor: V, exp_xor: V };

fn contains(list: []const [32]u8, id: [32]u8) bool {
    for (list) |x| if (std.mem.eql(u8, &x, &id)) return true;
    return false;
}

fn summarize(r: *const Recorder, w: Workload) SetResult {
    var amb: u64 = 0;
    var exp: u64 = 0;
    var amb_xor: V = @splat(0);
    var exp_xor: V = @splat(0);
    for (r.ids.items) |id| {
        if (contains(w.ambiguous_ids, id)) {
            amb += 1;
            amb_xor ^= @as(V, id);
        }
        if (contains(w.expired_ids, id)) {
            exp += 1;
            exp_xor ^= @as(V, id);
        }
    }
    return .{ .count = r.count, .xor = r.xor, .ambiguous = amb, .expired = exp, .amb_xor = amb_xor, .exp_xor = exp_xor };
}

fn hexAlloc(a: Allocator, b: [32]u8) ![]const u8 {
    const h = std.fmt.bytesToHex(b, .lower);
    return a.dupe(u8, &h);
}

fn round1(x: f64) f64 {
    return @round(x * 10.0) / 10.0;
}

fn percentile(sorted: []const f64, p: f64) f64 {
    // nearest-rank
    const n = sorted.len;
    var k: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(n))));
    if (k < 1) k = 1;
    if (k > n) k = n;
    return sorted[k - 1];
}

fn median(a: Allocator, xs: []const f64) !f64 {
    const s = try a.dupe(f64, xs);
    std.mem.sort(f64, s, {}, std.sort.asc(f64));
    const n = s.len;
    return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0;
}

/// Child mode: runs the warm-up and measured runs of one client on one workload and returns
/// its row (allocated in `arena`).
pub fn measure(arena: Allocator, gpa: Allocator, io: Io, s: Settings, meta: *const ClientMeta, w: Workload, run: RunFn) !Row {
    var row = Row.init(meta, w);
    row.warmup_runs = s.warmup_runs;

    const url = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ s.relay, w.name }, 0);
    const limit: u32 = @intCast(@min(w.events, std.math.maxInt(u32)));

    var first: ?SetResult = null;
    var times: std.ArrayList(f64) = .empty;
    var cpus: std.ArrayList(f64) = .empty;
    var measured_ns: f64 = 0;
    var total: u32 = 0;
    var failure: ?[]const u8 = null;

    while (true) : (total += 1) {
        const warm = total < s.warmup_runs;
        if (!warm) {
            const runs: u32 = @intCast(times.items.len);
            if (runs >= s.max_runs) break;
            if (runs >= s.min_runs and measured_ns >= @as(f64, @floatFromInt(s.min_time_ms)) * 1e6) break;
        }
        var rec = try Recorder.init(gpa, io, s.timeout_ms, w.events);
        defer rec.deinit();
        var ctx: RunCtx = .{ .gpa = gpa, .io = io, .url = url, .limit = limit, .timeout_ms = s.timeout_ms, .rec = &rec };
        run(meta.id, &ctx) catch |err| {
            failure = try std.fmt.allocPrint(arena, "run {d}: {s}{s}", .{
                total + 1,
                @errorName(err),
                if (err == error.Timeout) " (no EOSE within --timeout-ms)" else "",
            });
            break;
        };
        if (rec.eose_ns == null) {
            failure = try std.fmt.allocPrint(arena, "run {d}: no EOSE delivered", .{total + 1});
            break;
        }
        const ms = rec.elapsedMs();
        const res = summarize(&rec, w);
        if (first) |f| {
            if (f.count != res.count or !std.mem.eql(u8, &f.xor, &res.xor)) {
                failure = try std.fmt.allocPrint(arena, "run {d} delivered a different set than run 1 ({d} events vs {d})", .{ total + 1, res.count, f.count });
                row.errors += 1;
                break;
            }
        } else {
            first = res;
            row.first_run_ms = round1(ms);
        }
        if (!warm) {
            try times.append(arena, ms);
            try cpus.append(arena, rec.cpuMs());
            measured_ns += ms * 1e6;
        }
        std.debug.print("  {s} {s} run {d}{s}: {d:.1} ms, {d} accepted\n", .{ meta.id, w.name, total + 1, if (warm) " (warm-up)" else "", ms, res.count });
    }

    if (first) |f| {
        row.accepted = f.count;
        row.accepted_xor = try hexAlloc(arena, f.xor);
        row.ambiguous_accepted = f.ambiguous;
        row.expired_accepted = f.expired;
        // HARNESS.md "Correctness: the accepted set": valid XOR (expired it dropped) XOR (ambiguous it accepted)
        var want: V = w.valid_id_xor;
        for (w.expired_ids) |id| want ^= @as(V, id);
        want ^= f.exp_xor;
        want ^= f.amb_xor;
        const exp_ok = f.expired == 0 or f.expired == w.expired_ids.len;
        const want_count = w.valid_events - w.expired_ids.len + f.expired + f.ambiguous;
        const want_arr: [32]u8 = want;
        row.accepted_ok = exp_ok and f.count == want_count and std.mem.eql(u8, &want_arr, &f.xor);
    }

    row.runs = @intCast(times.items.len);
    row.peak_rss_mb = round1(peakRssMb());
    if (failure) |msg| {
        row.@"error" = msg;
        row.errors += 1;
        row.first_run_ms = null;
        row.accepted_ok = false;
        row.runs = 0;
        return row;
    }
    const sorted = try arena.dupe(f64, times.items);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const med = try median(arena, times.items);
    const rounded = try arena.alloc(f64, times.items.len);
    for (times.items, 0..) |t, i| rounded[i] = round1(t);
    row.run_ms = rounded;
    row.median_ms = round1(med);
    row.min_ms = round1(sorted[0]);
    row.p90_ms = round1(percentile(sorted, 0.9));
    const ev: f64 = @floatFromInt(w.events);
    row.events_per_s = round1(ev / (med / 1000.0));
    row.us_per_event = @round(med * 1000.0 / ev * 1000.0) / 1000.0;
    row.cpu_ms = round1(try median(arena, cpus.items));
    return row;
}

/// `main` of a library binary: child mode only (the driver re-executes it per client).
pub fn childMain(init: std.process.Init, run: RunFn) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const s = try parseArgs(args);
    const id = s.child orelse {
        std.debug.print("zig: this binary is started by libbench (--child <client> --workload <name>)\n", .{});
        std.process.exit(2);
    };
    const meta = findClient(id) orelse return error.UnknownClient;
    const manifest = try loadManifest(arena, io, s.corpus);
    const w = manifest.find(s.workload orelse "all") orelse return error.UnknownWorkload;
    const row = try measure(arena, init.gpa, io, s, meta, w, run);
    const json = try std.json.Stringify.valueAlloc(arena, row, .{});
    try Io.File.stdout().writeStreamingAll(io, json);
    try Io.File.stdout().writeStreamingAll(io, "\n");
}

pub fn zigRuntime() []const u8 {
    return "Zig " ++ builtin.zig_version_string ++ " (" ++ @tagName(builtin.mode) ++ ", " ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ ")";
}
