const CaseFolding = @This();

const Data = struct {
    cutoff: u21 = undefined,
    cwcf_exceptions_min: u21 = undefined,
    cwcf_exceptions_max: u21 = undefined,
    cwcf_exceptions: []const u21 = undefined,
    multiple_start: u21 = undefined,
    stage1: []const u8 = undefined,
    stage2: []const u8 = undefined,
    stage3: []const i24 = undefined,
};

const casefold = casefold: {
    const data = @import("fold");
    break :casefold Data{
        .cutoff = data.cutoff,
        .multiple_start = data.multiple_start,
        .stage1 = &data.stage1,
        .stage2 = &data.stage2,
        .stage3 = &data.stage3,
        .cwcf_exceptions_min = data.cwcf_exceptions_min,
        .cwcf_exceptions_max = data.cwcf_exceptions_max,
        .cwcf_exceptions = &data.cwcf_exceptions,
    };
};

/// Returns the case fold for `cp`.
pub fn caseFold(cp: u21, buf: []u21) []const u21 {
    // Unmatched code points fold to themselves, so we default to this.
    buf[0] = cp;

    if (cp >= casefold.cutoff) return buf[0..1];

    const stage1_val = casefold.stage1[cp >> 8];
    if (stage1_val == 0) return buf[0..1];

    const stage2_index = @as(usize, stage1_val) * 256 + (cp & 0xFF);
    const stage3_index = casefold.stage2[stage2_index];

    if (stage3_index & 0x80 != 0) {
        const real_index = @as(usize, casefold.multiple_start) + (stage3_index ^ 0x80) * 3;
        const mapping = mem.sliceTo(casefold.stage3[real_index..][0..3], 0);
        for (mapping, 0..) |c, i| buf[i] = @intCast(c);

        return buf[0..mapping.len];
    }

    const offset = casefold.stage3[stage3_index];
    if (offset == 0) return buf[0..1];

    buf[0] = @intCast(@as(i32, cp) + offset);

    return buf[0..1];
}

/// Produces the case folded code points for `cps`. Caller must free returned
/// slice with `allocator`.
pub fn caseFoldAlloc(
    allocator: Allocator,
    cps: []const u21,
) Allocator.Error![]const u21 {
    var cfcps = std.array_list.Managed(u21).init(allocator);
    defer cfcps.deinit();
    var buf: [3]u21 = undefined;

    for (cps) |cp| {
        const cf = CaseFolding.caseFold(cp, &buf);

        if (cf.len == 0) {
            try cfcps.append(cp);
        } else {
            try cfcps.appendSlice(cf);
        }
    }

    return try cfcps.toOwnedSlice();
}

/// Returns true when caseFold(NFD(`cp`)) != NFD(`cp`).
pub fn cpChangesWhenCaseFolded(cp: u21) bool {
    var buf: [3]u21 = undefined;
    const has_mapping = CaseFolding.caseFold(cp, &buf).len != 0;
    return has_mapping and !CaseFolding.isCwcfException(cp);
}

pub fn changesWhenCaseFolded(cps: []const u21) bool {
    return for (cps) |cp| {
        if (CaseFolding.cpChangesWhenCaseFolded(cp)) break true;
    } else false;
}

fn isCwcfException(cp: u21) bool {
    return cp >= casefold.cwcf_exceptions_min and
        cp <= casefold.cwcf_exceptions_max and
        std.mem.indexOfScalar(u21, casefold.cwcf_exceptions, cp) != null;
}

test "caseFold" {
    var buf: [3]u21 = undefined;

    // Folds '1' to '1'
    try testing.expectEqual(1, caseFold('1', &buf).len);
    try testing.expectEqual('1', caseFold('1', &buf)[0]);

    // Folds '2' to '2'
    try testing.expectEqual(1, caseFold('2', &buf).len);
    try testing.expectEqual('2', caseFold('2', &buf)[0]);

    // Folds Armenian capital letter 'Zhe' (U+053A)
    try testing.expectEqual(1, caseFold('Ժ', &buf).len);
    // Armenian small letter 'Zhe' (U+056A)
    try testing.expectEqual('ժ', caseFold('Ժ', &buf)[0]);

    // Folds Greek small letter Upsilon with Dialytika and Perispomeni (U+1FE7)
    try testing.expectEqual(3, caseFold('ῧ', &buf).len);
    // Greek small letter Upsilon (U+03C5)
    try testing.expectEqual('υ', caseFold('ῧ', &buf)[0]);
    // Combining Diaeresis
    try testing.expectEqual('\u{0308}', caseFold('ῧ', &buf)[1]);
    // Combining Greek Perispomeni
    try testing.expectEqual('\u{0342}', caseFold('ῧ', &buf)[2]);
}

const std = @import("std");
const Allocator = mem.Allocator;
const mem = std.mem;
const testing = std.testing;
