//! Normalization Properties Data

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u3 = undefined,
};

const norms = norm_props_data: {
    const data = @import("normp");
    break :norm_props_data Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

const NormProps = @This();

/// Returns true if `cp` is already in NFD form.
pub fn isNfd(cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 1 == 0;
}

/// Returns true if `cp` is already in NFKD form.
pub fn isNfkd(cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 2 == 0;
}

/// Returns true if `cp` is not allowed in any normalized form.
pub fn isFcx(cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;
