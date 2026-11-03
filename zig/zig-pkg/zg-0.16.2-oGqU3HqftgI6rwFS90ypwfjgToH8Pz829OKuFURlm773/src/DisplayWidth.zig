//! Display Width module
//!
//! Answers questions about the printable width in monospaced fonts of the
//! string of interest.

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const i4 = undefined,
};

const display_width = display_width: {
    const data = @import("dwp");
    break :display_width Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

const DisplayWidth = @This();

/// codePointWidth returns the number of cells `cp` requires when rendered
/// in a fixed-pitch font (i.e. a terminal screen). This can range from -1 to
/// 3, where BACKSPACE and DELETE return -1 and 3-em-dash returns 3. C0/C1
/// control codes return 0. If `cjk` is true, ambiguous code points return 2,
/// otherwise they return 1.  Gives misleading results if the codepoint is
/// a part of a grapheme cluster.
pub fn codePointWidth(cp: u21) i4 {
    return display_width.s2[display_width.s1[cp >> 8] + (cp & 0xff)];
}

test "codePointWidth" {
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x0000)); // null
    try testing.expectEqual(@as(i4, -1), DisplayWidth.codePointWidth(0x8)); // \b
    try testing.expectEqual(@as(i4, -1), DisplayWidth.codePointWidth(0x7f)); // DEL
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x0005)); // Cf
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x0007)); // \a BEL
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x000A)); // \n LF
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x000B)); // \v VT
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x000C)); // \f FF
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x000D)); // \r CR
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x000E)); // SQ
    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x000F)); // SI

    try testing.expectEqual(@as(i4, 0), DisplayWidth.codePointWidth(0x070F)); // Cf
    try testing.expectEqual(@as(i4, 1), DisplayWidth.codePointWidth(0x0603)); // Cf Arabic

    try testing.expectEqual(@as(i4, 1), DisplayWidth.codePointWidth(0x00AD)); // soft-hyphen
    try testing.expectEqual(@as(i4, 2), DisplayWidth.codePointWidth(0x2E3A)); // two-em dash
    try testing.expectEqual(@as(i4, 3), DisplayWidth.codePointWidth(0x2E3B)); // three-em dash

    try testing.expectEqual(@as(i4, 1), DisplayWidth.codePointWidth(0x00BD)); // ambiguous halfwidth

    try testing.expectEqual(@as(i4, 1), DisplayWidth.codePointWidth('é'));
    try testing.expectEqual(@as(i4, 2), DisplayWidth.codePointWidth('😊'));
    try testing.expectEqual(@as(i4, 2), DisplayWidth.codePointWidth('统'));
}

/// graphemeWidth returns the total display width of `gc` as the number
/// of cells required in a fixed-pitch font (i.e. a terminal screen).
/// `gc` is a slice corresponding to one grapheme cluster.
pub fn graphemeWidth(gc: []const u8) isize {
    var cp_iter = CodePointIterator{ .bytes = gc };
    var gc_total: isize = 0;

    while (cp_iter.next()) |cp| {
        var w = DisplayWidth.codePointWidth(cp.code);

        if (w != 0) {
            // Handle text emoji sequence.
            if (cp_iter.next()) |ncp| {
                // emoji text sequence.
                if (ncp.code == 0xFE0E) w = 1;
                if (ncp.code == 0xFE0F) w = 2;
                // Skin tones
                if (0x1F3FB <= ncp.code and ncp.code <= 0x1F3FF) w = 2;
            }

            // Only adding width of first non-zero-width code point.
            gc_total = w;
            break;
        }
    }
    return gc_total;
}

/// strWidth returns the total display width of `str` as the number of cells
/// required in a fixed-pitch font (i.e. a terminal screen).
pub fn strWidth(str: []const u8) usize {
    var total: isize = 0;

    // ASCII fast path
    if (ascii.isAsciiOnly(str)) {
        for (str) |b| total += DisplayWidth.codePointWidth(b);
        return @intCast(@max(0, total));
    }

    var giter = Graphemes.iterator(str);

    while (giter.next()) |gc| {
        total += DisplayWidth.graphemeWidth(gc.bytes(str));
    }

    return @intCast(@max(0, total));
}

test "strWidth" {
    const c0 = options.c0_width orelse 0;

    try testing.expectEqual(@as(usize, 5), DisplayWidth.strWidth("Hello\r\n"));
    try testing.expectEqual(@as(usize, 1), DisplayWidth.strWidth("\u{0065}\u{0301}"));
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("\u{1F476}\u{1F3FF}\u{0308}\u{200D}\u{1F476}\u{1F3FF}"));
    try testing.expectEqual(@as(usize, 8), DisplayWidth.strWidth("Hello 😊"));
    try testing.expectEqual(@as(usize, 8), DisplayWidth.strWidth("Héllo 😊"));
    try testing.expectEqual(@as(usize, 8), DisplayWidth.strWidth("Héllo :)"));
    try testing.expectEqual(@as(usize, 8), DisplayWidth.strWidth("Héllo 🇪🇸"));
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("\u{26A1}")); // Lone emoji
    try testing.expectEqual(@as(usize, 1), DisplayWidth.strWidth("\u{26A1}\u{FE0E}")); // Text sequence
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("\u{26A1}\u{FE0F}")); // Presentation sequence
    try testing.expectEqual(@as(usize, 1), DisplayWidth.strWidth("\u{2764}")); // Default text presentation
    try testing.expectEqual(@as(usize, 1), DisplayWidth.strWidth("\u{2764}\u{FE0E}")); // Default text presentation with VS15 selector
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("\u{2764}\u{FE0F}")); // Default text presentation with VS16 selector
    const expect_bs: usize = if (c0 == 0) 0 else 1 + c0;
    try testing.expectEqual(expect_bs, DisplayWidth.strWidth("A\x08")); // Backspace
    try testing.expectEqual(expect_bs, DisplayWidth.strWidth("\x7FA")); // DEL
    const expect_long_del: usize = if (c0 == 0) 0 else 1 + (c0 * 3);
    try testing.expectEqual(expect_long_del, DisplayWidth.strWidth("\x7FA\x08\x08")); // never less than 0

    // wcwidth Python lib tests. See: https://github.com/jquast/wcwidth/blob/master/tests/test_core.py
    const empty = "";
    try testing.expectEqual(@as(usize, 0), DisplayWidth.strWidth(empty));
    const with_null = "hello\x00world";
    try testing.expectEqual(@as(usize, 10 + c0), DisplayWidth.strWidth(with_null));
    const hello_jp = "コンニチハ, セカイ!";
    try testing.expectEqual(@as(usize, 19), DisplayWidth.strWidth(hello_jp));
    const control = "\x1b[0m";
    try testing.expectEqual(@as(usize, 3 + c0), DisplayWidth.strWidth(control));
    const balinese = "\u{1B13}\u{1B28}\u{1B2E}\u{1B44}";
    try testing.expectEqual(@as(usize, 3), DisplayWidth.strWidth(balinese));

    // These commented out tests require a new specification for complex scripts.
    // See: https://www.unicode.org/L2/L2023/23107-terminal-suppt.pdf
    // const jamo = "\u{1100}\u{1160}";
    // try testing.expectEqual(@as(usize, 3), strWidth(jamo));
    // const devengari = "\u{0915}\u{094D}\u{0937}\u{093F}";
    // try testing.expectEqual(@as(usize, 3), strWidth(devengari));
    // const tamal = "\u{0b95}\u{0bcd}\u{0bb7}\u{0bcc}";
    // try testing.expectEqual(@as(usize, 5), strWidth(tamal));
    // const kannada_1 = "\u{0cb0}\u{0ccd}\u{0c9d}\u{0cc8}";
    // try testing.expectEqual(@as(usize, 3), strWidth(kannada_1));
    // The following passes but as a mere coincidence.
    const kannada_2 = "\u{0cb0}\u{0cbc}\u{0ccd}\u{0c9a}";
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth(kannada_2));

    // From Rust https://github.com/jameslanska/unicode-display-width
    try testing.expectEqual(@as(usize, 15), DisplayWidth.strWidth("🔥🗡🍩👩🏻‍🚀⏰💃🏼🔦👍🏻"));
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("🦀"));
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("👨‍👩‍👧‍👧"));
    try testing.expectEqual(@as(usize, 2), DisplayWidth.strWidth("👩‍🔬"));
    try testing.expectEqual(@as(usize, 9), DisplayWidth.strWidth("sane text"));
    try testing.expectEqual(@as(usize, 9), DisplayWidth.strWidth("Ẓ̌á̲l͔̝̞̄̑͌g̖̘̘̔̔͢͞͝o̪̔T̢̙̫̈̍͞e̬͈͕͌̏͑x̺̍ṭ̓̓ͅ"));
    try testing.expectEqual(@as(usize, 17), DisplayWidth.strWidth("슬라바 우크라이나"));
    try testing.expectEqual(@as(usize, 1), DisplayWidth.strWidth("\u{378}"));

    // https://codeberg.org/atman/zg/issues/82
    try testing.expectEqual(@as(usize, 12), DisplayWidth.strWidth("✍️✍🏻✍🏼✍🏽✍🏾✍🏿"));
}

/// centers `str` in a new string of width `total_width` (in display cells) using `pad` as padding.
/// If the length of `str` and `total_width` have different parity, the right side of `str` will
/// receive one additional pad. This makes sure the returned string fills the requested width.
/// Caller must free returned bytes with `allocator`.
pub fn center(
    allocator: mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    const str_width = DisplayWidth.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;
    if (str_width == total_width) return try allocator.dupe(u8, str);

    const pad_width = DisplayWidth.strWidth(pad);
    if (pad_width == 0) return error.PadTooLong;

    const remaining_width = total_width - str_width;
    if (pad_width > remaining_width) return error.PadTooLong;

    const left_pads = (remaining_width / 2) / pad_width;
    const left_width = left_pads * pad_width;
    const right_width = remaining_width - left_width;
    if (right_width % pad_width != 0) return error.PadTooLong;

    const extra_pad = right_width / pad_width - left_pads;
    const pads = left_pads * 2 + extra_pad;

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    while (pads_index < pads / 2) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    @memcpy(result[bytes_index..][0..str.len], str);
    bytes_index += str.len;

    pads_index = 0;
    while (pads_index < pads / 2 + extra_pad) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    return result;
}

test "center" {
    const allocator = testing.allocator;

    // Input and width both have odd length
    var centered = try DisplayWidth.center(allocator, "abc", 9, "*");
    try testing.expectEqualSlices(u8, "***abc***", centered);

    // Input and width both have even length
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "---w😊w---", centered);

    // Input has even length, width has odd length
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "1234", 9, "-");
    try testing.expectEqualSlices(u8, "--1234---", centered);

    // Input has odd length, width has even length
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "123", 8, "-");
    try testing.expectEqualSlices(u8, "--123---", centered);

    // Input is the same length as the width
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "123", 3, "-");
    try testing.expectEqualSlices(u8, "123", centered);

    // Input is empty
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "", 3, "-");
    try testing.expectEqualSlices(u8, "---", centered);

    // Input is empty and width is zero
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "", 0, "-");
    try testing.expectEqualSlices(u8, "", centered);

    // Input is longer than the width, which is an error
    allocator.free(centered);
    try testing.expectError(error.StrTooLong, DisplayWidth.center(allocator, "123", 2, "-"));

    // Input is one display cell narrower than the width
    allocator.free(centered);
    centered = try DisplayWidth.center(allocator, "ab", 3, " ");
    try testing.expectEqualSlices(u8, "ab ", centered);
    allocator.free(centered);
}

/// padLeft returns a new string of width `total_width` (in display cells) using `pad` as padding
/// on the left side. Caller must free returned bytes with `allocator`.
pub fn padLeft(
    allocator: mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    const str_width = DisplayWidth.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;

    const pad_width = DisplayWidth.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = total_width - str_width;
    if (pad_width > margin_width) return error.PadTooLong;

    const pads = @divFloor(margin_width, pad_width);

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    while (pads_index < pads) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    @memcpy(result[bytes_index..][0..str.len], str);

    return result;
}

test "padLeft" {
    const allocator = testing.allocator;

    var right_aligned = try DisplayWidth.padLeft(allocator, "abc", 9, "*");
    defer allocator.free(right_aligned);
    try testing.expectEqualSlices(u8, "******abc", right_aligned);

    allocator.free(right_aligned);
    right_aligned = try DisplayWidth.padLeft(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "------w😊w", right_aligned);
}

/// padRight returns a new string of width `total_width` (in display cells) using `pad` as padding
/// on the right side.  Caller must free returned bytes with `allocator`.
pub fn padRight(
    allocator: mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    const str_width = DisplayWidth.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;

    const pad_width = DisplayWidth.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = total_width - str_width;
    if (pad_width > margin_width) return error.PadTooLong;

    const pads = @divFloor(margin_width, pad_width);

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    @memcpy(result[bytes_index..][0..str.len], str);
    bytes_index += str.len;

    while (pads_index < pads) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    return result;
}

test "padRight" {
    const allocator = testing.allocator;

    var left_aligned = try DisplayWidth.padRight(allocator, "abc", 9, "*");
    defer testing.allocator.free(left_aligned);
    try testing.expectEqualSlices(u8, "abc******", left_aligned);

    testing.allocator.free(left_aligned);
    left_aligned = try DisplayWidth.padRight(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "w😊w------", left_aligned);
}

/// Wraps a string approximately at the given number of columns per line.
/// `threshold` defines how far the last column of the last word can be
/// from the edge.  Caller must free returned bytes with `allocator`.
pub fn wrap(
    allocator: mem.Allocator,
    str: []const u8,
    columns: usize,
    threshold: usize,
) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var line_iter = mem.tokenizeAny(u8, str, "\r\n");
    var line_width: usize = 0;

    while (line_iter.next()) |line| {
        var word_iter = mem.tokenizeScalar(u8, line, ' ');

        while (word_iter.next()) |word| {
            try result.appendSlice(word);
            try result.append(' ');
            line_width += DisplayWidth.strWidth(word) + 1;

            if (line_width > columns or columns - line_width <= threshold) {
                try result.append('\n');
                line_width = 0;
            }
        }
    }

    // Remove trailing space and newline.
    if (result.items[result.items.len - 1] == '\n')
        _ = result.pop();
    if (result.items[result.items.len - 1] == ' ')
        _ = result.pop();

    return try result.toOwnedSlice();
}

test "wrap" {
    const allocator = testing.allocator;

    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const got = try DisplayWidth.wrap(allocator, input, 10, 3);
    defer testing.allocator.free(got);
    const want = "The quick \nbrown fox \njumped \nover the \nlazy dog!";
    try testing.expectEqualStrings(want, got);
}

test "zg/74" {
    const allocator = testing.allocator;
    const wrapped = try DisplayWidth.wrap(allocator, "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam pellentesque pulvinar felis, sit amet commodo ligula feugiat sed. Sed quis malesuada elit, nec eleifend lectus. Sed tincidunt finibus aliquet. Praesent consectetur nibh libero, tempus imperdiet lorem congue eget.", 16, 1);
    defer allocator.free(wrapped);
    const expected_wrap = "Lorem ipsum dolor \nsit amet, consectetur \nadipiscing elit. \nNullam pellentesque \npulvinar felis, \nsit amet commodo \nligula feugiat \nsed. Sed quis malesuada \nelit, nec eleifend \nlectus. Sed tincidunt \nfinibus aliquet. \nPraesent consectetur \nnibh libero, tempus \nimperdiet lorem \ncongue eget.";
    try std.testing.expectEqualStrings(expected_wrap, wrapped);
}

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const mem = std.mem;
const Allocator = mem.Allocator;
const simd = std.simd;
const testing = std.testing;

const ascii = @import("ascii");
const CodePointIterator = @import("code_point").Iterator;

const Graphemes = @import("Graphemes");
