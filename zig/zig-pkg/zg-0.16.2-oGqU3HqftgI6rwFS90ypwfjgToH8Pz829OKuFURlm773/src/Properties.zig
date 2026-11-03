//! Properties module

const Data = struct {
    core_s1: []const u16 = undefined,
    core_s2: []const u8 = undefined,
    props_s1: []const u16 = undefined,
    props_s2: []const u8 = undefined,
    num_s1: []const u16 = undefined,
    num_s2: []const u8 = undefined,
};

const properties = properties: {
    const core_props = @import("core_props");
    const props_data = @import("props");
    const numeric = @import("numeric");
    break :properties Data{
        .core_s1 = &core_props.s1,
        .core_s2 = &core_props.s2,
        .props_s1 = &props_data.s1,
        .props_s2 = &props_data.s2,
        .num_s1 = &numeric.s1,
        .num_s2 = &numeric.s2,
    };
};

const Properties = @This();

/// True if `cp` is a mathematical symbol.
pub fn isMath(cp: u21) bool {
    return properties.core_s2[properties.core_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is an alphabetic character.
pub fn isAlphabetic(cp: u21) bool {
    return properties.core_s2[properties.core_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is a valid identifier start character.
pub fn isIdStart(cp: u21) bool {
    return properties.core_s2[properties.core_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

/// True if `cp` is a valid identifier continuation character.
pub fn isIdContinue(cp: u21) bool {
    return properties.core_s2[properties.core_s1[cp >> 8] + (cp & 0xff)] & 8 == 8;
}

/// True if `cp` is a valid extended identifier start character.
pub fn isXidStart(cp: u21) bool {
    return properties.core_s2[properties.core_s1[cp >> 8] + (cp & 0xff)] & 16 == 16;
}

/// True if `cp` is a valid extended identifier continuation character.
pub fn isXidContinue(cp: u21) bool {
    return properties.core_s2[properties.core_s1[cp >> 8] + (cp & 0xff)] & 32 == 32;
}

/// True if `cp` is a whitespace character.
pub fn isWhitespace(cp: u21) bool {
    return properties.props_s2[properties.props_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is a hexadecimal digit.
pub fn isHexDigit(cp: u21) bool {
    return properties.props_s2[properties.props_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is a diacritic mark.
pub fn isDiacritic(cp: u21) bool {
    return properties.props_s2[properties.props_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

/// True if `cp` is numeric.
pub fn isNumeric(cp: u21) bool {
    return properties.num_s2[properties.num_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is a digit.
pub fn isDigit(cp: u21) bool {
    return properties.num_s2[properties.num_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is decimal.
pub fn isDecimal(cp: u21) bool {
    return properties.num_s2[properties.num_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

test "Props" {
    try testing.expect(Properties.isHexDigit('F'));
    try testing.expect(Properties.isHexDigit('a'));
    try testing.expect(Properties.isHexDigit('8'));
    try testing.expect(!Properties.isHexDigit('z'));

    try testing.expect(Properties.isDiacritic('\u{301}'));
    try testing.expect(Properties.isAlphabetic('A'));
    try testing.expect(!Properties.isAlphabetic('3'));
    try testing.expect(Properties.isMath('+'));

    try testing.expect(Properties.isNumeric('\u{277f}'));
    try testing.expect(Properties.isDigit('\u{2070}'));
    try testing.expect(Properties.isDecimal('3'));

    try testing.expect(!Properties.isNumeric('1'));
    try testing.expect(!Properties.isDigit('2'));
    try testing.expect(!Properties.isDecimal('g'));
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
