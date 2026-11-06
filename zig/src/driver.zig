//! libbench: the Zig harness driver. Parses the HARNESS.md flags, then runs every
//! (workload, client) in a fresh child process of the library binary that implements the
//! client, collects the rows they print and writes results/zig.json.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Host = struct { cpu: []const u8, cores: usize, os: []const u8 };
const SettingsOut = struct { warmup_runs: u32, min_runs: u32, min_time_ms: u64, max_runs: u32 };
const Output = struct {
    harness: []const u8,
    language: []const u8,
    runtime: []const u8,
    host: Host,
    settings: SettingsOut,
    relay: []const u8,
    corpus_fingerprint: []const u8,
    results: []const common.Row,
};

fn splitList(arena: Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |x| try out.append(arena, std.mem.trim(u8, x, " "));
    return out.items;
}

fn cpuModel(arena: Allocator, io: Io) []const u8 {
    // procfs reports size 0, so read it as a stream rather than with readFileAlloc.
    const file = Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{}) catch return "unknown";
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const text = reader.interface.allocRemaining(arena, .limited(1 << 20)) catch return "unknown";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |c| return std.mem.trim(u8, line[c + 1 ..], " \t");
        }
    }
    return "unknown";
}

fn osName(arena: Allocator) []const u8 {
    const u = std.posix.uname();
    return std.fmt.allocPrint(arena, "{s} {s}", .{ std.mem.sliceTo(&u.sysname, 0), std.mem.sliceTo(&u.release, 0) }) catch "Linux";
}

fn errorRow(arena: Allocator, meta: *const common.ClientMeta, w: common.Workload, warmup: u32, msg: []const u8) common.Row {
    var row = common.Row.init(meta, w);
    row.warmup_runs = warmup;
    row.errors = 1;
    row.@"error" = arena.dupe(u8, msg) catch "error";
    return row;
}

fn runChild(arena: Allocator, gpa: Allocator, io: Io, bin_dir: []const u8, s: common.Settings, meta: *const common.ClientMeta, w: common.Workload) common.Row {
    const exe = std.fs.path.join(arena, &.{ bin_dir, meta.binary }) catch return errorRow(arena, meta, w, s.warmup_runs, "out of memory");
    const argv = [_][]const u8{
        exe,                                                            "--child",       meta.id,
        "--workload",                                                   w.name,          "--relay",
        s.relay,                                                        "--corpus",      s.corpus,
        "--warmup-runs",                                                fmtInt(arena, s.warmup_runs), "--min-runs",
        fmtInt(arena, s.min_runs),                                      "--min-time-ms", fmtInt(arena, s.min_time_ms),
        "--max-runs",                                                   fmtInt(arena, s.max_runs), "--timeout-ms",
        fmtInt(arena, s.timeout_ms),
    };
    // The child bounds every run by --timeout-ms itself; this is the backstop for a child
    // that wedges outside a run (setup, teardown).
    const budget_ms: u64 = (s.timeout_ms + 30_000) * (@as(u64, s.warmup_runs) + s.max_runs + 1);
    const result = runCollect(gpa, io, &argv, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(@min(budget_ms, std.math.maxInt(i64)))), .clock = .awake } }) catch |err| {
        const msg = std.fmt.allocPrint(arena, "child process failed: {s}{s}", .{
            @errorName(err),
            if (err == error.Timeout) " (killed after its whole time budget)" else "",
        }) catch "child process failed";
        return errorRow(arena, meta, w, s.warmup_runs, msg);
    };
    defer gpa.free(result.stdout);

    const line = std.mem.trim(u8, result.stdout, " \r\n");
    if (line.len > 0) {
        if (std.json.parseFromSliceLeaky(common.Row, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |row| {
            return row;
        } else |_| {}
    }
    const why = switch (result.term) {
        .exited => |code| std.fmt.allocPrint(arena, "child exited with status {d} and no result row", .{code}),
        .signal => |sig| std.fmt.allocPrint(arena, "child killed by signal {d} (crash)", .{@intFromEnum(sig)}),
        else => std.fmt.allocPrint(arena, "child ended abnormally", .{}),
    } catch "child failed";
    const msg = why;
    return errorRow(arena, meta, w, s.warmup_runs, msg);
}

const Collected = struct { term: std.process.Child.Term, stdout: []u8 };

/// Like std.process.run, but the child's stderr goes straight to ours (live progress) and only
/// stdout (the row) is collected.
fn runCollect(gpa: Allocator, io: Io, argv: []const []const u8, timeout: Io.Timeout) !Collected {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(io);
    var buf: Io.File.MultiReader.Buffer(1) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, buf.toStreams(), &.{child.stdout.?});
    defer mr.deinit();
    const deadline = timeout.toDeadline(io);
    while (mr.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try mr.toOwnedSlice(0) };
}

fn fmtInt(arena: Allocator, v: anytype) []const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{v}) catch "0";
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const s = common.parseArgs(args) catch std.process.exit(2);

    if (s.list) {
        var out: std.ArrayList(u8) = .empty;
        for (common.clients) |c| {
            try out.appendSlice(arena, c.id);
            try out.append(arena, '\n');
        }
        try Io.File.stdout().writeStreamingAll(io, out.items);
        return;
    }

    // which clients
    var selected: std.ArrayList(*const common.ClientMeta) = .empty;
    if (s.clients) |list| {
        for (try splitList(arena, list)) |id| {
            const meta = common.findClient(id) orelse {
                std.debug.print("zig: unknown client {s} (see --list)\n", .{id});
                std.process.exit(2);
            };
            try selected.append(arena, meta);
        }
    } else {
        for (&common.clients) |*c| try selected.append(arena, c);
    }

    const manifest = try common.loadManifest(arena, io, s.corpus);
    var workloads: std.ArrayList(common.Workload) = .empty;
    for (try splitList(arena, s.workloads orelse "all")) |name| {
        try workloads.append(arena, manifest.find(name) orelse {
            std.debug.print("zig: unknown workload {s}\n", .{name});
            std.process.exit(2);
        });
    }

    const bin_dir = try std.process.executableDirPathAlloc(io, arena);

    var rows: std.ArrayList(common.Row) = .empty;
    for (workloads.items) |w| {
        for (selected.items) |meta| {
            std.debug.print("zig: {s} on {s}/{s}\n", .{ meta.id, s.relay, w.name });
            const row = runChild(arena, gpa, io, bin_dir, s, meta, w);
            if (row.@"error") |e| {
                std.debug.print("zig: {s} {s}: ERROR {s}\n", .{ meta.id, w.name, e });
            } else {
                std.debug.print("zig: {s} {s}: median {d:.1} ms, cpu {d:.1} ms, accepted {d} (ok={}), rss {d:.1} MB\n", .{
                    meta.id, w.name, row.median_ms orelse 0, row.cpu_ms orelse 0, row.accepted orelse 0, row.accepted_ok, row.peak_rss_mb orelse 0,
                });
            }
            try rows.append(arena, row);
        }
    }

    const output: Output = .{
        .harness = common.harness_id,
        .language = "Zig",
        .runtime = common.zigRuntime(),
        .host = .{ .cpu = cpuModel(arena, io), .cores = std.Thread.getCpuCount() catch 0, .os = osName(arena) },
        .settings = .{ .warmup_runs = s.warmup_runs, .min_runs = s.min_runs, .min_time_ms = s.min_time_ms, .max_runs = s.max_runs },
        .relay = s.relay,
        .corpus_fingerprint = manifest.fingerprint,
        .results = rows.items,
    };
    const json = try std.json.Stringify.valueAlloc(arena, output, .{ .whitespace = .indent_2 });
    if (std.fs.path.dirname(s.out)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = s.out, .data = try std.mem.concat(arena, u8, &.{ json, "\n" }) });
    std.debug.print("zig: wrote {s}\n", .{s.out});
}
