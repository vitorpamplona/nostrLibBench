const std = @import("std");
const simd = std.simd;
const testing = std.testing;

/// Returns true if `str` only contains ASCII bytes. Uses SIMD if possible.
pub fn isAsciiOnly(str: []const u8) bool {
    const vec_len = simd.suggestVectorLength(u8) orelse return for (str) |b| {
        if (b > 127) break false;
    } else true;

    const Vec = @Vector(vec_len, u8);
    var remaining = str;

    while (true) {
        if (remaining.len < vec_len) return for (remaining) |b| {
            if (b > 127) break false;
        } else true;

        const v1 = remaining[0..vec_len].*;
        const v2: Vec = @splat(127);
        if (@reduce(.Or, v1 > v2)) return false;
        remaining = remaining[vec_len..];
    }

    return true;
}

/// Returns the suffix of `str` beginning at the first non-ASCII byte.
/// Returns the empty suffix if `str` is entirely ASCII.
pub fn nonAsciiSuffix(str: []const u8) []const u8 {
    const vec_len = simd.suggestVectorLength(u8) orelse return for (str, 0..) |b, i| {
        if (b > 127) break str[i..];
    } else str[str.len..];

    const Vec = @Vector(vec_len, u8);
    const v2: Vec = @splat(127);
    var remaining = str;
    var prefix_len: usize = 0;

    while (remaining.len >= vec_len) {
        const v1: Vec = remaining[0..vec_len].*;
        if (@reduce(.Or, v1 > v2)) {
            return for (remaining[0..vec_len], 0..) |b, i| {
                if (b > 127) break str[prefix_len + i ..];
            } else unreachable;
        }
        remaining = remaining[vec_len..];
        prefix_len += vec_len;
    }

    return for (remaining, 0..) |b, i| {
        if (b > 127) break str[prefix_len + i ..];
    } else str[str.len..];
}

/// Do a caseless comparison, with SIMD if possible.  Strings must be of equal
/// length.  Returns how many bytes are case-fold-matched ASCII, this will be
/// equal to the string length if they match.
pub fn caselessCmpLen(str_a: []const u8, str_b: []const u8) usize {
    std.debug.assert(str_a.len == str_b.len);
    const vec_len = simd.suggestVectorLength(u8) orelse return caselessCmpNoSimd(str_a, str_b);
    const Vec = @Vector(vec_len, u8);
    const BVec = @Vector(vec_len, bool);

    const msb: Vec = @splat(@as(u8, 0x80));
    const case_bit: Vec = @splat(@as(u8, 0x20));
    const low5: Vec = @splat(@as(u8, 0x1f));
    const vec0: Vec = @splat(@as(u8, 0));
    const vec1: Vec = @splat(@as(u8, 1));
    const vec26: Vec = @splat(@as(u8, 26));

    var rem_a = str_a;
    var rem_b = str_b;

    while (rem_a.len >= vec_len) {
        const a: Vec = rem_a[0..vec_len].*;
        const b: Vec = rem_b[0..vec_len].*;
        // ASCII gate: MSB must be 0 in both.
        const is_ascii: BVec = ((a | b) & msb) == vec0;

        const xor: Vec = a ^ b;
        const exact: BVec = xor == vec0;
        const case_diff: BVec = xor == case_bit;

        // Letter test (only needed when case_diff).
        const x: Vec = (a | b) & low5;
        const is_letter: BVec =
            (x >= vec1) & (x <= vec26);

        const matched: BVec = is_ascii & (exact | (case_diff & is_letter));

        if (!@reduce(.And, matched)) break;
        rem_a = rem_a[vec_len..];
        rem_b = rem_b[vec_len..];
    }

    // Tail
    return str_a.len - rem_a.len + caselessCmpNoSimd(rem_a, rem_b);
}

inline fn caselessCmpNoSimd(str_a: []const u8, str_b: []const u8) usize {
    for (str_a, str_b, 0..) |a, b, i| {
        // High?
        if (((a | b) & 0x80) != 0) return i;
        const xor = a ^ b;
        if (xor == 0) continue; // Match
        if (xor != 0x20) return i; // Not the upcase bit.

        const lo = a | b;
        const x = lo & 0x1f;
        if (x < 1 or x > 26) return i; // Not a letter
    } else return str_a.len;
}

test caselessCmpNoSimd {
    const hi_l = "Hello, World!";
    const hi_h = "HeLlO, wOrLd!";
    try testing.expectEqual(hi_l.len, caselessCmpNoSimd(hi_l, hi_h));
}

test caselessCmpLen {
    const hi_l = "Hello, World!" ** 25;
    const hi_h = "HeLlO, wOrLd!" ** 25;
    try testing.expectEqual(hi_l.len, caselessCmpLen(hi_l, hi_h));
}

test "isAsciiOnly" {
    const ascii_only = "Hello, World! 0123456789 !@#$%^&*()_-=+";
    try testing.expect(isAsciiOnly(ascii_only));
    const not_ascii_only = "Héllo, World! 0123456789 !@#$%^&*()_-=+";
    try testing.expect(!isAsciiOnly(not_ascii_only));
}

test "nonAsciiSuffix" {
    try testing.expectEqualStrings("", nonAsciiSuffix(""));
    try testing.expectEqualStrings("", nonAsciiSuffix("Hello, World!"));
    try testing.expectEqualStrings("éllo", nonAsciiSuffix("Héllo"));
    try testing.expectEqualStrings("\u{0301}x", nonAsciiSuffix("\u{0301}x"));
}
