//! Emoji module

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u6 = undefined,
};

const emoji = emoji: {
    const data = @import("emoji");
    break :emoji Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

// This must be an exact match of `Emoji` from `codegen/emoji.zig`.
pub const Properties = packed struct {
    Emoji: bool = false,
    Emoji_Presentation: bool = false,
    Emoji_Modifier: bool = false,
    Emoji_Modifier_Base: bool = false,
    Emoji_Component: bool = false,
    Extended_Pictographic: bool = false,
};

/// Lookup the emoji properties for a code point.
fn properties(cp: u21) Properties {
    return @bitCast(emoji.s2[emoji.s1[cp >> 8] + (cp & 0xff)]);
}

pub fn isEmoji(cp: u21) bool {
    return properties(cp).Emoji;
}

pub fn isEmojiPresentation(cp: u21) bool {
    return properties(cp).Emoji_Presentation;
}

pub fn isEmojiModifier(cp: u21) bool {
    return properties(cp).Emoji_Modifier;
}

pub fn isEmojiModifierBase(cp: u21) bool {
    return properties(cp).Emoji_Modifier_Base;
}

pub fn isEmojiComponent(cp: u21) bool {
    return properties(cp).Emoji_Component;
}

pub fn isExtendedPictographic(cp: u21) bool {
    return properties(cp).Extended_Pictographic;
}

test "isEmoji" {
    try std.testing.expect(isEmoji(0x1F415)); // 🐕
    try std.testing.expect(!isEmoji(0x3042)); // あ
}

test "isEmojiPresentation" {
    try std.testing.expect(isEmojiPresentation(0x1F408)); // 🐈
    try std.testing.expect(!isEmojiPresentation(0x267E)); // ♾
}

test "isEmojiModifier" {
    try std.testing.expect(isEmojiModifier(0x1F3FF)); //
    try std.testing.expect(!isEmojiModifier(0x1F385)); // 🎅
}

test "isEmojiModifierBase" {
    try std.testing.expect(isEmojiModifierBase(0x1F977)); // 🥷
    try std.testing.expect(!isEmojiModifierBase(0x1F4F8)); // 📸
}

test "isEmojiComponent" {
    try std.testing.expect(isEmojiComponent(0x1F9B0)); // 🦰
    try std.testing.expect(!isEmojiComponent(0x1F9B5)); // 🦵
}

test "isExtendedPictographic" {
    try std.testing.expect(isExtendedPictographic(0x1F005)); // 🀅
    try std.testing.expect(!isExtendedPictographic(0x2A)); // *
}

const std = @import("std");
const builtin = @import("builtin");
const unicode = std.unicode;

const CodePoint = @import("code_point").CodePoint;
const CodePointIterator = @import("code_point").Iterator;
