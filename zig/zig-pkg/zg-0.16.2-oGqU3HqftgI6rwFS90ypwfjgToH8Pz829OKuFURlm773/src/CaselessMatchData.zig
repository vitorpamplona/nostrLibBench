//! Caseless Matching Fast-path Data

pub const IsCaseFoldable = enum(u1) {
    yes,
    maybe,
};

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u1 = undefined,
};

const caseless_data = caseless_data: {
    const data = @import("caseless");
    break :caseless_data Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

pub fn nfcCaseFoldableQC(cp: u21) IsCaseFoldable {
    return @enumFromInt(caseless_data.s2[caseless_data.s1[cp >> 8] + (cp & 0xff)]);
}

fn isExpectedMaybe(cp: u21) bool {
    return cp == 0x0345 or
        (0x1F80 <= cp and cp <= 0x1FAF) or
        (0x1FB2 <= cp and cp <= 0x1FB4) or
        cp == 0x1FB7 or
        cp == 0x1FBC or
        (0x1FC2 <= cp and cp <= 0x1FC4) or
        cp == 0x1FC7 or
        cp == 0x1FCC or
        (0x1FF2 <= cp and cp <= 0x1FF4) or
        cp == 0x1FF7 or
        cp == 0x1FFC;
}

test "nfcCaseFoldableQC exact set" {
    var maybe_count: usize = 0;

    for (0..0x110000) |cp_i| {
        const cp: u21 = @intCast(cp_i);
        const expected: IsCaseFoldable = if (isExpectedMaybe(cp)) .maybe else .yes;
        try testing.expectEqual(expected, nfcCaseFoldableQC(cp));
        if (expected == .maybe) maybe_count += 1;
    }

    try testing.expectEqual(@as(usize, 64), maybe_count);
}

test "nfcCaseFoldableQC spot checks" {
    try testing.expectEqual(.maybe, nfcCaseFoldableQC('\u{0345}'));
    try testing.expectEqual(.maybe, nfcCaseFoldableQC('\u{1FC3}'));
    try testing.expectEqual(.yes, nfcCaseFoldableQC('e'));
    try testing.expectEqual(.yes, nfcCaseFoldableQC('\u{00E9}'));
}

const std = @import("std");
const testing = std.testing;
