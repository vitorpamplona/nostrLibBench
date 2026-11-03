# News


## zg v0.16.0 Release Notes

This brings another major change to `zg`, touching basically everything.

The `zg` modules no longer require allocation to use.  Everything is
kept in static memory, where it should be.

With compression gone in the last release, the inconvenience and startup
penalty of moving the data, already present _in_ static memory, over to
the heap, was purely wasted effort.  Just CPU heat and extra clock time.
So that's gone.

90% of the work getting us here was done by Jacob Sandlund, who went on
to write his own rather interesting Unicode library, [uucode][uucode],
which you should check out if you like galaxy-brained comptime
shenanigans (I surely do).

Zig having moved on, I needed to merge that code via massage and
copypasta, so none of the commits survive.  But it's his work, so
thanks Jacob!

I did manage to dispose of one last allocation in `CanonData`, by
integrating Vexu's very clever [comptime hash map][chm], so, that's
nice.

[uucode]: https://github.com/jacobsandlund/uucode
[chm]: https://github.com/Vexu/comptime_hash_map/blob/master/src/main.zig


### Version

The release version of `v0.16.0` requires Zig `0.16.0`, conveniently
enough.  It differs in no other way from the `-rc2` release, which
supports `0.15.2`.  I may be willing to backport bug fixes for some
time, depending on interest, but probably not long.  Zig moves fast.


### Migration

Is simplicity itself: just call the module.  Instead of calling the
`.init` function, with an allocator, using what it returns, and
disposing of it when you're done with it.

Technically the laws of style dictate that, since these are now
containers, and not instantiable types, they should be lowercased.

I didn't see the point in changing all those names, it would add labor
to what should be a very brief and pleasant upgrade (but see below).
But feel free!

Pro tip: use LSP superpowers to rename the instance to the name of the
module, then just delete the initializer.  Couldn't be simpler.

While further breaking changes are almost certain, this is the last
refactor of this total magnitude which `zg` is likely to see.


### zg: The Module

The take-what-you-need approach, of packaging the interface in a bunch of
separate modules, remains available for those who prefer it.

Or, your code can just import `"zg"`, a module containing all of the
other modules.  Zig's lazy compilation model gives us take-what-you-need
already, so while there's no reason to remove the submodules, there's no
reason to prefer using them either.

As mentioned above, none of these are instance types any longer, and that
dictates that they take lower-case (as `code_point` and `ascii` always
have, for that reason).  So in `zg`, the modules are styled in lower case.

I did not want to combine a purely stylistic change, and one which would
require editing build scripts, with the functional changes needed to use
the (much nicer!) allocation-free interface.  It is possible that later
releases will lowercase the submodules as well, or maybe just remove
them in favor of importing `zg`.  Then again, maybe not.


### Emoji Module

Also Jacob's work.  Exposes the basic useful Unicode emoji properties.


### `graphemeWidth`

@lch361 submitted a minor refactor which makes it cleaner to obtain the
display width of a grapheme cluster.  Thanks Lich!


### Grapheme and Word methods

`Grapheme` exposes the display-width function, the dual of which is
available in `DisplayWidth` itself.  Zig lets modules import each other,
and lazy compilation means code which doesn't need to know about display
width will not pay for those tables just for using `Graphemes.`

`Word` uses the revamped `LetterCasing` module (see below) to expose
queries and writers on the subject of title-casing.


### Total Revamp of Normalization and Caseless Comparison

The first pre-release added some modest improvement to normalization,
making it faster on mainly-ASCII text.  The second pre-release is a
massive improvement, and a different philosophy.


#### Normalization, Stream-Safety, and the Zalgo Text Question

This library places special emphasis on real-life Unicode.  That starts
with encoding: if you don't have UTF-8, get that first, or `zg` is not
going to be of any assistance.  The era of wide encodings on-the-wire
is well past us, and mostly so at-rest, as well.  UTF-8 won, and it
deserved to win.

Similar statements apply to normalization forms.  The vast majority of
text is in NFC form, and yours should be as well!  That's what the
Normalization library emphasizes, because that's what's genuinely useful.

"Compatibility" is one of those not-great ideas which Unicode has kind of
backed away from, but will always have to support.  It plays a role in
matching, where you might want to search for "XIV" (ASCII) and still find
roman-numeral-encoded ⅩⅠⅤ.  Things of that nature.

But the faction in Unicode which wanted "Compatibility" to mean "don't
use a bunch of these codepoints", mostly, they lost.  The Wikipedia
article on the subject notwithstanding.  The largely-the-same-people
faction who wanted a purist approach to always decomposing diacritics
and Hangul?  Also lost.  NFC won, and it deserved to win.

UAX#15, the technical annex on normalization, defines a 'stream safe'
version of normalization.  Every normalization test which is in the UCD,
the stream safe version passes.  This reflects reality: while "sequence
of UTF-8" cannot be rigorously normalized with the stream safe approach,
_text_, all text, all _actual_ text, very much can be.

Well, what can't be?  [Zalgo Text][Zalgo], that's what.  If you encounter
Zalgo in the wild, there are only a few options:

  - It is someone's beautiful artistic expression.  So don't normalize it.
  - Someone is testing the boundaries of your application or library, out
    of curiosity or some other good motive.  That's fine, they'll learn
    something.
  - You are being trolled.  Someone is pushing on edge cases without your
    best interests in mind.  Do you feed the trolls?  Up to you, but,
    this behavior is deprecated.

`zg` now offers two pathways for `nfc`: `nfc`, which you should use, and
`nfcExact`, which... exists.  It's there.  The query `isNfc` will answer
according to the former, stream-safe definition, it does not take an
allocator because it does not need one. `nfc` does need an allocator,
because the text might not be `nfc`.  But the rigorous "trolled by
Zalgo" version of normalization requires scratch space commensurate
with the string itself, to even answer the question "is this NFC".
It must perform sorting, at `O(n⋅logₙ)`.  There is no reason to
tolerate this, and only one way to answer the question is provided:
force conversion to pure NFC, with `nfcExact`.  What you get back, will
be.

In the interest of completeness: if `nfc` is called on text which a)
is not purely NFC under the stream-safe definition, and b) has weird
Zalgo business, what is returned is rigorously NFC normalized text.
Since a new slice must be allocated, there's little advantage to doing
otherwise.

Similar considerations do not apply to `nfd`, or either compatibility
form, because text will generally not be in those three forms: it will
be in NFC.  So the general case, of fully decomposing into codepoints,
sorting when needed, and re-encoding into UTF-8, can't really be
improved much, and isn't.  However, we do use "quick check" to speed
things up, and often this means no copy is needed for full NFD.

NFKC is useless, so if you use the `nfkc` converter, you'll get what you
asked for: efficiently, but not optimally so.  NFKD is not useless, but
effort expended on that format is discussed below.

Which brings us to caseless matching.  The old matching routine lived
in `Normalize` and did a pessimal amount of allocation before trying
to answer the question: do these two strings match, caselessly?

Now we have a new module, `CaselessMatch`.  The functions `canonMatch`
and `compatMatch` no longer take an allocator, at all.  These take about
a half-KiB of stack space before the function calls are considered, that
space can be heap-allocated as a `Compat-` or `CanonCaselessMatcher`, if
you wish.

What's the tradeoff?  Is it Zalgo?  It's Zalgo.  No Zalgo-respecting
match routine is available, although you can rescue it from the repo
history if you feel strongly about the subject.

Also added is something a great deal more fun and useful, caseless
_search_.  For this, you comptime-specialize a `CaselessSearcher` of
canonical or compatible form, giving it a plausible codepoint-buffer
size for your decomposed needles.  These can be stack or heap allocated,
as you prefer, and search requires no allocation for any needle which
fits in the buffer.

A too-large needle returns an error, but given an allocator, search
may be performed against a needle of arbitrary size.  Search may also
specify an index to begin search at, so all matches can be found
iteratively.  No "last match" primitive is provided, because the thought
of writing a reversal of this algorithm raises my blood pressure, and
you can find the last match the hard way just as easily as I can.


#### QuickCheck

Central to making all of this efficient is the "quick check" algorithm,
which is a yes/no/maybe sort of thing which can rapidly skip the more
detailed and slower steps of verifying a normalization state.  These
are available in raw form, on the off chance that this might be useful.

It's important to understand, however: "quick check" doesn't mean "faster
way to do what `isNfc` does".  It's a specific algorithm which might be
of some direct use, that's all.

Due to the existence of an obscure tone-marker in the Greek alphabet,
which is only rarely used in transcribing certain Koine dialects, this
routine needed to be specialized for caseless match and search.  Them's
the breaks.


#### Upshot

For several releases, normalization has returned a `Result`, which
tracks whether the returned string was allocated, and which can be
safely `deinit`ed whether or not this is true.

Now, normalizing to `nfc` will never allocate for already-NFC text, and
will confirm this in the fastest manner I know how.  Since most text is
already NFC, that's a win.  Caseless matching is no longer allocating,
caseless search is possible, and won't allocate unless code opts in to
an oversized-needle kind of search.


### Real Letter Casing

Before this release, `zg` did only "simple" letter casing, about which
the Standard says: "only legacy implementations that cannot handle case
mappings that increase string lengths should use UnicodeData.txt case
mappings alone."

Well, `zg` is no longer a legacy implementation, implementing the full
'default' case mapping apparatus.  The 'best fit' single-codepoint
matching functions remain as primitives.

This release also adds title-case matching.  Since it's properly words,
rather than characters, which are or are not in titlecase, the important
functionality of this feature is found in the `Words` module.


### code_point.decode fully deprecated

Slicing to decode a point is an anti-pattern, and calling this
deprecated function is now a `@compileError`, suggesting `decodeAtIndex`
instead.  I suggest taking a look at `decodeAtCursor` as well, which
takes a pointer to an index and moves it to the next codepoint while
decoding.  This is often what you want.

A future release will remove the function entirely.


## zg v0.15.2-4 Release Notes

Better late than never.  The notes, I mean.  But the release too.

This was primarily a matter of getting up to Zig `0.15` compatibility.
Minor bugfixes in word wrapping, and the display width of certain
esoteric emoji, are also included.

Compression of the data was also removed.  It was removed from stdlib,
but we could have vendored it: more importantly, it turned out to be
basically useless.  Savings per data set were in the bytes to low
KiB range, and startup time was negatively affected.


## zg v0.14.1 Release Notes

In a flurry of activity during and after the `v0.14.0` beta, several
features were added (including from a new contributor!), and a bug
fixed.

Presenting `zg v0.14.1`.  As should be expected from a patch release,
there are no breaking changes to the interface, just bug fixes and
features.


### Grapheme Zalgo Text Bugfix

Until this release, `zg` was using a `u8` to store the length of a
`Grapheme`.  While this is much larger than any "real" grapheme, the
Unicode grapheme segmentation algorithm allows graphemes of arbitrary
size to be constructed, often called [Zalgo text][Zalgo] after a
notorious and funny Stack Overflow answer making use of this affordance.

Therefore, a crafted string could force an integer overflow, with all that
comes with it.  The `.len` field of a `Grapheme` is now a `u32`, like the
`.offset` field.  Due to padding, the `Grapheme` is the same size as it
was, just making use of the entire 8 bytes.

Actually, both fields are now `uoffset`, for reasons described next.

[Zalgo]: https://stackoverflow.com/questions/1732348/regex-match-open-tags-except-xhtml-self-contained-tags/1732454#1732454


### Limits Section Added to README

The README now clearly documents that some data structures and iterators
in `zg` use a `u32`.  I've also made it possible to configure the library
to use a `u64` instead, and have included an explanation of why this is
not the solution to actual problems which it at first might seem.

My job as maintainer is to provide a useful library to the community, and
comptime makes it easy and pleasant to tailor types to purpose.  So for those
who see a need for `u64` values in those structures, just pass `-Dfat_offset`
or its equivalent, and you'll have them.

I believe this to be neither necessary nor sufficient for handling data of
that size.  But I can't anticipate every requirement, and don't want to
preclude it as a solution.


### Iterators, Back and Forth

A new contributor, Nemoos, took on the challenge of adding a reverse
iterator to `Graphemes`.  Thanks Nemoos!

I've taken the opportunity to fill in a few bits of functionality to
flesh these out.  `code_point` now has a reverse iterator as well, and
either a forward or backward iterator can be reversed in-place.

Reversing an iterator will always return the last non-`null` result
of calling that iterator.  This is the only sane behavior, but
might be a bit unexpected without prior warning.

There's also `codePointAtIndex` and `graphemeAtIndex`.  These can be
given any index which falls within the Grapheme or Codepoint which
is returned.  These always return a value, and therefore cannot be
called on an empty string.

Finally, `Graphemes.iterateAfterGrapheme(string, grapheme)` will
return a forward iterator which will yield the grapheme after
`grapheme` when first called.  `iterateBeforeGrapheme` has the
signature and result one might expect from this.

`code_point` doesn't have an equivalent of those, since it isn't
useful: codepoints are one to four bytes in length, while obtaining
a grapheme reliably, given only an index, involves some pretty tricky
business to get right.  The `Graphemes` API just described allows
code to obtain a Grapheme cursor and then begin iterating in either
direction, by calling `graphemeAtIndex` and providing it to either
of those functions.  For codepoints, starting an iterator at either
`.offset` or `.offset + .len` will suffice, since the `CodePoint`
iterator is otherwise stateless.


### Words Module

The [Unicode annex][tr29] with the canonical grapheme segmentation
algorithm also includes algorithms for word and sentence segmentation.
`v0.14.1` includes an implementation of the word algorithm.

It works like `Graphemes`.  There's forward and reverse iteration,
`wordAtIndex`, and `iterate(Before|After)Word`.

If anyone is looking for a challenge, there are open issues for sentence
segmentation and [line breaking][tr14].

[tr29]: https://www.unicode.org/reports/tr29/
[tr14]: https://www.unicode.org/reports/tr14/


#### Runeset Used

As a point of interest:

Most of the rules in the word breaking algorithm come from a distinct
property table, `WordBreakProperties.txt` from the [UCD][UCD].  These
are made into a data structure familiar from the other modules.

One rule, WB3c, uses the Extended Pictographic property.  This is also
used in `Graphemes`, but to avoid a dependency on that library, I used
a [Runeset][Rune].  This is included statically, with only just as much
code as needed to recognize the sequences; `zg` itself remains free of
transitive dependencies.

[UCD]: https://www.unicode.org/reports/tr44/
[Rune]: https://github.com/mnemnion/runeset


## zg v0.14.0 Release Notes

This is the first minor point release since Sam Atman (me) took over
maintenance of `zg` from the inimitable José Colon Rodriguez, aka
@dude_the_builder.  We're all grateful for everything he's done for
the Zig community.

The changes are fairly large, and most user code will need to be updated.
The result is substantially streamlined and easier to use, and updating
will mainly take place around importing, creating, and deinitializing.


### The Great Renaming

The most obvious change is on the surface API: more than half of the
modules have been renamed.  There are no user-facing modules with `Data`
in the name, and some abbreviations have been spelled in full.


### No More Separation of Data and Functionality

It is no longer necessary to separately create, for example, a
`GraphemeData` structure, in order to use the functionality provided
by the `grapheme` module.

Instead there's just `Graphemes`, and the same for a couple of other
modules which worked the same way.  This means that the cases where
functionality was provided by a wrapped pointer are now provided
directly from the struct with the necessary data.

This would make user structs larger in some cases, while eliminating a
pointer chase.  If that isn't a desirable trade off for your code,
read on.


### All Allocated Data is Unmanaged

Prior to `v0.14`, all structs which need heap allocation no longer
have a copy of their allocator.  We felt that this was redundant,
especially when several such structures were in use, and it reflects
a general trend in the standard library toward fewer managed data
structures.

Getting up to speed is a matter of passing the allocator to `deinit`.

This change comes courtesy of [lch361](https://lch361.net), in his
first contribution to the repo.  Thanks Lich!


### `code_point` Now Unicode-Compliant

The `v0.15.x` decoder used a simple, fast, but naïve method to decode
UTF-8 into codepoints.  Concerningly, this interpreted overlong
sequences, which has been forbidden by Unicode for more than 20 years
due to the security risks involved.

This has been replaced with a DFA decoder based on the work of
[Björn Höhrmann][UTF], which has proven itself fast[^1] and reliable.
This is a breaking change; sequences such as `"\xc0\xaf"` will no longer
produce the code `'/'`, nor will surrogates return their codepoint
value.

The new decoder faithfully implements §3.9.6 of the Unicode Standard,
_U+FFFD Substitution of Maximal Subparts_.  While this is itself not
required to claim Unicode conformance, it is the W3C specification for
replacement behavior.

Along with this, `code_point.decode` is deprecated, and will be removed
in a later version of `zg`.  It was basically an exposed piece of the
`Iterator` implementation, and is no longer used in that capacity.

Instead, prefer `decodeAtIndex([]const u8, u32) ?CodePoint`, or better
yet, `decodeAtCursor([]const u8, *u32)`.  The latter advances its
second argument to the next possible index for a valid codepoint, which
is good for the fetch pipeline, and more ergonomic in many cases.

[UTF]: https://bjoern.hoehrmann.de/utf-8/decoder/dfa/

[^1]: A bit more than twice as fast as the standard library for
decoding, according to my (limited) benchmarks.


### DisplayWidth and CaseFolding Can Share Data

Both of these modules use another module to get the job done,
`Graphemes` for `DisplayWidth`, and `Normalize` for `CaseFolding`.

It is now possible to initialize them with a borrowed copy of those
modules, to make it simpler to write code which also needs the base
modules.


### Grapheme Iterator Creation

This is a modest streamlining of how a grapheme iterator is created.

Before:

```zig
const gd = try grapheme.GraphemeData.init(allocator);
defer gd.deinit();
var iter = grapheme.Iterator.init("🤘🏻some rad string! 🤘🏿", &gd);
```

Now:

```zig
const graphemes = try Graphemes.init(allocator);
defer graphemes.deinit(allocator);
var iter = graphemes.iterator("🤘🏻some rad string! 🤘🏿");
```

It remains possible to use

```zig
var iter = Graphemes.Iterator.init("stri̵̢̡̡̡̨̧̡̨̡̡̡̨̫̗̗̱̳̼̖͚͉̩̬̬͚̟̣̮̬̙̖̗͇̮͓̻̫͍͎͉͎̹̩̗͖͈̙̻̭̝̭̼̙̯̪͚̙͉͎͎͖̥̹͈̫͍̹͓̘̙͎͖̝̦͎̤̼̹͕͈̪̙̪̯̯͙̝͈͕̬̪̗̭͎͖̟͚̦̣̘͙̞̮̹̙͚̼̤̟͉̭͔̩͍͔͈̯͎̘͎̭̥̖̜͙̖̖͍̼͙͎͚̦̮̹̞̺͍̳̖̹̼̲̠̩̰̳͂̌̈́̓̄͋̇̎͜͜͠ͅͅͅͅng", &graphemes);
```

If one were to prefer doing so.


### Initialization vs. Setup

Every allocating module now has both an `init` function, which
returns the created struct, and a `setup` function.  The latter
takes a mutable pointer, and an `Allocator`, returning
`Allocator.Error!void`.

So those who might prefer a single-pointer home for such modules
can allocate the struct on the heap with `allocator.create`, or
add a pointer field to some other struct, then use `setup` to
populate it.

In the process, the various spurious reader and decompression errors
have been turned `unreachable`, leaving only `error.OutOfMemory`.
Encountering any of the other errors would indicate an internal problem,
so we no longer make user code deal with that unlikely event.


### New DisplayWidth options

A `DisplayWidth` can now be compiled to treat `c0` and `c1` control codes
as having a width.  Canonically, terminals don't print them, so they
would have a width of 0.  However, some applications (`vim` for example)
need to escape control codes to make them visible.  Setting these
options will let `DisplayWidth` return the correct widths when this
is done.


### Unicode 16.0

This updates `zg` to use the latest Unicode edition.  This should be
the only change which will change behavior of user code, other than
through the use of the new `DisplayWidth` options.


### Tests

It is now possible to run all the tests, not just the `unicode-test`
subset. Accordingly, that step is removed, and `zig build test`
runs everything.


#### Allocations Tested

Every allocate-able now has a `checkAllAllocationFailures` test.  This
process turned up two bugs.  Also discovered were 8,663 allocations,
which were reduced to two, these were also being individually freed
on deinit.  So that's nice.


#### That's It!

I hope you find converting over `zg v0.13` code to be fairly painless
and straightforward.  There should be no need to make changes of this
magnitude in the future.

