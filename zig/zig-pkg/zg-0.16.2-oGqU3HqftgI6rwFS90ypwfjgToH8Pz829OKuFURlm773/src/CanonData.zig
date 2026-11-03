//! Canonicalization Data

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const @import("canon").Canonicalization = undefined,
};

// Canonicalization looks like this:
// const Canonicalization = struct {
//     len: u3 = 0,
//     cps: [2]u21 = [_]u21{0} ** 2,
// };

const canon_data = canon_data: {
    const canon_ = @import("canon");
    break :canon_data Data{
        .s1 = &canon_.s1,
        .s2 = &canon_.s2,
    };
};

const CanonData = @This();

// There's a bug here, which is down to how static u21 vs. runtime are handled,
// the "unique representation" claim is not working out.  AutoHash casts to bytes,
// and that won't fly.  So we do a simple custom context which works for both.

const Context = struct {
    pub fn hash(_: Context, cps: [2]u21) u64 {
        const cp_44: u64 = (@as(u64, cps[0]) << 22) + cps[1];
        return std.hash.int(cp_44);
    }

    pub fn eql(_: Context, cps1: [2]u21, cps2: [2]u21) bool {
        return cps1[0] == cps2[0] and cps1[1] == cps2[1];
    }
};

const c_map = comptime_map.ComptimeHashMap([2]u21, u21, Context, @import("canon").c_map);

/// Returns canonical decomposition for `cp`.
pub fn toNfd(cp: u21) []const u21 {
    const canon = &canon_data.s2[canon_data.s1[cp >> 8] + (cp & 0xff)];
    return canon.cps[0..canon.len];
}

// Returns the primary composite for the codepoints in `cp`.
pub fn toNfc(cps: [2]u21) ?u21 {
    if (c_map.get(cps)) |cpp| {
        return cpp.*;
    } else {
        return null;
    }
    unreachable;
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const comptime_map = @import("comptime_map.zig");

test {
    _ = comptime_map;
}
