//! Combining Class Data

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u8 = undefined,
};

const combining_data = combining_data: {
    const data = @import("ccc");
    break :combining_data Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

const CombiningData = @This();

/// Returns the canonical combining class for a code point.
pub fn ccc(cp: u21) u8 {
    return combining_data.s2[combining_data.s1[cp >> 8] + (cp & 0xff)];
}

/// True if `cp` is a starter code point, not a combining character.
pub fn isStarter(cp: u21) bool {
    return combining_data.s2[combining_data.s1[cp >> 8] + (cp & 0xff)] == 0;
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
