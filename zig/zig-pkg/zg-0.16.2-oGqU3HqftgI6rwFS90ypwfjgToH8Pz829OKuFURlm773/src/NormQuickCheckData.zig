//! Normalization Quick Check Data
//!

/// Is the codepoint in the queried normalization form.
/// Decompositions only have 'yes' and 'no'.
pub const IsNormal = enum(u2) {
    yes,
    no,
    maybe,
};

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u2 = undefined,
};

const qc_data = @import("quickcheck");

const nfc_data = nfc_data: {
    break :nfc_data Data{
        .s1 = &qc_data.nfc1,
        .s2 = &qc_data.nfc2,
    };
};

const nfd_data = nfd_data: {
    break :nfd_data Data{
        .s1 = &qc_data.nfd1,
        .s2 = &qc_data.nfd2,
    };
};

const nfkc_data = nfkc_data: {
    break :nfkc_data Data{
        .s1 = &qc_data.nfkc1,
        .s2 = &qc_data.nfkc2,
    };
};

const nfkd_data = nfkd_data: {
    break :nfkd_data Data{
        .s1 = &qc_data.nfkd1,
        .s2 = &qc_data.nfkd2,
    };
};

pub fn isNormalNfc(cp: u21) IsNormal {
    return @enumFromInt(nfc_data.s2[nfc_data.s1[cp >> 8] + (cp & 0xff)]);
}

pub fn isNormalNfd(cp: u21) IsNormal {
    return @enumFromInt(nfd_data.s2[nfd_data.s1[cp >> 8] + (cp & 0xff)]);
}

pub fn isNormalNfkc(cp: u21) IsNormal {
    return @enumFromInt(nfkc_data.s2[nfkc_data.s1[cp >> 8] + (cp & 0xff)]);
}

pub fn isNormalNfkd(cp: u21) IsNormal {
    return @enumFromInt(nfkd_data.s2[nfkd_data.s1[cp >> 8] + (cp & 0xff)]);
}

// This is: one isolated point, each end of a range, and one
// unlisted point.  Enough to make the case.

test isNormalNfc {
    try expectEqual(.no, isNormalNfc('\u{0374}'));
    try expectEqual(.no, isNormalNfc('\u{09dc}'));
    try expectEqual(.no, isNormalNfc('\u{09dd}'));
    try expectEqual(.yes, isNormalNfc('\u{0d9e}'));
    try expectEqual(.maybe, isNormalNfc('\u{0311}'));
    try expectEqual(.maybe, isNormalNfc('\u{0323}'));
    try expectEqual(.maybe, isNormalNfc('\u{0328}'));
}

test isNormalNfd {
    try expectEqual(.no, isNormalNfd('\u{0128}'));
    try expectEqual(.no, isNormalNfd('\u{0130}'));
    try expectEqual(.no, isNormalNfd('\u{0374}'));
    try expectEqual(.yes, isNormalNfd('\u{0375}'));
    // No maybes with decomposition
}

test isNormalNfkc {
    try expectEqual(.no, isNormalNfkc('\u{00a0}'));
    try expectEqual(.no, isNormalNfkc('\u{00b2}'));
    try expectEqual(.no, isNormalNfkc('\u{00b3}'));
    try expectEqual(.yes, isNormalNfkc('\u{00bb}'));
    try expectEqual(.maybe, isNormalNfkc('\u{031b}'));
    try expectEqual(.maybe, isNormalNfkc('\u{0653}'));
    try expectEqual(.maybe, isNormalNfkc('\u{0655}'));
}

test isNormalNfkd {
    try expectEqual(.no, isNormalNfkd('\u{1f5b}'));
    try expectEqual(.no, isNormalNfkd('\u{1f80}'));
    try expectEqual(.no, isNormalNfkd('\u{1fb4}'));
    try expectEqual(.yes, isNormalNfkd('\u{0375}'));
    // No maybes with decomposition
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;
