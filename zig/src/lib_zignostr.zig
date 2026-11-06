//! zig-nostr/nostr (github.com/zig-nostr/nostr) clients. Started by the driver as
//! `libbench-zignostr --child <client> --workload <name> ...`.
const std = @import("std");
const nostr = @import("nostr");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    try common.childMain(init, run);
}

var reported = false;

fn run(client_id: []const u8, ctx: *common.RunCtx) anyerror!void {
    if (std.mem.eql(u8, client_id, "zig-nostr-relay")) return runRelay(ctx);
    return error.UnknownClient;
}

/// The library's documented read loop (README / skills/zig-nostr/SKILL.md "Relays"):
/// dial, subscribe, receiveTimeout until EOSE, nostr.event.verify on every event.
fn runRelay(ctx: *common.RunCtx) !void {
    const gpa = ctx.gpa;
    const rec = ctx.rec;

    // Setup (untimed): a new secp256k1 context and a new connection, handshake done.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const relay = try nostr.relay.dial(gpa, ctx.io, ctx.url);
    defer relay.deinit();

    const sub_id = "bench";
    const filters = [_]nostr.filter.Filter{.{ .limit = ctx.limit }};

    rec.begin();
    try relay.subscribe(sub_id, &filters);
    while (true) {
        if (rec.remainingNs() <= 0) return error.Timeout;
        var msg = (try relay.receiveTimeout(rec.remainingTimeout())) orelse return error.RelayClosed;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| {
                if (!std.mem.eql(u8, e.subscription_id, sub_id)) continue;
                if (try nostr.event.verify(gpa, signer, e.event)) rec.accept(&e.event.id);
            },
            .eose => |e| if (std.mem.eql(u8, e.subscription_id, sub_id)) {
                rec.eose();
                break;
            },
            .closed => return error.SubscriptionClosed,
            else => {},
        }
    }

    // Teardown (untimed).
    relay.unsubscribe(sub_id) catch {};
    if (!reported) {
        reported = true;
        std.debug.print("  zig-nostr-relay: messages the parser skipped (Relay.unreadable): {d}\n", .{relay.unreadable()});
    }
}
