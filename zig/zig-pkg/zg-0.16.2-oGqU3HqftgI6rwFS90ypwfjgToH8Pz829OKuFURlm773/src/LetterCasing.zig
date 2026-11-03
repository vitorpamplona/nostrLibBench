const code_point = @import("code_point");

const CodePoint = code_point.CodePoint;
const CodePointIterator = code_point.Iterator;
const ReverseIterator = code_point.ReverseIterator;

const SimpleData = struct {
    s1: []const u16 = undefined,
    s2: []const @import("case").SimpleMapping = undefined,
};

const PropsData = struct {
    s1: []const u16 = undefined,
    s2: []const u8 = undefined,
};

const CaseData = struct {
    cutoff: u21 = undefined,
    s4_start: u16 = undefined,
    s1: []const u16 = undefined,
    s2: []const u16 = undefined,
    s3: []const u21 = undefined,
    s4: []const @import("case").MultiMapping = undefined,
    multis: []const u21 = undefined,
};

const simple = simple: {
    const data = @import("case");
    break :simple SimpleData{
        .s1 = &data.simple_s1,
        .s2 = &data.simple_s2,
    };
};

const prop_data = prop_data: {
    const data = @import("case");
    break :prop_data PropsData{
        .s1 = &data.props_s1,
        .s2 = &data.props_s2,
    };
};

const lower = lower: {
    const data = @import("case");
    break :lower CaseData{
        .cutoff = data.lower_full_cutoff,
        .s4_start = data.lower_full_s4_start,
        .s1 = &data.lower_full_s1,
        .s2 = &data.lower_full_s2,
        .s3 = &data.lower_full_s3,
        .s4 = &data.lower_full_s4,
        .multis = &data.lower_full_multis,
    };
};

const title = title: {
    const data = @import("case");
    break :title CaseData{
        .cutoff = data.title_full_cutoff,
        .s4_start = data.title_full_s4_start,
        .s1 = &data.title_full_s1,
        .s2 = &data.title_full_s2,
        .s3 = &data.title_full_s3,
        .s4 = &data.title_full_s4,
        .multis = &data.title_full_multis,
    };
};

const upper = upper: {
    const data = @import("case");
    break :upper CaseData{
        .cutoff = data.upper_full_cutoff,
        .s4_start = data.upper_full_s4_start,
        .s1 = &data.upper_full_s1,
        .s2 = &data.upper_full_s2,
        .s3 = &data.upper_full_s3,
        .s4 = &data.upper_full_s4,
        .multis = &data.upper_full_multis,
    };
};

const prop_lowercase: u8 = 1;
const prop_uppercase: u8 = 2;
const prop_cased: u8 = 4;
const prop_case_ignorable: u8 = 8;
const prop_titlecase: u8 = 16;
const final_sigma: u21 = 0x03A3;
const final_sigma_lower: u21 = 0x03C2;

// Returns true if `cp` is either upper, lower, or title case.
pub fn isCased(cp: u21) bool {
    return props(cp) & prop_cased != 0;
}

// Returns true if `cp` is uppercase.
pub fn isUpper(cp: u21) bool {
    return props(cp) & prop_uppercase != 0;
}

// Returns true if `cp` is titlecase.
pub fn isTitlecase(cp: u21) bool {
    return props(cp) & prop_titlecase != 0;
}

test "isTitlecase" {
    try testing.expect(isTitlecase('ǅ'));
    try testing.expect(!isTitlecase('Ǆ'));
    try testing.expect(!isTitlecase('ǆ'));
}

/// Returns true if `str` is all non-lowercase.
pub fn isUpperStr(str: []const u8) bool {
    var iter = CodePointIterator{ .bytes = str };

    return while (iter.next()) |cp| {
        if (isLower(cp.code)) break false;
    } else true;
}

test "isUpperStr" {
    try testing.expect(isUpperStr("HELLO, WORLD 2112!"));
    try testing.expect(!isUpperStr("hello, world 2112!"));
    try testing.expect(!isUpperStr("Hello, World 2112!"));
}

/// Returns uppercase mapping for `cp`.
pub fn toUpper(cp: u21) u21 {
    const mapping = simpleMapping(cp);
    return if (mapping.upper != 0) mapping.upper else cp;
}

/// Returns simple titlecase mapping for `cp`.
pub fn toTitlecase(cp: u21) u21 {
    const mapping = simpleMapping(cp);
    return if (mapping.title != 0) mapping.title else cp;
}

/// Writes `str` in uppercase using full default casing.
pub fn writeAsUpper(writer: *Writer, str: []const u8) Writer.Error!void {
    var iter = CodePointIterator{ .bytes = str };

    while (iter.next()) |cp| {
        if (upperMapped(cp.code)) |mapping| {
            try appendCodePoints(writer, mapping);
        } else {
            try appendCodePoint(writer, cp.code);
        }
    }
}

/// Returns a new string with all letters in uppercase using full default casing.
/// Caller must free returned bytes with `allocator`.
pub fn toUpperAlloc(allocator: Allocator, str: []const u8) OOM![]u8 {
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();

    writeAsUpper(&allocating.writer, str) catch return error.OutOfMemory;
    return try allocating.toOwnedSlice();
}

test "toUpperAlloc" {
    const uppered = try toUpperAlloc(testing.allocator, "Hello, World 2112!");
    defer testing.allocator.free(uppered);
    try testing.expectEqualStrings("HELLO, WORLD 2112!", uppered);
}

// Returns true if `cp` is lowercase.
pub fn isLower(cp: u21) bool {
    return props(cp) & prop_lowercase != 0;
}

/// Returns true if `str` is all non-uppercase.
pub fn isLowerStr(str: []const u8) bool {
    var iter = CodePointIterator{ .bytes = str };

    return while (iter.next()) |cp| {
        if (isUpper(cp.code)) break false;
    } else true;
}

test "isLowerStr" {
    try testing.expect(isLowerStr("hello, world 2112!"));
    try testing.expect(!isLowerStr("HELLO, WORLD 2112!"));
    try testing.expect(!isLowerStr("Hello, World 2112!"));
}

/// Returns lowercase mapping for `cp`.
pub fn toLower(cp: u21) u21 {
    const mapping = simpleMapping(cp);
    return if (mapping.lower != 0) mapping.lower else cp;
}

/// Returns the full uppercase mapping for `cp`, if it changes.
pub fn upperMapped(cp: u21) ?[]const u21 {
    if (cp >= upper.cutoff) return null;

    const offset = upper.s1[cp >> 8] + (cp & 0xff);
    const index = upper.s2[offset];
    if (index == 0) return null;

    if (index < upper.s4_start) {
        return upper.s3[index - 1 ..][0..1];
    }

    const multi = upper.s4[index - upper.s4_start];
    return upper.multis[multi.index..][0..multi.len];
}

/// Returns the full lowercase mapping for `cp`, if it changes.
pub fn lowerMapped(cp: u21) ?[]const u21 {
    if (cp >= lower.cutoff) return null;

    const offset = lower.s1[cp >> 8] + (cp & 0xff);
    const index = lower.s2[offset];
    if (index == 0) return null;

    if (index < lower.s4_start) {
        return lower.s3[index - 1 ..][0..1];
    }

    const multi = lower.s4[index - lower.s4_start];
    return lower.multis[multi.index..][0..multi.len];
}

/// Returns the full titlecase mapping for `cp`, if it changes.
pub fn titleMapped(cp: u21) ?[]const u21 {
    if (cp >= title.cutoff) return null;

    const offset = title.s1[cp >> 8] + (cp & 0xff);
    const index = title.s2[offset];
    if (index == 0) return null;

    if (index < title.s4_start) {
        return title.s3[index - 1 ..][0..1];
    }

    const multi = title.s4[index - title.s4_start];
    return title.multis[multi.index..][0..multi.len];
}

/// Writes `str` in lowercase using full default casing.
pub fn writeAsLower(writer: *Writer, str: []const u8) Writer.Error!void {
    var iter = CodePointIterator{ .bytes = str };

    while (iter.next()) |cp| {
        if (cp.code == final_sigma and isFinalSigma(str, cp)) {
            try appendCodePoints(writer, &[_]u21{final_sigma_lower});
            continue;
        }

        if (lowerMapped(cp.code)) |mapping| {
            try appendCodePoints(writer, mapping);
        } else {
            try appendCodePoint(writer, cp.code);
        }
    }
}

/// Returns a new string with all letters in lowercase using full default casing.
/// Caller must free returned bytes with `allocator`.
pub fn toLowerAlloc(allocator: Allocator, str: []const u8) OOM![]u8 {
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();

    writeAsLower(&allocating.writer, str) catch return error.OutOfMemory;
    return try allocating.toOwnedSlice();
}

test "toLowerAlloc" {
    const lowered = try toLowerAlloc(testing.allocator, "Hello, World 2112!");
    defer testing.allocator.free(lowered);
    try testing.expectEqualStrings("hello, world 2112!", lowered);
}

fn simpleMapping(cp: u21) @import("case").SimpleMapping {
    const block_index = cp >> 8;
    if (block_index >= simple.s1.len) {
        return .{ .lower = 0, .title = 0, .upper = 0 };
    }

    const offset = simple.s1[block_index] + (cp & 0xff);
    return simple.s2[offset];
}

fn props(cp: u21) u8 {
    const block_index = cp >> 8;
    if (block_index >= prop_data.s1.len) return 0;

    const offset = prop_data.s1[block_index] + (cp & 0xff);
    return prop_data.s2[offset];
}

fn appendCodePoint(writer: *Writer, cp: u21) Writer.Error!void {
    var buf: [4]u8 = undefined;
    const len = unicode.utf8Encode(cp, &buf) catch unreachable;
    try writer.writeAll(buf[0..len]);
}

fn appendCodePoints(writer: *Writer, cps: []const u21) Writer.Error!void {
    for (cps) |cp| try appendCodePoint(writer, cp);
}

fn isCaseIgnorable(cp: u21) bool {
    return props(cp) & prop_case_ignorable != 0;
}

fn isFinalSigma(str: []const u8, cp: CodePoint) bool {
    const before_end: usize = @intCast(cp.offset);
    const after_start: usize = @intCast(cp.offset + cp.len);
    return precededByCased(str[0..before_end]) and !followedByCased(str[after_start..]);
}

fn precededByCased(prefix: []const u8) bool {
    var iter = ReverseIterator.init(prefix);
    while (iter.prev()) |cp| {
        if (isCaseIgnorable(cp.code)) continue;
        return isCased(cp.code);
    }
    return false;
}

fn followedByCased(suffix: []const u8) bool {
    var iter = CodePointIterator.init(suffix);
    while (iter.next()) |cp| {
        if (isCaseIgnorable(cp.code)) continue;
        return isCased(cp.code);
    }
    return false;
}

test "toTitlecase simple mapping" {
    try testing.expectEqual(@as(u21, 'A'), toTitlecase('a'));
    try testing.expectEqual(@as(u21, '\u{01C5}'), toTitlecase('\u{01C6}'));
}

test "upperMapped, lowerMapped, and titleMapped" {
    try testing.expectEqualSlices(u21, &[_]u21{ 'S', 'S' }, upperMapped('\u{00DF}').?);
    try testing.expectEqualSlices(u21, &[_]u21{ 'F', 'F', 'I' }, upperMapped('\u{FB03}').?);
    try testing.expectEqualSlices(u21, &[_]u21{ 'i', '\u{0307}' }, lowerMapped('\u{0130}').?);
    try testing.expectEqualSlices(u21, &[_]u21{ 'S', 's' }, titleMapped('\u{00DF}').?);
    try testing.expectEqualSlices(u21, &[_]u21{ 'F', 'f', 'i' }, titleMapped('\u{FB03}').?);
    try testing.expectEqual(@as(?[]const u21, null), titleMapped('ǅ'));
    try testing.expectEqual(@as(?[]const u21, null), titleMapped('ა'));
    try testing.expectEqual(@as(?[]const u21, null), upperMapped('A'));
}

test "toUpperAlloc uses full casing" {
    const uppered = try toUpperAlloc(testing.allocator, "Straße \u{FB03}");
    defer testing.allocator.free(uppered);

    try testing.expectEqualStrings("STRASSE FFI", uppered);
}

test "toLowerAlloc default sigma handling" {
    {
        const lowered = try toLowerAlloc(testing.allocator, "ΟΣ");
        defer testing.allocator.free(lowered);
        try testing.expectEqualStrings("ος", lowered);
    }

    {
        const lowered = try toLowerAlloc(testing.allocator, "ΟΣΑ");
        defer testing.allocator.free(lowered);
        try testing.expectEqualStrings("οσα", lowered);
    }

    {
        const lowered = try toLowerAlloc(testing.allocator, "ΟΣ.Σ");
        defer testing.allocator.free(lowered);
        try testing.expectEqualStrings("οσ.ς", lowered);
    }
}

test "full casing returns null for identity" {
    try testing.expectEqual(@as(?[]const u21, null), lowerMapped('a'));
    try testing.expectEqual(@as(?[]const u21, null), titleMapped('A'));
    try testing.expectEqual(@as(?[]const u21, null), upperMapped('A'));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const Writer = std.Io.Writer;
