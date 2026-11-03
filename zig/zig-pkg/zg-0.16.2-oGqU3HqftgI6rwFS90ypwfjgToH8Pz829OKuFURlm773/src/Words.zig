//! Word Breaking Algorithm.
//!
//! https://www.unicode.org/reports/tr29/#Word_Boundaries
//!

const Words = @This();

const WordBreakProperty = enum(u5) {
    none,
    Double_Quote,
    Single_Quote,
    Hebrew_Letter,
    CR,
    LF,
    Newline,
    Extend,
    Regional_Indicator,
    Format,
    Katakana,
    ALetter,
    MidLetter,
    MidNum,
    MidNumLet,
    Numeric,
    ExtendNumLet,
    ZWJ,
    WSegSpace,
};

const Data = struct {
    s1: []const u16 = undefined,
    s2: []const u5 = undefined,
};

const wbp = display_width: {
    const data = @import("wbp");
    break :display_width Data{
        .s1 = &data.s1,
        .s2 = &data.s2,
    };
};

pub const TitleStatus = enum(i2) {
    not_cased = -1,
    no,
    yes,
};

/// Represents a Unicode word span, as an offset into the source string
/// and the length of the word.
pub const Word = struct {
    offset: uoffset,
    len: uoffset,

    /// Returns a slice of the word given the source string.
    pub fn bytes(word: Word, src: []const u8) []const u8 {
        return src[word.offset..][0..word.len];
    }

    /// Check if a word is in title case, with three answers: `.no`,
    /// `.yes`, and `.not_cased`.
    pub fn isTitlecased(word: Word, src: []const u8) TitleStatus {
        // Implementation of Unicode 17 § 3.13.2 R3
        const span = src[word.offset..][0..word.len];
        var iter: CodepointIterator = .init(span);
        var saw_cased = false;
        while (iter.next()) |cp| {
            if (letter_case.isCased(cp.code)) {
                if (!saw_cased) {
                    if (letter_case.titleMapped(cp.code)) |_| return .no;
                    saw_cased = true;
                } else {
                    if (letter_case.lowerMapped(cp.code)) |_| return .no;
                }
            }
        }
        return if (saw_cased) .yes else .not_cased;
    }

    /// Write this word in title case to the Writer.  Note that this performs no
    /// tailoring, and as such will generate words like `Is` which are generally
    /// not part of English titles, with similar considerations applying in
    /// detail to other cased languages.
    pub fn writeTitlecased(word: Word, src: []const u8, writer: *std.Io.Writer) !void {
        const span = src[word.offset..][0..word.len];
        var iter: CodepointIterator = .init(span);
        var saw_cased = false;
        var buf: [4]u8 = undefined;

        while (iter.next()) |cp| {
            if (!saw_cased and letter_case.isCased(cp.code)) {
                if (letter_case.titleMapped(cp.code)) |mapping| {
                    for (mapping) |mapped| {
                        const len = unicode.utf8Encode(mapped, &buf) catch unreachable;
                        try writer.writeAll(buf[0..len]);
                    }
                } else {
                    const len = unicode.utf8Encode(cp.code, &buf) catch unreachable;
                    try writer.writeAll(buf[0..len]);
                }
                saw_cased = true;
                continue;
            }

            if (saw_cased) {
                if (letter_case.lowerMapped(cp.code)) |mapping| {
                    for (mapping) |mapped| {
                        const len = unicode.utf8Encode(mapped, &buf) catch unreachable;
                        try writer.writeAll(buf[0..len]);
                    }
                } else {
                    const len = unicode.utf8Encode(cp.code, &buf) catch unreachable;
                    try writer.writeAll(buf[0..len]);
                }
            } else {
                const len = unicode.utf8Encode(cp.code, &buf) catch unreachable;
                try writer.writeAll(buf[0..len]);
            }
        }
    }

    /// Copy the word's span, transforming it to tilecase if applicable.  Always
    /// returns a copy, even if nothing changes: `isTitleCased` answers whether
    /// this function will return changed text.
    pub fn toTitlecaseAlloc(word: Word, src: []const u8, alocator: Allocator) OOM![]const u8 {
        var allocating = std.Io.Writer.Allocating.init(alocator);
        defer allocating.deinit();

        writeTitlecased(word, src, &allocating.writer) catch return error.OutOfMemory;
        return try allocating.toOwnedSlice();
    }
};

/// Returns the word break property type for `cp`.
pub fn breakProperty(cp: u21) WordBreakProperty {
    return @enumFromInt(wbp.s2[wbp.s1[cp >> 8] + (cp & 0xff)]);
}

/// Convenience function for working with CodePoints
fn breakProp(point: CodePoint) WordBreakProperty {
    return @enumFromInt(wbp.s2[wbp.s1[point.code >> 8] + (point.code & 0xff)]);
}

/// Returns the Word at the given index.  Asserts that the index is less than
/// `string.len`, and that the string is not empty. Always returns a word.
/// The index does not have to be the start of a codepoint in the word.
pub fn wordAtIndex(string: []const u8, index: usize) Word {
    assert(index < string.len and string.len > 0);
    var iter_back: ReverseIterator = reverseFromIndex(string, index);
    const first_back = iter_back.prev();
    if (first_back) |back| {
        if (back.offset == 0) {
            var iter_fwd = Words.iterator(string);
            while (iter_fwd.next()) |word| {
                if (word.offset <= index and index < word.offset + word.len)
                    return word;
            }
        }
    } else {
        var iter_fwd = Words.iterator(string);
        while (iter_fwd.next()) |word| {
            if (word.offset <= index and index < word.offset + word.len)
                return word;
        }
    }
    _ = iter_back.prev();
    // There's sometimes flags:
    if (iter_back.flags > 0) {
        while (iter_back.flags > 0) {
            if (iter_back.prev()) |_| {
                continue;
            } else {
                break;
            }
        }
    }
    var iter_fwd = iter_back.forwardIterator();
    while (iter_fwd.next()) |word| {
        if (word.offset <= index and index < word.offset + word.len)
            return word;
    }
    unreachable;
}

/// Returns an iterator over words in `slice`.
pub fn iterator(slice: []const u8) Iterator {
    return Iterator.init(slice);
}

/// Returns a reverse iterator over the words in `slice`.
pub fn reverseIterator(slice: []const u8) ReverseIterator {
    return ReverseIterator.init(slice);
}

/// Returns an iterator after the `word` in `slice`.
pub fn iterateAfterWord(slice: []const u8, word: Word) Iterator {
    return forwardFromIndex(slice, word.offset + word.len);
}

/// Returns a reverse iterator before the `word` in `slice`.
pub fn iterateBeforeWord(slice: []const u8, word: Word) ReverseIterator {
    return reverseFromIndex(slice, word.offset);
}

/// An iterator, forward, over all words in a provided string.
pub const Iterator = struct {
    this: ?CodePoint = null,
    that: ?CodePoint = null,
    cp_iter: CodepointIterator,

    /// Assumes `str` is valid UTF-8.
    pub fn init(str: []const u8) Iterator {
        var wb_iter: Iterator = .{ .cp_iter = .init(str) };
        wb_iter.advance();
        return wb_iter;
    }

    /// Returns the next word segment, without advancing.
    pub fn peek(iter: *Iterator) ?Word {
        const cache = .{ iter.this, iter.that, iter.cp_iter };
        defer {
            iter.this, iter.that, iter.cp_iter = cache;
        }
        return iter.next();
    }

    /// Returns a reverse iterator from the point this iterator is paused
    /// at.  Usually, and always when using the API to create iterators,
    /// calling `prev()` will return the word just seen.
    pub fn reverseIterator(iter: *Iterator) ReverseIterator {
        var cp_it = iter.cp_iter.reverseIterator();
        if (iter.that) |_|
            _ = cp_it.prev();
        if (iter.cp_iter.peek()) |_|
            _ = cp_it.prev();
        return .{
            .before = cp_it.prev(),
            .after = iter.that,
            .cp_iter = cp_it,
        };
    }

    /// Returns the next word segment, if any.
    pub fn next(iter: *Iterator) ?Word {
        iter.advance();

        // Done?
        if (iter.this == null) return null;
        // Last?
        if (iter.that == null) return Word{ .len = iter.this.?.len, .offset = iter.this.?.offset };

        const word_start = iter.this.?.offset;
        var word_len: uoffset = 0;

        // State variables.
        var last_p: WordBreakProperty = .none;
        var last_last_p: WordBreakProperty = .none;
        var ri_count: usize = 0;

        scan: while (true) : (iter.advance()) {
            const this = iter.this.?;
            word_len += this.len;
            if (iter.that) |that| {
                const this_p = Words.breakProp(this);
                const that_p = Words.breakProp(that);
                if (!isIgnorable(this_p)) {
                    last_last_p = last_p;
                    last_p = this_p;
                }
                // WB3  CR × LF
                if (this_p == .CR and that_p == .LF) continue :scan;
                // WB3a  (Newline | CR | LF) ÷
                if (isNewline(this_p)) break :scan;
                // WB3b  ÷ (Newline | CR | LF)
                if (isNewline(that_p)) break :scan;
                // WB3c  ZWJ × \p{Extended_Pictographic}
                if (this_p == .ZWJ and ext_pict.isMatch(that.bytes(iter.cp_iter.bytes))) {
                    continue :scan;
                }
                // WB3d  WSegSpace × WSegSpace
                if (this_p == .WSegSpace and that_p == .WSegSpace) continue :scan;
                // WB4  X (Extend | Format | ZWJ)* → X
                if (isIgnorable(that_p)) {
                    continue :scan;
                } // Now we use last_p instead of this_p for ignorable's sake
                if (isAHLetter(last_p)) {
                    // WB5  AHLetter × AHLetter
                    if (isAHLetter(that_p)) continue :scan;
                    // WB6  AHLetter × (MidLetter | MidNumLetQ) AHLetter
                    if (isMidVal(that_p)) {
                        const next_val = iter.peekPast();
                        if (next_val) |next_cp| {
                            const next_p = Words.breakProp(next_cp);
                            if (isAHLetter(next_p)) {
                                continue :scan;
                            }
                        }
                    }
                }
                // WB7 AHLetter (MidLetter | MidNumLetQ) × AHLetter
                if (isAHLetter(last_last_p) and isMidVal(last_p) and isAHLetter(that_p)) {
                    continue :scan;
                }
                if (last_p == .Hebrew_Letter) {
                    // WB7a  Hebrew_Letter × Single_Quote
                    if (that_p == .Single_Quote) continue :scan;
                    // WB7b  Hebrew_Letter × Double_Quote Hebrew_Letter
                    if (that_p == .Double_Quote) {
                        const next_val = iter.peekPast();
                        if (next_val) |next_cp| {
                            const next_p = Words.breakProp(next_cp);
                            if (next_p == .Hebrew_Letter) {
                                continue :scan;
                            }
                        }
                    }
                }
                // WB7c  Hebrew_Letter Double_Quote × Hebrew_Letter
                if (last_last_p == .Hebrew_Letter and last_p == .Double_Quote and that_p == .Hebrew_Letter)
                    continue :scan;
                // WB8  Numeric × Numeric
                if (last_p == .Numeric and that_p == .Numeric) continue :scan;
                // WB9  AHLetter × Numeric
                if (isAHLetter(last_p) and that_p == .Numeric) continue :scan;
                // WB10  Numeric ×  AHLetter
                if (last_p == .Numeric and isAHLetter(that_p)) continue :scan;
                // WB11  Numeric (MidNum | MidNumLetQ) × Numeric
                if (last_last_p == .Numeric and isMidNum(last_p) and that_p == .Numeric)
                    continue :scan;
                // WB12  Numeric × (MidNum | MidNumLetQ) Numeric
                if (last_p == .Numeric and isMidNum(that_p)) {
                    const next_val = iter.peekPast();
                    if (next_val) |next_cp| {
                        const next_p = Words.breakProp(next_cp);
                        if (next_p == .Numeric) {
                            continue :scan;
                        }
                    }
                }
                // WB13  Katakana × Katakana
                if (last_p == .Katakana and that_p == .Katakana) continue :scan;
                // WB13a  (AHLetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
                if (isExtensible(last_p) and that_p == .ExtendNumLet) continue :scan;
                // WB13b  ExtendNumLet × (AHLetter | Numeric | Katakana)
                if (last_p == .ExtendNumLet and isExtensible(that_p)) continue :scan;
                // WB15, WB16  ([^RI] | sot) (RI RI)* RI × RI
                const maybe_flag = that_p == .Regional_Indicator and last_p == .Regional_Indicator;
                if (maybe_flag) {
                    ri_count += 1;
                    if (ri_count % 2 == 1) continue :scan;
                }
                // WB999  Any ÷ Any
                break :scan;
            } else { // iter.that == null
                break :scan;
            }
        }

        return Word{ .len = word_len, .offset = word_start };
    }

    pub fn format(iter: Iterator, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print(
            "Iterator {{ .this = {any}, .that = {any} }}",
            .{ iter.this, iter.that },
        );
    }

    fn advance(iter: *Iterator) void {
        iter.this = iter.that;
        iter.that = iter.cp_iter.next();
    }

    fn peekPast(iter: *Iterator) ?CodePoint {
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.peek()) |peeked| {
            if (!isIgnorable(Words.breakProp(peeked))) return peeked;
            _ = iter.cp_iter.next();
        }
        return null;
    }
};

/// An iterator, backward, over all words in a provided string.
pub const ReverseIterator = struct {
    after: ?CodePoint = null,
    before: ?CodePoint = null,
    cp_iter: ReverseCodepointIterator,
    flags: usize = 0,

    /// Assumes `str` is valid UTF-8.
    pub fn init(str: []const u8) ReverseIterator {
        var wb_iter: ReverseIterator = .{ .cp_iter = .init(str) };
        wb_iter.advance();
        return wb_iter;
    }

    /// Returns the previous word segment, if any, without advancing.
    pub fn peek(iter: *ReverseIterator) ?Word {
        const cache = .{ iter.before, iter.after, iter.cp_iter, iter.flags };
        defer {
            iter.before, iter.after, iter.cp_iter, iter.flags = cache;
        }
        return iter.prev();
    }

    /// Return a forward iterator from where this iterator paused.  Usually,
    /// and always when using the API to create iterators, calling `next()`
    /// will return the word just seen.
    pub fn forwardIterator(iter: *ReverseIterator) Iterator {
        var cp_it = iter.cp_iter.forwardIterator();
        if (iter.before) |_|
            _ = cp_it.next();
        return .{
            .this = cp_it.next(),
            .that = iter.after,
            .cp_iter = cp_it,
        };
    }

    /// Return the previous word, if any.
    pub fn prev(iter: *ReverseIterator) ?Word {
        iter.advance();

        // Done?
        if (iter.after == null) return null;
        // Last?
        if (iter.before == null) return Word{ .len = iter.after.?.len, .offset = 0 };

        const word_end = iter.after.?.offset + iter.after.?.len;
        var word_len: uoffset = 0;

        // State variables.
        var last_p: WordBreakProperty = .none;
        var last_last_p: WordBreakProperty = .none;

        scan: while (true) : (iter.advance()) {
            const after = iter.after.?;
            word_len += after.len;
            if (iter.before) |before| {
                var sneak = sneaky(iter); // 'sneaks' past ignorables
                const after_p = Words.breakProp(after);
                var before_p = Words.breakProp(before);
                if (!isIgnorable(after_p)) {
                    last_last_p = last_p;
                    last_p = after_p;
                }
                // WB3  CR × LF
                if (before_p == .CR and after_p == .LF) continue :scan;
                // WB3a  (Newline | CR | LF) ÷
                if (isNewline(before_p)) break :scan;
                // WB3b  ÷ (Newline | CR | LF)
                if (isNewline(after_p)) break :scan;
                // WB3c  ZWJ × \p{Extended_Pictographic}
                if (before_p == .ZWJ and ext_pict.isMatch(after.bytes(iter.cp_iter.bytes))) {
                    continue :scan;
                }
                // WB3d  WSegSpace × WSegSpace
                if (before_p == .WSegSpace and after_p == .WSegSpace) continue :scan;
                // WB4  X (Extend | Format | ZWJ)* → X
                if (isIgnorable(before_p)) {
                    const maybe_before = sneak.prev();
                    if (maybe_before) |valid_before| {
                        before_p = Words.breakProp(valid_before);
                    } else if (!isIgnorable(after_p)) {
                        // We're done
                        break :scan;
                    }
                }
                if (isIgnorable(after_p)) continue :scan;
                // WB5  AHLetter × AHLetter
                if (isAHLetter(last_p) and isAHLetter(before_p)) {
                    continue :scan;
                }
                // WB6  AHLetter × (MidLetter | MidNumLetQ) AHLetter
                if (isAHLetter(before_p) and isMidVal(last_p) and isAHLetter(last_last_p)) {
                    continue :scan;
                }
                // WB7 AHLetter (MidLetter | MidNumLetQ) × AHLetter
                if (isMidVal(before_p) and isAHLetter(last_p)) {
                    const prev_val = sneak.peek();
                    if (prev_val) |prev_cp| {
                        const prev_p = Words.breakProp(prev_cp);
                        if (isAHLetter(prev_p)) {
                            continue :scan;
                        }
                    }
                }
                // WB7a  Hebrew_Letter × Single_Quote
                if (before_p == .Hebrew_Letter and last_p == .Single_Quote) continue :scan;
                // WB7b  Hebrew_Letter × Double_Quote Hebrew_Letter
                if (before_p == .Hebrew_Letter and last_p == .Double_Quote and last_last_p == .Hebrew_Letter) {
                    continue :scan;
                }
                // WB7c  Hebrew_Letter Double_Quote × Hebrew_Letter
                if (before_p == .Double_Quote and last_p == .Hebrew_Letter) {
                    const prev_val = sneak.peek();
                    if (prev_val) |prev_cp| {
                        const prev_p = Words.breakProp(prev_cp);
                        if (prev_p == .Hebrew_Letter) {
                            continue :scan;
                        }
                    }
                }
                // WB8  Numeric × Numeric
                if (before_p == .Numeric and last_p == .Numeric) continue :scan;
                // WB9  AHLetter × Numeric
                if (isAHLetter(before_p) and last_p == .Numeric) continue :scan;
                // WB10  Numeric ×  AHLetter
                if (before_p == .Numeric and isAHLetter(last_p)) continue :scan;
                // WB11  Numeric (MidNum | MidNumLetQ) × Numeric
                if (isMidNum(before_p) and last_p == .Numeric) {
                    const prev_val = sneak.peek();
                    if (prev_val) |prev_cp| {
                        const prev_p = Words.breakProp(prev_cp);
                        if (prev_p == .Numeric) {
                            continue :scan;
                        }
                    }
                }
                // WB12  Numeric × (MidNum | MidNumLetQ) Numeric
                if (before_p == .Numeric and isMidNum(last_p) and last_last_p == .Numeric) {
                    continue :scan;
                }
                // WB13  Katakana × Katakana
                if (before_p == .Katakana and last_p == .Katakana) continue :scan;
                // WB13a  (AHLetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
                if (isExtensible(before_p) and last_p == .ExtendNumLet) continue :scan;
                // WB13b  ExtendNumLet × (AHLetter | Numeric | Katakana)
                if (before_p == .ExtendNumLet and isExtensible(last_p)) continue :scan;
                // WB15, WB16  ([^RI] | sot) (RI RI)* RI × RI
                // NOTE:
                // So here we simply have to know whether a run of flags is even or odd.
                // The whole run.  To avoid quadratic behavior (and long flag runs are
                // actually a thing in the wild), we have to count them once, store that
                // on the iterator, and decrement each time we see two, possibly breaking
                // once extra at the beginning. They break up one per flag, once we hit
                // zero, that's all the flags.  If we see another flag we do it again.
                if (before_p == .Regional_Indicator and last_p == .Regional_Indicator) {
                    defer {
                        if (iter.flags > 0) iter.flags -= 1;
                    }
                    if (iter.flags == 0) {
                        iter.flags = sneak.countFlags();
                    }
                    if (iter.flags % 2 == 0) {
                        continue :scan;
                    }
                }
                // WB999  Any ÷ Any
                break :scan;
            }
            break :scan;
        }
        return Word{ .len = word_len, .offset = word_end - word_len };
    }

    pub fn format(iter: ReverseIterator, writer: anytype) !void {
        try writer.print(
            "ReverseIterator {{ .before = {any}, .after = {any}, .flags = {d} }}",
            .{ iter.before, iter.after, iter.flags },
        );
    }

    fn peekPast(iter: *ReverseIterator) ?CodePoint {
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.peek()) |peeked| {
            if (!isIgnorable(Words.breakProp(peeked))) return peeked;
            _ = iter.cp_iter.prev();
        }
        return null;
    }

    fn advance(iter: *ReverseIterator) void {
        iter.after = iter.before;
        iter.before = iter.cp_iter.prev();
    }
};

//| Implementation Details

/// Initialize a ReverseIterator at the provided index. Used in `wordAtIndex`.
fn reverseFromIndex(string: []const u8, index: usize) ReverseIterator {
    var idx: uoffset = @intCast(index);
    // Find the next lead byte:
    while (idx < string.len and 0x80 <= string[idx] and string[idx] <= 0xBf) : (idx += 1) {}
    if (idx == string.len) return Words.reverseIterator(string);
    var iter: ReverseIterator = undefined;
    iter.flags = 0;
    // We need to populate the CodePoints, and the codepoint iterator.
    // Consider "abc| def" with the cursor as |.
    // We need `before` to be `c` and `after` to be ' ',
    // and `cp_iter.prev()` to be `b`.
    var cp_iter: ReverseCodepointIterator = .{ .bytes = string, .i = idx };
    iter.after = cp_iter.prev();
    iter.before = cp_iter.prev();
    iter.cp_iter = cp_iter;
    return iter;
}

fn forwardFromIndex(string: []const u8, index: usize) Iterator {
    var idx: uoffset = @intCast(index);
    if (idx == string.len) {
        return .{
            .cp_iter = .{ .bytes = string, .i = idx },
            .this = null,
            .that = null,
        };
    }
    while (idx > 0 and 0x80 <= string[idx] and string[idx] <= 0xBf) : (idx -= 1) {}
    if (idx == 0) return Words.iterator(string);
    var iter: Iterator = undefined;
    // We need to populate the CodePoints, and the codepoint iterator.
    // Consider "abc |def" with the cursor as |.
    // We need `this` to be ` ` and `that` to be 'd',
    // and `cp_iter.next()` to be `d`.
    idx -= 1;
    while (idx > 0 and 0x80 <= string[idx] and string[idx] <= 0xBf) : (idx -= 1) {}
    // "abc| def"
    var cp_iter: CodepointIterator = .{ .bytes = string, .i = idx };
    iter.this = cp_iter.next();
    iter.that = cp_iter.next();
    iter.cp_iter = cp_iter;
    return iter;
}

fn sneaky(iter: *const ReverseIterator) SneakIterator {
    return .{ .cp_iter = iter.cp_iter };
}

const SneakIterator = struct {
    cp_iter: ReverseCodepointIterator,

    fn peek(iter: *SneakIterator) ?CodePoint {
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.peek()) |peeked| {
            if (!isIgnorable(Words.breakProp(peeked))) return peeked;
            _ = iter.cp_iter.prev();
        }
        return null;
    }

    fn countFlags(iter: *SneakIterator) usize {
        var flags: usize = 0;
        const save_cp = iter.cp_iter;
        defer iter.cp_iter = save_cp;
        while (iter.cp_iter.prev()) |cp| {
            const prop = Words.breakProp(cp);
            if (isIgnorable(prop)) continue;
            if (prop == .Regional_Indicator) {
                flags += 1;
            } else break;
        }
        return flags;
    }

    fn prev(iter: *SneakIterator) ?CodePoint {
        while (iter.cp_iter.prev()) |peeked| {
            if (!isIgnorable(Words.breakProp(peeked))) return peeked;
        }
        return null;
    }
};

//| Predicates

inline fn isNewline(w_prop: WordBreakProperty) bool {
    return w_prop == .CR or w_prop == .LF or w_prop == .Newline;
}

inline fn isIgnorable(w_prop: WordBreakProperty) bool {
    return switch (w_prop) {
        .Format, .Extend, .ZWJ => true,
        else => false,
    };
}

inline fn isAHLetter(w_prop: WordBreakProperty) bool {
    return w_prop == .ALetter or w_prop == .Hebrew_Letter;
}

inline fn isMidVal(w_prop: WordBreakProperty) bool {
    return w_prop == .MidLetter or w_prop == .MidNumLet or w_prop == .Single_Quote;
}

inline fn isMidNum(w_prop: WordBreakProperty) bool {
    return w_prop == .MidNum or w_prop == .MidNumLet or w_prop == .Single_Quote;
}

inline fn isExtensible(w_prop: WordBreakProperty) bool {
    return switch (w_prop) {
        .ALetter, .Hebrew_Letter, .Katakana, .Numeric, .ExtendNumLet => true,
        else => false,
    };
}

test "Word Break Properties" {
    try testing.expectEqual(.CR, Words.breakProperty('\r'));
    try testing.expectEqual(.LF, Words.breakProperty('\n'));
    try testing.expectEqual(.Hebrew_Letter, Words.breakProperty('ש'));
    try testing.expectEqual(.Katakana, Words.breakProperty('\u{30ff}'));
}

test "ext_pict" {
    try testing.expect(ext_pict.isMatch("👇"));
    try testing.expect(ext_pict.isMatch("\u{2701}"));
}

test "Words" {
    const word_str = "Metonym   Μετωνύμιο メトニム";
    var w_iter = Words.iterator(word_str);
    try testing.expectEqualStrings("Metonym", w_iter.next().?.bytes(word_str));
    // Spaces are "words" too!
    try testing.expectEqualStrings("   ", w_iter.next().?.bytes(word_str));
    const in_greek = w_iter.next().?;
    for (in_greek.offset..in_greek.offset + in_greek.len) |i| {
        const at_index = Words.wordAtIndex(word_str, i).bytes(word_str);
        try testing.expectEqualStrings("Μετωνύμιο", at_index);
    }
    _ = w_iter.next();
    try testing.expectEqualStrings("メトニム", w_iter.next().?.bytes(word_str));
}

test wordAtIndex {
    const t_string = "first second third";
    const second = Words.wordAtIndex(t_string, 8);
    try testing.expectEqualStrings("second", second.bytes(t_string));
    const third = Words.wordAtIndex(t_string, 14);
    try testing.expectEqualStrings("third", third.bytes(t_string));
    {
        const first = Words.wordAtIndex(t_string, 3);
        try testing.expectEqualStrings("first", first.bytes(t_string));
    }
    {
        const first = Words.wordAtIndex(t_string, 0);
        try testing.expectEqualStrings("first", first.bytes(t_string));
    }
    const last = Words.wordAtIndex(t_string, 14);
    try testing.expectEqualStrings("third", last.bytes(t_string));
}

const testr = "don't a:ka fin!";

test "reversal" {
    {
        var fwd = Words.iterator(testr);
        var this_word: ?Word = fwd.next();

        while (this_word) |this| : (this_word = fwd.next()) {
            var back = fwd.reverseIterator();
            const that_word = back.prev();
            if (that_word) |that| {
                try testing.expectEqualStrings(this.bytes(testr), that.bytes(testr));
            } else {
                try testing.expect(false);
            }
        }
    }
    {
        var back = Words.reverseIterator(testr);
        var this_word: ?Word = back.prev();

        while (this_word) |this| : (this_word = back.prev()) {
            var fwd = back.forwardIterator();
            const that_word = fwd.next();
            if (that_word) |that| {
                try testing.expectEqualStrings(this.bytes(testr), that.bytes(testr));
            } else {
                try testing.expect(false);
            }
        }
    }
}

test "Word.isTitleCased" {
    {
        const str = "Hello world";
        try testing.expectEqual(.yes, Words.wordAtIndex(str, 0).isTitlecased(str));
        try testing.expectEqual(.no, Words.wordAtIndex(str, 6).isTitlecased(str));
    }

    {
        const str = "ǅuro Ǆuro ǆuro";
        try testing.expectEqual(.yes, Words.wordAtIndex(str, 0).isTitlecased(str));
        try testing.expectEqual(.no, Words.wordAtIndex(str, "ǅuro ".len).isTitlecased(str));
        try testing.expectEqual(.no, Words.wordAtIndex(str, "ǅuro Ǆuro ".len).isTitlecased(str));
    }

    {
        const str = "123";
        try testing.expectEqual(.not_cased, Words.wordAtIndex(str, 0).isTitlecased(str));
    }

    {
        const str = "აბგ";
        try testing.expectEqual(.yes, Words.wordAtIndex(str, 0).isTitlecased(str));
    }

    {
        const str = "ßuro";
        try testing.expectEqual(.no, Words.wordAtIndex(str, 0).isTitlecased(str));
    }
}

test "Word.writeTitlecased and toTitlecaseAlloc" {
    {
        const str = "hello world";
        var allocating = std.Io.Writer.Allocating.init(testing.allocator);
        defer allocating.deinit();
        try Words.wordAtIndex(str, 0).writeTitlecased(str, &allocating.writer);
        const titlecased = try allocating.toOwnedSlice();
        defer testing.allocator.free(titlecased);
        try testing.expectEqualStrings("Hello", titlecased);
    }

    {
        const str = "ǆuro ßuro";
        const first = try Words.wordAtIndex(str, 0).toTitlecaseAlloc(str, testing.allocator);
        defer testing.allocator.free(first);
        try testing.expectEqualStrings("ǅuro", first);

        const second = try Words.wordAtIndex(str, "ǆuro ".len).toTitlecaseAlloc(str, testing.allocator);
        defer testing.allocator.free(second);
        try testing.expectEqualStrings("Ssuro", second);
    }

    {
        const str = "123";
        const same = try Words.wordAtIndex(str, 0).toTitlecaseAlloc(str, testing.allocator);
        defer testing.allocator.free(same);
        try testing.expectEqualStrings("123", same);
    }
}

const std = @import("std");
const builtin = @import("builtin");
const compress = std.compress;
const mem = std.mem;
const unicode = std.unicode;
const Allocator = mem.Allocator;
const OOM = Allocator.Error;
const assert = std.debug.assert;
const testing = std.testing;

const uoffset = code_point.uoffset;

const code_point = @import("code_point");
const CodepointIterator = code_point.Iterator;
const ReverseCodepointIterator = code_point.ReverseIterator;
const CodePoint = code_point.CodePoint;

const letter_case = @import("LetterCasing");

const ext_pict = @import("micro_runeset.zig").Extended_Pictographic;
