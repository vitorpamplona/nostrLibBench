# zg

zg provides Unicode text processing for Zig projects.


## Unicode Version

The Unicode version supported by zg is `16.0.0`.


## Zig Version

The minimum Zig version required is `0.15.2`.

The official release of `zg 0.16` will require Zig `0.16.x`, whatever
`x` is official this time.  The last beta release will be kept around
for those who don't want to bump Zig versions right away.


## Integrating zg into your Zig Project

You first need to add zg as a dependency in your `build.zig.zon` file. In your
Zig project's root directory, run:

```plain
zig fetch --save https://codeberg.org/atman/zg/archive/v0.16.2.tar.gz
```

Then instantiate the dependency in your `build.zig`:

```zig
const zg = b.dependency("zg", .{});
```

## Zg, the Module

The `zg` package has classically been structured as a collection
of mix-and-match modules.  This approach is still available, just
supplemented with a module-of-modules, also called `zg`.

For historical reasons, many of the submodules use `TypeCase`, despite
the fact that they no longer require instantiation.  Reflecting this,
the names of the modules in the `zg` scope are all `container_case`.

To use in this fashion, import like so:

```zig
exe.root_module.addImport("zg", zg.module("zg"));
```

Rather than trying to split the difference, the README will reflect use
of `zg` on a submodule basis.  Note that any configurations discussed can
be passed directly to the `zg` dependency import, and will reach that
submodule accordingly.


### The Modular Approach

`zg` is a modular library.  This approach minimizes binary file size and
memory requirements by only including the Unicode data required for the
specified module.  The following sections describe the various modules
and their specific use case.


## Code Points

In the `code_point` module, you'll find a data structure representing a
single code point, `CodePoint`, and an `Iterator` to iterate over the
code points in a string.

In your `build.zig`:

```zig
exe.root_module.addImport("code_point", zg.module("code_point"));
```

In your code:

```zig
const code_point = @import("code_point");

test "Code point iterator" {
    const str = "Hi 😊";
    var iter: code_point.Iterator = .init(str);
    var i: usize = 0;

    while (iter.next()) |cp| : (i += 1) {
        // The `code` field is the actual code point scalar as a `u21`.
        if (i == 0) try expect(cp.code == 'H');
        if (i == 1) try expect(cp.code == 'i');
        if (i == 2) try expect(cp.code == ' ');

        if (i == 3) {
            try expect(cp.code == '😊');
            // The `offset` field is the byte offset in the
            // source string.
            try expect(cp.offset == 3);
            try expectEqual(cp, code_point.decodeAtIndex(str, cp.offset).?);
            // The `len` field is the length in bytes of the
            // code point in the source string.
            try expect(cp.len == 4);
            // There is also a 'cursor' decode, like so:
            {
                var cursor = cp.offset;
                try expectEqual(cp, code_point.decodeAtCursor(str, &cursor).?);
                // Which advances the cursor variable to the next possible
                // offset, in this case, `str.len`.  Don't forget to account
                // for this possibility!
                try expectEqual(cp.offset + cp.len, cursor);
            }
            // There's also this, for when you aren't sure if you have the
            // correct start for a code point:
            try expectEqual(cp, code_point.codepointAtIndex(str, cp.offset + 1).?);
        }
        // Reverse iteration is also an option:
        var r_iter: code_point.ReverseIterator = .init(str);
        // Both iterators can be peeked:
        try expectEqual('😊', r_iter.peek().?.code);
        try expectEqual('😊', r_iter.prev().?.code);
        // Both kinds of iterators can be reversed:
        var fwd_iter = r_iter.forwardIterator(); // or iter.reverseIterator();
        // This will always return the last codepoint from
        // the prior iterator, _if_ it yielded one:
        try expectEqual('😊', fwd_iter.next().?.code);
    }
}
```

Note that it's safe to call CodePoint functions on invalid
UTF-8. Iterators and decode functions will return the Unicode
Replacement Character `U+FFFD`, according to the Substitution of Maximal
Subparts algorithm, for any invalid code unit sequences encountered.


## Grapheme Clusters

Many characters are composed from more than one code point. These
are known as Grapheme Clusters, and the `Graphemes` module has a
data structure to represent them, `Grapheme`, and an `Iterator` and
`ReverseIterator` to iterate over them in a string.

There is also `graphemeAtIndex`, which returns whatever grapheme
belongs to the index; this does not have to be on a valid grapheme
or codepoint boundary, but it is illegal to call on an empty string.
Last, `iterateAfterGrapheme` or `iterateBeforeGrapheme` will provide
forward or backward grapheme iterators of the string, from the grapheme
provided.  Thus, given an index, you can begin forward or backward
iteration at that index without needing to slice the string.

In your `build.zig`:

```zig
exe.root_module.addImport("Graphemes", zg.module("Graphemes"));
```

In your code:

```zig
const Graphemes = @import("Graphemes");

test "Grapheme cluster iterator" {
    const str = "He\u{301}"; // Hé
    var iter = Graphemes.iterator(str);

    var i: usize = 0;

    while (iter.next()) |gc| : (i += 1) {
        // The `len` field is the length in bytes of the
        // grapheme cluster in the source string.
        if (i == 0) try expect(gc.len == 1);

        if (i == 1) {
            try expect(gc.len == 3);

            // The `offset` in bytes of the grapheme cluster
            // in the source string.
            try expect(gc.offset == 1);

            // The `bytes` method returns the slice of bytes
            // that comprise this grapheme cluster in the
            // source string `str`.
            try expectEqualStrings("e\u{301}", gc.bytes(str));
        }
    }
}```


## Words

Unicode has a standard word segmentation algorithm, which gives good
results for most languages.  Some languages, such as Thai, require a
dictionary to find the boundary between words; these cases are not
handled by the standard algorithm.

`zg` implements that algorithm in the `Words` module.  As a note,
the iterators and functions provided here will yield segments which
are not a "word" in the conventional sense, but word _boundaries_.
Specifically, the iterators in this module will return every segment of
a string, ensuring that words are kept whole when encountered.  If the
word breaks are of primary interest, you'll want to use the `.offset`
field of each iterated value, and handle `string.len` as the final case
when the iteration returns `null`.

The API is congruent with `Graphemes`: forward and backward iterators,
`wordAtIndex`, and `iterateAfter` and before.

In your `build.zig`:

```zig
exe.root_module.addImport("Words", zg.module("Words"));
```

In your code:

```zig
const Words = @import("Words");

test "Words" {
    const word_str = "Metonym   Μετωνύμιο メトニム";
    var w_iter = Words.iterator(word_str);
    try testing.expectEqualStrings("Metonym", w_iter.next().?.bytes(word_str));
    // Spaces are "words" too!
    try testing.expectEqualStrings("   ", w_iter.next().?.bytes(word_str));
    const in_greek = w_iter.next().?;
    // wordAtIndex doesn't care if the index is valid for a codepoint:
    for (in_greek.offset..in_greek.offset + in_greek.len) |i| {
        const at_index = Words.wordAtIndex(word_str, i).bytes(word_str);
        try testing.expectEqualStrings("Μετωνύμιο", at_index);
    }
    _ = w_iter.next();
    try testing.expectEqualStrings("メトニム", w_iter.next().?.bytes(word_str));

    const hello = Words.wordAtIndex("Hello!", 0);
    try testing.expectEqual(.yes, hello.isTitlecased("Hello!"));

    // Titlecasing can be streamed to a writer:
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    const smol_hello = "hello world!";
    var hello_iter = Words.iterator(smol_hello);
    while (hello_iter.next()) |word| {
        try word.writeTitlecased(smol_hello, &allocating.writer);
    }
    const titlecased = try allocating.toOwnedSlice();
    defer testing.allocator.free(titlecased);
    try testing.expectEqualStrings("Hello World!", titlecased);
    // Or a copy made with `toTitlecaseAlloc`.
}
```

## Unicode General Categories

To detect the general category for a code point, use the
`GeneralCategories` module.

In your `build.zig`:

```zig
exe.root_module.addImport("GeneralCategories", zg.module("GeneralCategories"));
```

In your code:

```zig
const GeneralCategories = @import("GeneralCategories");

test "General Categories" {
    // The `gc` method returns the abbreviated General Category.
    // These abbreviations and descriptive comments can be found
    // in the source file `src/GenCatData.zig` as en enum.
    try expect(GeneralCategories.gc('A') == .Lu); // Lu: uppercase letter
    try expect(GeneralCategories.gc('3') == .Nd); // Nd: decimal number

    // The following are convenience methods for groups of General
    // Categories. For example, all letter categories start with `L`:
    // Lu, Ll, Lt, Lo.
    try expect(GeneralCategories.isControl(0));
    try expect(GeneralCategories.isLetter('z'));
    try expect(GeneralCategories.isMark('\u{301}'));
    try expect(GeneralCategories.isNumber('3'));
    try expect(GeneralCategories.isPunctuation('['));
    try expect(GeneralCategories.isSeparator(' '));
    try expect(GeneralCategories.isSymbol('©'));
}
```

## Unicode Properties

You can detect common properties of a code point with the `Properties`
module.

In your `build.zig`:

```zig
exe.root_module.addImport("Properties", zg.module("Properties"));
```

In your code:

```zig
const Properties = @import("Properties");

const Properties = @import("Properties");

test "Properties" {
    // Mathematical symbols and letters.
    try expect(Properties.isMath('+'));
    // Alphabetic only code points.
    try expect(Properties.isAlphabetic('Z'));
    // Space, tab, and other separators.
    try expect(Properties.isWhitespace(' '));
    // Hexadecimal digits and variations thereof.
    try expect(Properties.isHexDigit('f'));
    try expect(!Properties.isHexDigit('z'));

    // Accents, dieresis, and other combining marks.
    try expect(Properties.isDiacritic('\u{301}'));

    // Unicode has a specification for valid identifiers like
    // the ones used in programming and regular expressions.
    try expect(Properties.isIdStart('Z')); // Identifier start character
    try expect(!Properties.isIdStart('1'));
    try expect(Properties.isIdContinue('1'));

    // The `X` versions add some code points that can appear after
    // normalizing a string.
    try expect(Properties.isXidStart('\u{b33}')); // Extended identifier start character
    try expect(Properties.isXidContinue('\u{e33}'));
    try expect(!Properties.isXidStart('1'));

    // Note surprising Unicode numeric type properties!
    try expect(Properties.isNumeric('\u{277f}'));
    try expect(!Properties.isNumeric('3')); // 3 is not numeric!
    try expect(Properties.isDigit('\u{2070}'));
    try expect(!Properties.isDigit('3')); // 3 is not a digit!
    try expect(Properties.isDecimal('3')); // 3 is a decimal digit
}```

## Letter Case Detection and Conversion

To detect and convert to and from different letter cases, use the
`LetterCasing` module.

In your `build.zig`:

```zig
exe.root_module.addImport("LetterCasing", zg.module("LetterCasing"));
```

In your code:

```zig
const LetterCasing = @import("LetterCasing");

test "LetterCasing" {
    // Simple upper, lower, and title case for a single code point.
    try expect(LetterCasing.isUpper('A'));
    try expect('A' == LetterCasing.toUpper('a'));
    try expect(LetterCasing.isLower('a'));
    try expect('a' == LetterCasing.toLower('A'));
    try expect('\u{01C5}' == LetterCasing.toTitlecase('\u{01C6}'));

    // Code points that have case.
    try expect(LetterCasing.isCased('É'));
    try expect(!LetterCasing.isCased('3'));

    // Full upper, lower, and title mappings for a single code point.
    try expectEqualSlices(u21, &[_]u21{ 'S', 'S' }, LetterCasing.upperMapped('ß').?);
    try expectEqualSlices(u21, &[_]u21{ 'i', '\u{0307}' }, LetterCasing.lowerMapped('\u{0130}').?);
    try expectEqualSlices(u21, &[_]u21{ 'S', 's' }, LetterCasing.titleMapped('ß').?);
    // Returns `null` if the point doesn't change:
    try expectEqual(null, LetterCasing.lowerMapped('1'));

    // Case detection and full default Unicode casing for strings.
    try expect(LetterCasing.isUpperStr("HELLO 123!"));
    const ucased = try LetterCasing.toUpperAlloc(allocator, "Straße");
    defer allocator.free(ucased);
    try expectEqualStrings("STRASSE", ucased);

    try expect(LetterCasing.isLowerStr("hello 123!"));
    const lcased = try LetterCasing.toLowerAlloc(allocator, "\u{0130}Σ");
    defer allocator.free(lcased);
    try expectEqualStrings("i\u{0307}ς", lcased);
}
```

The scalar `toUpper`, `toLower`, and `toTitlecase` functions map
one-to-one to the best-single-point equivalent, what Unicode calls
"simple".  For full mapping, e.g. `ß` -> `SS`, call `lowerMapped` (or
`upper`, `title`): these return `null` if the codepoint doesn't change,
`[]const u21` if it does.

The allocating string functions `toUpperAlloc` and `toLowerAlloc`, and
the writer interfaces `writeAsUpper` and `writeAsLower`, perform full
default Unicode casing, including one-to-many mappings and default
context-sensitive behavior such as final sigma.


## Normalization

Unicode normalization is the process of converting a string into a
uniform representation that can guarantee a known structure by following
a strict set of rules. There are four normalization forms:

**Canonical Composition (NFC)**
: The most compact representation obtained by first decomposing to
Canonical Decomposition and then composing to NFC.  The vast majority of
text is currently normalized to NFC.

**Compatibility Composition (NFKC)**
: The most comprehensive composition obtained by first decomposing to
Compatibility Decomposition and then composing to NFKC.  The maintainer
of `zg` is aware of no practical use for this form.

**Canonical Decomposition (NFD)**
: Only code points with canonical decompositions are decomposed. This is
a more compact and faster decomposition but will not provide the most
comprehensive normalization possible.

**Compatibility Decomposition (NFKD)**
: The most comprehensive decomposition method where both canonical and
compatibility decompositions are performed recursively.

`zg` has methods to produce all four normalization forms in the
`Normalize` module.  The special emphasis is on `nfc`, because most text
is already in NFC form.

The `nfc` function uses the "Stream safe" variant of normalization,
which passes all Unicode normalization tests while requiring a small and
bounded amount of scratch memory.  While it is possible to construct
inputs which do not normalize correctly via this method, such inputs
do not correspond to actual text in any language covered by Unicode.
The function `nfcExact` will also normalize these exceptional inputs
correctly, should you absolutely require that.

In your `build.zig`:

```zig
exe.root_module.addImport("Normalize", zg.module("Normalize"));
```

In your code:

```zig
const Normalize = @import("Normalize");

test "Normalize" {

    // NFC: Canonical composition. If the text is already NFC,
    // this returns a view of the original slice without allocating.
    const nfc_result = try Normalize.nfc(allocator, "Complex char: \u{3D2}\u{301}");
    defer nfc_result.deinit(allocator); // Safe whether or not .slice is allocated
    try expectEqualStrings("Complex char: \u{3D3}", nfc_result.slice);

    try expect(Normalize.isNfc("déjà vu"));
    try expect(!Normalize.isNfc("de\u{301}ja\u{300} vu"));

    // `nfcExact` exists for the rigorous answer on unusual text.  This is not an
    // example of 'unusual text', which is a minimum of 30 codepoints in width,
    // and would represent nothing anyone is likely to care about.
    const exact_result = try Normalize.nfcExact(allocator, "Complex char: \u{3D2}\u{301}");
    defer exact_result.deinit(allocator);
    try expectEqualStrings("Complex char: \u{3D3}", exact_result.slice);

    // NFKC: Compatibility composition
    const nfkc_result = try Normalize.nfkc(allocator, "Complex char: \u{03A5}\u{0301}");
    defer nfkc_result.deinit(allocator);
    try expectEqualStrings("Complex char: \u{038E}", nfkc_result.slice);

    // NFD: Canonical decomposition
    const nfd_result = try Normalize.nfd(allocator, "Héllo World! \u{3d3}");
    defer nfd_result.deinit(allocator);
    try expectEqualStrings("He\u{301}llo World! \u{3d2}\u{301}", nfd_result.slice);

    // NFKD: Compatibility decomposition
    const nfkd_result = try Normalize.nfkd(allocator, "Héllo World! \u{3d3}");
    defer nfkd_result.deinit(allocator);
    try expectEqualStrings("He\u{301}llo World! \u{3a5}\u{301}", nfkd_result.slice);

    // Test for equality of two strings after normalizing to NFC.  This
    // uses the 'stream safe' definition of NFC, which requires no
    // allocation and cannot fail, but is not rigorous in the face of
    // Zalgo-text weirdness.
    try expect(Normalize.eql("foé", "foe\u{0301}"));
    try expect(Normalize.eql("foϓ", "fo\u{03D2}\u{0301}"));

    // QuickCheck is a Unicode primitive algorithm, which may be useful, and
    // is included on that basis.  It is not "isNfc but faster".
    try expectEqual(.yes, Normalize.nfcQuickCheck("déjà vu"));
}
```

The `Result` returned by normalization functions may or may not be
copied from the inputs given.  For example, an input already in NFC
form fed to the `nfc` converter does not need to be a copy, and will be
a view of the original slice.  Calling `result.deinit(allocator)` will
only free an allocated `Result`, not one which is a view.  Thus it is
safe to do unconditionally.

This does mean that the validity of a `Result` can depend on the
original string staying in memory.  To ensure that your `Result` is
always a copy, you may call `try result.toOwned(allocator)`, which will
only make a copy if one was not already made.


## Case Folding

Unicode case folding data is available directly through the
`CaseFolding` module.  This is useful when you need the raw fold for a
code point, or want to ask whether case folding would change it.

Note that "case folding" is a subtly different concept from "case mapping",
more concerned with matching than a locale-independent upper or lowercasing
of a string.  As one example, names may be stored in case-folded form with
their original style, to enable case-insensitive retrieval.

In your `build.zig`:

```zig
exe.root_module.addImport("CaseFolding", zg.module("CaseFolding"));
```

In your code:

```zig
const CaseFolding = @import("CaseFolding");

test "Case folding" {
    var buf: [3]u21 = undefined;

    const folded = CaseFolding.caseFold('ῧ', &buf);
    try expectEqual(@as(usize, 3), folded.len);
    try expectEqual('υ', folded[0]);
    try expectEqual('\u{0308}', folded[1]);
    try expectEqual('\u{0342}', folded[2]);

    try expect(CaseFolding.cpChangesWhenCaseFolded('É'));
    try expect(!CaseFolding.cpChangesWhenCaseFolded('3'));
}
```

## Caseless Matching

Unicode caseless matching and search live in the `CaselessMatch` module.
These routines are allocation-free in the common case, and use the same
stream-safe understanding of NFC which `Normalize.nfc` uses.

In your `build.zig`:

```zig
exe.root_module.addImport("CaselessMatch", zg.module("CaselessMatch"));
```

In your code:

```zig
const CaselessMatch = @import("CaselessMatch");

test "Caseless matching and search" {
    const a = "Héllo World! \u{3d3}";
    const b = "He\u{301}llo World! \u{3a5}\u{301}";
    const c = "He\u{301}llo World! \u{3d2}\u{301}";

    try expect(!CaselessMatch.canonMatch(a, b));
    try expect(CaselessMatch.canonMatch(a, c));
    try expect(CaselessMatch.compatMatch(a, b));

    var matcher = CaselessMatch.CanonCaselessMatcher.default;
    try expect(matcher.match("Straße", "STRASSE"));

    var searcher = CaselessMatch.CaselessSearcher(32, .compat).default;
    // The error here is only if the needle is larger than the comptime-
    // configured buffer, here 32 codepoints in length.  An overlarge
    // needle may still be matched with `matchAlloc`, which requires an
    // allocator to make space for the decomposed needle.
    const found = searcher.match("xx Straße yy", "STRASSE") catch unreachable;
    try expectEqualStrings("Straße", found.?);
}
```

For repeated use, the matcher and searcher types may also be
heap-allocated with `.create(allocator)` and later freed with
`.destroy(allocator)`.


## Display Width of Characters and Strings

When displaying text with a fixed-width font on a terminal screen, it's
very important to know exactly how many columns or cells each character
should take.  Most characters will use one column, but there are
many, like emoji and East- Asian ideographs that need more space. The
`DisplayWidth` module provides methods for this purpose.  It also has
methods that use the display width calculation to `center`, `padLeft`,
`padRight`, and `wrap` text.

The `zg` authors consider [Ghostty][ghost] the terminal of record, when
deciding what answer this function should return.

In your `build.zig`:

```zig
exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
```

In your code:

```zig
const DisplayWidth = @import("DisplayWidth");

test "Display width" {
    // String display width
    try expectEqual(@as(usize, 5), DisplayWidth.strWidth("Hello\r\n"));
    try expectEqual(@as(usize, 8), DisplayWidth.strWidth("Hello 😊"));
    try expectEqual(@as(usize, 8), DisplayWidth.strWidth("Héllo 😊"));
    try expectEqual(@as(usize, 9), DisplayWidth.strWidth("Ẓ̌á̲l͔̝̞̄̑͌g̖̘̘̔̔͢͞͝o̪̔T̢̙̫̈̍͞e̬͈͕͌̏͑x̺̍ṭ̓̓ͅ"));
    try expectEqual(@as(usize, 17), DisplayWidth.strWidth("슬라바 우크라이나"));

    // Grapheme display width.  Usually the grapheme would come from
    // a grapheme iterator, but that's not a requirement.
    try expectEqual(@as(usize, 2), DisplayWidth.graphemeWidth("👨🏻‍🌾"))

    // Centering text
    const centered = try DisplayWidth.center(allocator, "w😊w", 10, "-");
    defer allocator.free(centered);
    try expectEqualStrings("---w😊w---", centered);

    // Pad left
    const right_aligned = try DisplayWidth.padLeft(allocator, "abc", 9, "*");
    defer allocator.free(right_aligned);
    try expectEqualStrings("******abc", right_aligned);

    // Pad right
    const left_aligned = try DisplayWidth.padRight(allocator, "abc", 9, "*");
    defer allocator.free(left_aligned);
    try expectEqualStrings("abc******", left_aligned);

    // Wrap text
    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const wrapped = try DisplayWidth.wrap(allocator, input, 10, 3);
    defer allocator.free(wrapped);
    const want =
        \\The quick
        \\brown fox
        \\jumped
        \\over the
        \\lazy dog!
    ;
    try expectEqualStrings(want, wrapped);
}
```

This module has build options.  The first is `cjk`, which will consider
[ambiguous characters][ambig] as double-width.

To choose this option, add it to the dependency like so:

```zig
const zg = b.dependency("zg", .{
    .cjk = true,
});
```

The other options are `c0_width` and `c1_width`.  The standard behavior
is to treat C0 and C1 control codes as zero-width, except for delete and
backspace, which are -1 (the logic ensures that a `strWidth` is always
at least 0).  If printing control codes with replacement characters,
it's necessary to assign these a width, hence the options.  When
provided these values must fit in an `i4`, this allows for C1s to be
printed as `\u{80}` if desired.

[ambig]: https://www.unicode.org/reports/tr11/tr11-6.html
[ghost]: https://ghostty.org/

## Scripts

Unicode categorizes code points by the Script in which they belong.  A
Script collects letters and other symbols that belong to a particular
writing system.  You can detect the Script for a code point with the
`Scripts` module.

In your `build.zig`:

```zig
exe.root_module.addImport("Scripts", zg.module("Scripts"));
```

In your code:

```zig
const Scripts = @import("Scripts");

test "Scripts" {
    // To see the full list of Scripts, look at the
    // `src/Scripts.zig` file. They are listed as an enum.
    try expect(Scripts.script('A') == .Latin);
    try expect(Scripts.script('Ω') == .Greek);
    try expect(Scripts.script('צ') == .Hebrew);
}
```

## Emoji

To get information about emoji and emoji-like characters, use the
`Emoji` module.

In your `build.zig`:

```zig
exe.root_module.addImport("Emoji", zg.module("Emoji"));
```

In your code:

```zig
const Emoji = @import("Emoji");

test "Emoji" {
    try expect(Emoji.isEmoji(0x1F415)); // 🐕
    try expect(Emoji.isEmojiPresentation(0x1F408)); // 🐈
    try expect(Emoji.isEmojiModifier(0x1F3FF)); //
    try expect(Emoji.isEmojiModifierBase(0x1F977)); // 🥷
    try expect(Emoji.isEmojiComponent(0x1F9B0)); // 🦰
    try expect(Emoji.isExtendedPictographic(0x1F005)); // 🀅
}
```

## Limits

Iterators, and fragment types such as `CodePoint`, `Grapheme` and
`Word`, use a `u32` to store the offset into a string, and the length of
the fragment (`CodePoint` uses a `u3` for length, actually).

4GiB is a lot of string.  There are a few reasons to work with that much
string, log files primarily, but fewer to bring it all into memory at
once, and practically no reason at all to do anything to such a string
without breaking it into smaller pieces to work with.

Also, Zig compiles on 32 bit systems, where `usize` is a `u32`.  Code
running on such systems has no choice but to handle slices in smaller
pieces.  In general, if you want code to perform correctly when
encountering multi-gigabyte strings, you'll need to code for that, at a
level one or two steps above that in which you'll want to, for example,
iterate some graphemes of that string.

That all said, `zg` modules can be passed the Boolean config option
`fat_offset`, which will make all of those data structures use a `u64`
instead.  I added this option not because you should use it, which you
should not, but to encourage awareness that code operating on strings
needs to pay attention to the size of those strings, and have a plan for
when sizes get out of specification.  What would your code do with a
1MiB region of string with no newline?  There are many questions of this
nature, and robust code must detect when data is out of the expected
envelope, so it can respond accordingly.

Code which does pay attention to these questions has no need for `u64`
sized offsets, and code which does not will not be helped by them.  But
perhaps yours is an exception, in which case, by all means, configure
accordingly.
