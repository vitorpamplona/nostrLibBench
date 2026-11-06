//! privkeyio/libnostr-z (github.com/privkeyio/libnostr-z) clients. Started by the driver as
//! `libbench-libnostrz --child <client> --workload <name> ...`.
const std = @import("std");
const nostr = @import("nostr");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    // noscrypt's global context (crypto.init), as the README's usage does.
    try nostr.init();
    defer nostr.cleanup();
    try common.childMain(init, run);
}

fn run(client_id: []const u8, ctx: *common.RunCtx) anyerror!void {
    if (std.mem.eql(u8, client_id, "libnostr-z-relay")) return runRelay(ctx);
    if (std.mem.eql(u8, client_id, "libnostr-z-pool-query")) return runPoolQuery(ctx);
    return error.UnknownClient;
}

fn timeoutMs32(ms: u64) u32 {
    return @intCast(@min(ms, std.math.maxInt(u32)));
}

/// The loop the noz CLI (`noz req`) runs: Relay.init/connect, subscribe, receive until EOSE,
/// Event.validate on every event.
fn runRelay(ctx: *common.RunCtx) !void {
    const rec = ctx.rec;

    // Setup (untimed): a new Relay, connected (TCP + WebSocket upgrade).
    var relay = try nostr.relay.Relay.init(ctx.gpa, ctx.url, .{
        .auto_reconnect = false,
        .read_timeout_ms = timeoutMs32(ctx.timeout_ms),
    });
    defer relay.deinit();
    try relay.connect();
    defer relay.disconnect();

    const sub_id = "bench";
    const filters = [_]nostr.Filter{.{ .limit_val = ctx.limit }};

    rec.begin();
    try relay.subscribe(sub_id, &filters);
    while (true) {
        if (rec.remainingNs() <= 0) return error.Timeout;
        // null: the socket read failed or timed out (SO_RCVTIMEO), or the relay closed.
        var msg = (try relay.receive()) orelse return error.ReceiveFailedOrTimedOut;
        defer msg.deinit();
        switch (msg.msg_type) {
            .event => {
                const sid = msg.subscription_id orelse continue;
                if (!std.mem.eql(u8, sid, sub_id)) continue;
                // event is null when Event.parse rejected it (e.g. "sig":"")
                if (msg.event) |*ev| {
                    ev.validate() catch continue;
                    rec.accept(ev.id());
                }
            },
            .eose => {
                rec.eose();
                break;
            },
            .closed => return error.SubscriptionClosed,
            else => {},
        }
    }

    // Teardown (untimed).
    relay.unsubscribe(sub_id) catch {};
}

/// Pool.queryParallel: the library's fetch-all API (subscribe, collect until every relay sent
/// EOSE, return the events), then Event.validate on each.
fn runPoolQuery(ctx: *common.RunCtx) !void {
    const rec = ctx.rec;

    // Setup (untimed): a new Pool with the relay connected.
    // queue_size raised from 10000 to the workload size: a full queue drops its oldest message.
    var pool = nostr.pool.Pool.initWithOptions(ctx.gpa, .{ .queue_size = @as(usize, ctx.limit) + 16 });
    defer pool.deinit();
    try pool.addRelay(ctx.url);
    if (try pool.connectAll() != 1) return error.ConnectFailed;
    // Without a socket read timeout the pool's reader thread stays blocked in read() once the
    // relay goes quiet after EOSE, and stopReceiving (queryParallel's exit) / deinit join it
    // forever. 200 ms lets the thread see should_stop.
    for (pool.relays.items) |*h| {
        if (h.client) |*c| c.setReadTimeout(200);
    }

    const filters = [_]nostr.Filter{.{ .limit_val = ctx.limit }};

    rec.begin();
    const events = try pool.queryParallel("bench", &filters, ctx.timeout_ms);
    rec.eose(); // queryParallel returns once the relay's EOSE was read
    defer {
        for (events) |*e| e.deinit();
        ctx.gpa.free(events);
    }
    for (events) |*ev| {
        ev.validate() catch continue;
        rec.accept(ev.id());
    }
    rec.end();
    if (rec.remainingNs() <= 0) return error.Timeout;
}
