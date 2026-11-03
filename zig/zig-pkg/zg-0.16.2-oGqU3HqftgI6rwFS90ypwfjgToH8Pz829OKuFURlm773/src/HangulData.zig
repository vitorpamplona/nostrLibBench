//! Hangul Data

pub const Syllable = enum {
    none,
    L,
    LV,
    LVT,
    V,
    T,
};

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u3 = undefined,
};

const hangul = hangul_data: {
    const data = @import("hangul");
    break :hangul_data Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

const Hangul = @This();

/// Returns the Hangul syllable type for `cp`.
pub fn syllable(cp: u21) Syllable {
    return @enumFromInt(hangul.s2[hangul.s1[cp >> 8] + (cp & 0xff)]);
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;
