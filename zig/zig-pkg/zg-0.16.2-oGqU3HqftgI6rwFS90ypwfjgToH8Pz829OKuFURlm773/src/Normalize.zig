//! Normalize contains functions and methods that implement Unicode
//! Normalization.  You can normalize strings into NFC, NFKC, NFD, and NFKD
//! normalization forms.
//!
//! Caseless matching has moved to CaselessMatching.zig.

/// Returned from various functions in this namespace. Remember to call
/// `deinit` to free any allocated memory.  Note that normalization functions
/// will not copy what they're given if no normalization is needed, if you
/// need to ensure that this Result outlasts the given string, call `try
/// result.toOwned(allocator)`.  This will not make a third copy if the Result
/// is already copied from the input.
pub const Result = struct {
    allocated: bool = false,
    slice: []const u8,

    /// Ensures that the slice result is a copy of the input, by making a copy if it was not.
    pub fn toOwned(result: Result, allocator: Allocator) error{OutOfMemory}!Result {
        if (result.allocated) return result;
        return .{ .allocated = true, .slice = try allocator.dupe(u8, result.slice) };
    }

    pub fn deinit(result: *const Result, allocator: Allocator) void {
        if (result.allocated) allocator.free(result.slice);
    }
};

/// Normalize a string to NFC, by far the most common normalization form for
/// text, when at rest or in flight.  The algorithm used here performs no
/// allocation to verify normalization, and is correct for any 'ordinary' text,
/// meaning, all and every use of Unicode designed to be read by humans.  If
/// the text is already NFC, no allocation at all will occur.  But it does not
/// normalize _absolutely all_ text.  If you do need that, use `nfcExact`.
pub fn nfc(allocator: Allocator, str: []const u8) OOM!Result {
    if (isNfc(str)) return .{ .slice = str };
    return nfcExact(allocator, str);
}

/// Normalizes `str` to NFC.  Unlike its cousin `nfc`, this will perform
/// allocation in order to both verify normalization, and perform it if needed.
/// It is also subject to somewhat time-consuming codepoint sorting, when
/// fed unusual 'Zalgo' texts.  If you do not care deeply about the final
/// normalization state of weird illegible sequences of codepoints, for which
/// the term 'text' is generous, you want to use `nfc`.
pub fn nfcExact(allocator: Allocator, str: []const u8) OOM!Result {
    return nfxc(.nfc, allocator, str);
}

/// Answers whether the text is in NFC, subject to the same algorithm used for
/// the `nfc` converter, UAX15-D3.  This algorithm has good performance and
/// does not allocate, while passing all tests Unicode sees fit to publish for
/// verifying a normalization library is conformant.  But, again, Zalgo text.
pub fn isNfc(str: []const u8) bool {
    const non_ascii = ascii.nonAsciiSuffix(str);
    if (non_ascii.len == 0) return true;

    var cursor: usize = str.len - non_ascii.len;
    var last_stable: ?usize = if (cursor > 0) cursor - 1 else null;

    while (true) {
        switch (quickCheckCursorWithLastStable(.nfc, str, &cursor, &last_stable)) {
            .yes => return true,
            .no => return false,
            .maybe => {
                const start = last_stable orelse 0;
                const next = checkNfcGoodEnoughRegion(str, start, cursor) orelse return false;
                if (next == str.len) return true;

                cursor = next;
                last_stable = next;
            },
        }
    }
}

/// Returns the NFC quick-check result for `str`.  This is a Unicode primitive,
/// it is not a quick way to check if text is normalized: much ordinary text in
/// NFC form will return `.maybe` from this function.  Those with an actual use
/// for this function will ordinarily prefer the cursor'ed version.
pub fn nfcQuickCheck(str: []const u8) IsNormal {
    var cursor: usize = 0;
    return quickCheckCursor(.nfc, str, &cursor);
}

/// Returns the NFC quick-check result for `str`, setting `cursor` to the offset
/// of the first code point that is not definitely NFC.  This is a Unicode
/// primitive widely used in this library, not a faster alternative to `isNfc`
/// (which uses this function heavily).
pub fn nfcQuickCheckCursor(str: []const u8, cursor: *usize) IsNormal {
    return quickCheckCursor(.nfc, str, cursor);
}

/// Normalizes `str` to NFKC.  This form has relatively little purpose in
/// practice, being basically the fourth quadrant out of three useful ones.
pub fn nfkc(allocator: Allocator, str: []const u8) OOM!Result {
    return nfxc(.nfkc, allocator, str);
}

/// Normalize `str` to NFD.  No 'stream safe' NFD is directly provided by zg.
/// Generally, text will not be read into a program in NFD form, and what is
/// avoided in the `nfc` algorithm is exactly decomposition to NFD, so there
/// would be little to gain from the distinction.
pub fn nfd(allocator: Allocator, str: []const u8) OOM!Result {
    return nfdResult(allocator, str);
}

/// Normalize `str` to NFKD.  This form is broadly useful for search.
pub fn nfkd(allocator: Allocator, str: []const u8) OOM!Result {
    return nfkdResult(allocator, str);
}

/// Returns the NFD quick-check result for `str`.
pub fn nfdQuickCheck(str: []const u8) IsNormal {
    var cursor: usize = 0;
    return quickCheckCursor(.nfd, str, &cursor);
}

/// Returns the NFD quick-check result for `str`, setting `cursor` to the
/// offset of the first code point that is not definitely NFD.
pub fn nfdQuickCheckCursor(str: []const u8, cursor: *usize) IsNormal {
    return quickCheckCursor(.nfd, str, cursor);
}

/// Tests for equality of `a` and `b` after normalizing to NFC, in the
/// actually-useful-but-not-Zalgo-safe manner.
pub fn eql(allocator: Allocator, a: []const u8, b: []const u8) !bool {
    const norm_result_a = try nfc(allocator, a);
    defer norm_result_a.deinit(allocator);
    const norm_result_b = try nfc(allocator, b);
    defer norm_result_b.deinit(allocator);

    return mem.eql(u8, norm_result_a.slice, norm_result_b.slice);
}

/// Returns true if `str` only contains Latin-1 Supplement code points. Uses
/// SIMD if possible.  This was an optimized fast path of earlier versions of
/// this library, and lacking any reason to remove it, here it remains.
pub fn isLatin1Only(str: []const u8) bool {
    var cp_iter = CodePointIterator{ .bytes = str };

    const vec_len = simd.suggestVectorLength(u32) orelse return blk: {
        break :blk while (cp_iter.next()) |cp| {
            if (cp.code > 256) break false;
        } else true;
    };

    const Vec = @Vector(vec_len, u32);

    outer: while (true) {
        var code_buf: [vec_len]u32 = undefined;
        const saved_cp_i = cp_iter.i;

        for (0..vec_len) |i| {
            if (cp_iter.next()) |cp| {
                code_buf[i] = cp.code;
            } else {
                cp_iter.i = saved_cp_i;
                break :outer;
            }
        }
        const v1: Vec = @bitCast(code_buf);
        const v2: Vec = @splat(256);
        if (@reduce(.Or, v1 > v2)) return false;
    }

    return while (cp_iter.next()) |cp| {
        if (cp.code > 256) break false;
    } else true;
}

//| Internal

fn nfdCodePoints(allocator: Allocator, cps: []const u21) OOM![]u21 {
    var dcp_list = std.array_list.Managed(u21).init(allocator);
    defer dcp_list.deinit();

    var dc_buf: [18]u21 = undefined;

    for (cps) |cp| {
        const dc = decompose(cp, .nfd, &dc_buf);

        if (dc.form == .same) {
            try dcp_list.append(cp);
        } else {
            try dcp_list.appendSlice(dc.cps);
        }
    }

    canonicalSort(dcp_list.items);

    return try dcp_list.toOwnedSlice();
}

fn nfkdCodePoints(allocator: Allocator, cps: []const u21) OOM![]u21 {
    var dcp_list = std.array_list.Managed(u21).init(allocator);
    defer dcp_list.deinit();

    var dc_buf: [18]u21 = undefined;

    for (cps) |cp| {
        const dc = decompose(cp, .nfkd, &dc_buf);

        if (dc.form == .same) {
            try dcp_list.append(cp);
        } else {
            try dcp_list.appendSlice(dc.cps);
        }
    }

    canonicalSort(dcp_list.items);

    return try dcp_list.toOwnedSlice();
}

fn nfxdCodePoints(allocator: Allocator, str: []const u8, comptime form: Form) OOM![]u21 {
    var dcp_list = std.array_list.Managed(u21).init(allocator);
    defer dcp_list.deinit();

    var cp_iter = CodePointIterator{ .bytes = str };
    var dc_buf: [18]u21 = undefined;

    while (cp_iter.next()) |cp| {
        const dc = decompose(cp.code, form, &dc_buf);
        if (dc.form == .same) {
            try dcp_list.append(cp.code);
        } else {
            try dcp_list.appendSlice(dc.cps);
        }
    }

    canonicalSort(dcp_list.items);

    return try dcp_list.toOwnedSlice();
}

inline fn quickCheck(comptime form: Form, cp: u21) IsNormal {
    return switch (form) {
        .nfc => NormQuickCheckData.isNormalNfc(cp),
        .nfd => NormQuickCheckData.isNormalNfd(cp),
        .nfkc => NormQuickCheckData.isNormalNfkc(cp),
        .nfkd => NormQuickCheckData.isNormalNfkd(cp),
        else => unreachable,
    };
}

fn quickCheckCursor(comptime form: Form, str: []const u8, cursor: *usize) IsNormal {
    var last_stable: ?usize = null;
    return quickCheckCursorWithLastStable(form, str, cursor, &last_stable);
}

fn quickCheckCursorWithLastStable(
    comptime form: Form,
    str: []const u8,
    cursor: *usize,
    last_stable: *?usize,
) IsNormal {
    var cp_cursor: code_point.uoffset = @intCast(cursor.*);
    var last_ccc: u8 = 0;

    while (code_point.decodeAtCursor(str, &cp_cursor)) |cp| {
        const quick = quickCheck(form, cp.code);
        if (quick != .yes) {
            cursor.* = cp.offset;
            return quick;
        }

        const ccc = CombiningData.ccc(cp.code);
        if (ccc != 0 and last_ccc > ccc) {
            cursor.* = cp.offset;
            return .no;
        }
        if (quick == .yes and ccc == 0) last_stable.* = cp.offset;
        last_ccc = ccc;
    }

    cursor.* = cp_cursor;
    return .yes;
}

const SBase: u21 = 0xAC00;
const LBase: u21 = 0x1100;
const VBase: u21 = 0x1161;
const TBase: u21 = 0x11A7;
const LCount: u21 = 19;
const VCount: u21 = 21;
const TCount: u21 = 28;
const NCount: u21 = 588; // VCount * TCount
const SCount: u21 = 11172; // LCount * NCount

pub const IsNormal = NormQuickCheckData.IsNormal;

fn decomposeHangul(cp: u21, buf: []u21) ?Decomp {
    const kind = HangulData.syllable(cp);
    if (kind != .LV and kind != .LVT) return null;

    const SIndex: u21 = cp - SBase;
    const LIndex: u21 = SIndex / NCount;
    const VIndex: u21 = (SIndex % NCount) / TCount;
    const TIndex: u21 = SIndex % TCount;
    const LPart: u21 = LBase + LIndex;
    const VPart: u21 = VBase + VIndex;

    var dc = Decomp{ .form = .nfd };
    buf[0] = LPart;
    buf[1] = VPart;

    if (TIndex == 0) {
        dc.cps = buf[0..2];
        return dc;
    }

    // TPart
    buf[2] = TBase + TIndex;
    dc.cps = buf[0..3];
    return dc;
}

fn composeHangulCanon(lv: u21, t: u21) u21 {
    assert(0x11A8 <= t and t <= 0x11C2);
    return lv + (t - TBase);
}

fn composeHangulFull(l: u21, v: u21, t: u21) u21 {
    assert(0x1100 <= l and l <= 0x1112);
    assert(0x1161 <= v and v <= 0x1175);
    const LIndex = l - LBase;
    const VIndex = v - VBase;
    const LVIndex = LIndex * NCount + VIndex * TCount;

    if (t == 0) return SBase + LVIndex;

    assert(0x11A8 <= t and t <= 0x11C2);
    const TIndex = t - TBase;

    return SBase + LVIndex + TIndex;
}

const Form = enum {
    nfc,
    nfd,
    nfkc,
    nfkd,
    same,
};

const stream_safe_limit: usize = 30;
const good_enough_scratch_cap: usize = stream_safe_limit + 2;

const Decomp = struct {
    form: Form = .same,
    cps: []const u21 = &.{},
};

const StreamStats = struct {
    initial_nonstarters: usize = 0,
    trailing_nonstarters: usize = 0,
    total_len: usize = 0,
    has_starter: bool = false,
};

// `mapping` retrieves the decomposition mapping for a code point as per the UCD.
fn mapping(cp: u21, form: Form) Decomp {
    var dc = Decomp{};

    switch (form) {
        .nfd => {
            dc.cps = CanonData.toNfd(cp);
            if (dc.cps.len != 0) dc.form = .nfd;
        },

        .nfkd => {
            dc.cps = CompatData.toNfkd(cp);
            if (dc.cps.len != 0) {
                dc.form = .nfkd;
            } else {
                dc.cps = CanonData.toNfd(cp);
                if (dc.cps.len != 0) dc.form = .nfkd;
            }
        },

        else => @panic("Normalizer.mapping only accepts form .nfd or .nfkd."),
    }

    return dc;
}

// `decompose` a code point to the specified normalization form, which should be either `.nfd` or `.nfkd`.
fn decompose(cp: u21, comptime form: Form, buf: []u21) Decomp {
    // ASCII
    if (cp < 128) return .{};

    // NFD / NFKD quick checks.
    switch (form) {
        .nfd => if (NormPropsData.isNfd(cp)) return .{},
        .nfkd => if (NormPropsData.isNfkd(cp)) return .{},
        else => @panic("Normalizer.decompose only accepts form .nfd or .nfkd."),
    }

    // Hangul precomposed syllable full decomposition.
    if (decomposeHangul(cp, buf)) |dc| return dc;

    // Full decomposition.
    var dc = Decomp{ .form = form };

    var result_index: usize = 0;
    var work_index: usize = 1;

    // Start work with argument code point.
    var work = [_]u21{cp} ++ [_]u21{0} ** 17;

    while (work_index > 0) {
        // Look at previous code point in work queue.
        work_index -= 1;
        const next = work[work_index];
        const m = mapping(next, form);

        // No more of decompositions for this code point.
        if (m.form == .same) {
            buf[result_index] = next;
            result_index += 1;
            continue;
        }

        // Work backwards through decomposition.
        // `i` starts at 1 because m_last is 1 past the last code point.
        var i: usize = 1;
        while (i <= m.cps.len) : ({
            i += 1;
            work_index += 1;
        }) {
            work[work_index] = m.cps[m.cps.len - i];
        }
    }

    dc.cps = buf[0..result_index];

    return dc;
}

fn nfdStats(cp: u21) StreamStats {
    // صَلَّى اللّٰهُ عَلَيْهِ وَسَلَّمَ
    var buf: [18]u21 = undefined;
    const dc = decompose(cp, .nfd, &buf);
    var same = [_]u21{cp};
    const cps = if (dc.form == .same) same[0..] else dc.cps;

    var stats = StreamStats{
        .total_len = cps.len,
    };

    while (stats.initial_nonstarters < cps.len and !CombiningData.isStarter(cps[stats.initial_nonstarters])) {
        stats.initial_nonstarters += 1;
    }

    stats.has_starter = stats.initial_nonstarters != cps.len;
    if (!stats.has_starter) {
        stats.trailing_nonstarters = cps.len;
        return stats;
    }

    var i = cps.len;
    while (i > 0) {
        i -= 1;
        if (CombiningData.isStarter(cps[i])) break;
        stats.trailing_nonstarters += 1;
    }

    return stats;
}

fn advanceStreamCount(nonstarter_count: *usize, stats: StreamStats) void {
    if (!stats.has_starter) {
        nonstarter_count.* += stats.total_len;
    } else {
        nonstarter_count.* = stats.trailing_nonstarters;
    }
}

fn composeCodePointsInPlace(dcps: []u21) usize {
    const tombstone = 0x1FFFF; // Convenient Cn noncharacter point

    while (true) {
        var i: usize = 1; // start at second code point.
        var deleted: usize = 0;

        block_check: while (i < dcps.len) : (i += 1) {
            const C = dcps[i];
            if (C == tombstone) continue :block_check;
            const cc_C = CombiningData.ccc(C);
            var starter_index: ?usize = null;
            var j: usize = i;

            while (true) {
                j -= 1;
                if (dcps[j] == tombstone) continue;

                if (CombiningData.isStarter(dcps[j])) {
                    for (dcps[(j + 1)..i]) |B| {
                        if (B == tombstone) continue;
                        const cc_B = CombiningData.ccc(B);
                        if (cc_B != 0 and isHangul(C)) continue :block_check;
                        if (cc_B >= cc_C) continue :block_check;
                    }

                    starter_index = j;
                    break;
                }

                if (j == 0) break;
            }

            if (starter_index) |sidx| {
                const L = dcps[sidx];
                var processed_hangul = false;

                if (isHangul(L) and isHangul(C)) {
                    const l_stype = HangulData.syllable(L);
                    const c_stype = HangulData.syllable(C);

                    if (l_stype == .LV and c_stype == .T) {
                        dcps[sidx] = composeHangulCanon(L, C);
                        dcps[i] = tombstone;
                        processed_hangul = true;
                    }

                    if (l_stype == .L and c_stype == .V) {
                        dcps[sidx] = composeHangulFull(L, C, 0);
                        dcps[i] = tombstone;
                        processed_hangul = true;
                    }

                    if (processed_hangul) deleted += 1;
                }

                if (!processed_hangul) {
                    if (CanonData.toNfc(.{ L, C })) |P| {
                        if (!NormPropsData.isFcx(P)) {
                            dcps[sidx] = P;
                            dcps[i] = tombstone;
                            deleted += 1;
                        }
                    }
                }
            }
        }

        if (deleted == 0) break;
    }

    var write: usize = 0;
    for (dcps) |cp| {
        if (cp == tombstone) continue;
        dcps[write] = cp;
        write += 1;
    }

    return write;
}

fn normalizeChunkMatchesNfc(str: []const u8) bool {
    var dc_buf: [18]u21 = undefined;
    var dcps: [good_enough_scratch_cap]u21 = undefined;
    var dcps_len: usize = 0;
    var cursor: code_point.uoffset = 0;

    while (code_point.decodeAtCursor(str, &cursor)) |cp| {
        const dc = decompose(cp.code, .nfd, &dc_buf);
        const cps = if (dc.form == .same) &[_]u21{cp.code} else dc.cps;
        if (dcps_len + cps.len > dcps.len) return false;

        @memcpy(dcps[dcps_len..][0..cps.len], cps);
        dcps_len += cps.len;
    }

    canonicalSort(dcps[0..dcps_len]);
    const c_len = composeCodePointsInPlace(dcps[0..dcps_len]);

    var out: [good_enough_scratch_cap * 4]u8 = undefined;
    var out_len: usize = 0;

    for (dcps[0..c_len]) |cp| {
        const len = unicode.utf8Encode(cp, out[out_len..][0..4]) catch unreachable;
        out_len += len;
    }

    return mem.eql(u8, str, out[0..out_len]);
}

// Returns `null` to indicate failure in a control-flow-friendly way.
fn checkNfcGoodEnoughRegion(
    str: []const u8,
    start: usize,
    unstable_offset: usize,
) ?usize {
    var cursor: code_point.uoffset = @intCast(start);
    var chunk_start = start;
    var nonstarter_count: usize = 0;

    while (code_point.decodeAtCursor(str, &cursor)) |cp| {
        const quick = quickCheck(.nfc, cp.code);
        const ccc = CombiningData.ccc(cp.code);

        if (cp.offset > unstable_offset and quick == .yes and ccc == 0) {
            if (!normalizeChunkMatchesNfc(str[chunk_start..cp.offset])) return null;
            return cp.offset;
        }

        const stats = nfdStats(cp.code);
        if (cp.offset > chunk_start and nonstarter_count + stats.initial_nonstarters > stream_safe_limit) {
            if (!normalizeChunkMatchesNfc(str[chunk_start..cp.offset])) return null;
            chunk_start = cp.offset;
            nonstarter_count = 0;
        }

        advanceStreamCount(&nonstarter_count, stats);
    }

    if (!normalizeChunkMatchesNfc(str[chunk_start..])) return null;
    return str.len;
}

// Compares code points by Canonical Combining Class order.
fn cccLess(_: void, lhs: u21, rhs: u21) bool {
    return CombiningData.ccc(lhs) < CombiningData.ccc(rhs);
}

// Applies the Canonical Sorting Algorithm.
fn canonicalSort(cps: []u21) void {
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const start: usize = i;
        while (i < cps.len and CombiningData.ccc(cps[i]) != 0) : (i += 1) {}
        mem.sort(u21, cps[start..i], {}, cccLess);
    }
}

fn decomposedCodePointsToResult(allocator: Allocator, dcps: []const u21) OOM!Result {
    var dstr_list = std.array_list.Managed(u8).init(allocator);
    defer dstr_list.deinit();
    var buf: [4]u8 = undefined;

    for (dcps) |dcp| {
        const len = unicode.utf8Encode(dcp, &buf) catch unreachable;
        try dstr_list.appendSlice(buf[0..len]);
    }

    return Result{ .allocated = true, .slice = try dstr_list.toOwnedSlice() };
}

fn nfdChunk(allocator: Allocator, str: []const u8) OOM!Result {
    const dcps = try nfxdCodePoints(allocator, str, .nfd);
    defer allocator.free(dcps);

    return decomposedCodePointsToResult(allocator, dcps);
}

fn nfdResult(allocator: Allocator, str: []const u8) OOM!Result {
    // Quick checks.
    if (ascii.isAsciiOnly(str)) return Result{ .slice = str };

    var qc_cursor: usize = 0;
    var last_stable: ?usize = null;
    switch (quickCheckCursorWithLastStable(.nfd, str, &qc_cursor, &last_stable)) {
        .yes => return Result{ .slice = str },
        .no, .maybe => {},
    }

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    const initial_unstable_start = last_stable orelse 0;
    try out.appendSlice(str[0..initial_unstable_start]);

    var copy_start: usize = initial_unstable_start;
    var last_stable_start: usize = initial_unstable_start;
    var have_stable = last_stable != null;
    var unstable_start: ?usize = initial_unstable_start;
    var cursor: code_point.uoffset = @intCast(qc_cursor);
    var last_ccc: u8 = 0;

    while (code_point.decodeAtCursor(str, &cursor)) |cp| {
        const quick = quickCheck(.nfd, cp.code);
        const ccc = CombiningData.ccc(cp.code);
        const stable = quick == .yes and ccc == 0;
        const unstable = quick != .yes or (ccc != 0 and last_ccc > ccc);

        if (unstable and unstable_start == null) {
            const start = if (have_stable) last_stable_start else 0;
            try out.appendSlice(str[copy_start..start]);
            unstable_start = start;
        }

        if (stable) {
            if (unstable_start) |start| {
                const normalized = try nfdChunk(allocator, str[start..cp.offset]);
                defer normalized.deinit(allocator);
                try out.appendSlice(normalized.slice);
                copy_start = cp.offset;
                unstable_start = null;
            }

            last_stable_start = cp.offset;
            have_stable = true;
        }

        last_ccc = ccc;
    }

    if (unstable_start) |start| {
        const normalized = try nfdChunk(allocator, str[start..]);
        defer normalized.deinit(allocator);
        try out.appendSlice(normalized.slice);
    } else {
        try out.appendSlice(str[copy_start..]);
    }

    return .{ .allocated = true, .slice = try out.toOwnedSlice() };
}

fn nfkdResult(allocator: Allocator, str: []const u8) OOM!Result {
    // Quick check for ASCII:
    if (ascii.isAsciiOnly(str)) return Result{ .slice = str };

    const dcps = try nfxdCodePoints(allocator, str, .nfkd);
    defer allocator.free(dcps);

    return decomposedCodePointsToResult(allocator, dcps);
}

// Composition (NFC, NFKC)

fn isHangul(cp: u21) bool {
    return cp >= 0x1100 and HangulData.syllable(cp) != .none;
}

fn nfxc(comptime form: Form, allocator: Allocator, str: []const u8) OOM!Result {
    // Quick checks.
    const non_ascii = ascii.nonAsciiSuffix(str);
    if (non_ascii.len == 0) return Result{ .slice = str };
    var qc_cursor: usize = 0;
    if (quickCheckCursor(form, non_ascii, &qc_cursor) == .yes) return Result{ .slice = str };

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var copy_start: usize = 0;
    var last_stable_start: usize = 0;
    var have_stable = false;
    var unstable_start: ?usize = null;
    var cursor: code_point.uoffset = 0;
    var last_ccc: u8 = 0;

    while (code_point.decodeAtCursor(str, &cursor)) |cp| {
        const quick = quickCheck(form, cp.code);
        const ccc = CombiningData.ccc(cp.code);
        const stable = quick == .yes and ccc == 0;
        const unstable = quick != .yes or (ccc != 0 and last_ccc > ccc);

        if (unstable and unstable_start == null) {
            const start = if (have_stable) last_stable_start else 0;
            try out.appendSlice(str[copy_start..start]);
            unstable_start = start;
        }

        if (stable) {
            if (unstable_start) |start| {
                const normalized = try nfxcChunk(form, allocator, str[start..cp.offset]);
                defer normalized.deinit(allocator);
                try out.appendSlice(normalized.slice);
                copy_start = cp.offset;
                unstable_start = null;
            }

            last_stable_start = cp.offset;
            have_stable = true;
        }

        last_ccc = ccc;
    }

    if (unstable_start) |start| {
        const normalized = try nfxcChunk(form, allocator, str[start..]);
        defer normalized.deinit(allocator);
        try out.appendSlice(normalized.slice);
    } else {
        try out.appendSlice(str[copy_start..]);
    }

    return .{ .allocated = true, .slice = try out.toOwnedSlice() };
}

fn nfxcChunk(comptime form: Form, allocator: Allocator, str: []const u8) OOM!Result {
    const dcps = if (form == .nfc)
        try nfxdCodePoints(allocator, str, .nfd)
    else
        try nfxdCodePoints(allocator, str, .nfkd);
    defer allocator.free(dcps);

    return composeCodePoints(allocator, dcps);
}

fn composeCodePoints(allocator: Allocator, dcps: []u21) OOM!Result {
    const c_len = composeCodePointsInPlace(dcps);

    var cstr_list = std.array_list.Managed(u8).init(allocator);
    defer cstr_list.deinit();
    var buf: [4]u8 = undefined;

    for (dcps[0..c_len]) |cp| {
        const len = unicode.utf8Encode(cp, &buf) catch unreachable;
        try cstr_list.appendSlice(buf[0..len]);
    }

    return Result{ .allocated = true, .slice = try cstr_list.toOwnedSlice() };
}

//| Tests

test "decompose" {
    var buf: [18]u21 = undefined;

    var dc = decompose('é', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ 'e', '\u{301}' }, dc.cps[0..2]);

    dc = decompose('\u{1e0a}', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ 'D', '\u{307}' }, dc.cps[0..2]);

    dc = decompose('\u{1e0a}', .nfkd, &buf);
    try testing.expect(dc.form == .nfkd);
    try testing.expectEqualSlices(u21, &[_]u21{ 'D', '\u{307}' }, dc.cps[0..2]);

    dc = decompose('\u{3189}', .nfd, &buf);
    try testing.expect(dc.form == .same);
    try testing.expect(dc.cps.len == 0);

    dc = decompose('\u{3189}', .nfkd, &buf);
    try testing.expect(dc.form == .nfkd);
    try testing.expectEqualSlices(u21, &[_]u21{'\u{1188}'}, dc.cps[0..1]);

    dc = decompose('\u{ace1}', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{1100}', '\u{1169}', '\u{11a8}' }, dc.cps[0..3]);

    dc = decompose('\u{ace1}', .nfkd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{1100}', '\u{1169}', '\u{11a8}' }, dc.cps[0..3]);

    dc = decompose('\u{3d3}', .nfd, &buf);
    try testing.expect(dc.form == .nfd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{3d2}', '\u{301}' }, dc.cps[0..2]);

    dc = decompose('\u{3d3}', .nfkd, &buf);
    try testing.expect(dc.form == .nfkd);
    try testing.expectEqualSlices(u21, &[_]u21{ '\u{3a5}', '\u{301}' }, dc.cps[0..2]);
}

test "nfd ASCII / no-alloc" {
    const allocator = testing.allocator;

    const result = try nfd(allocator, "Hello World!");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Hello World!", result.slice);
}

test "nfd !ASCII / alloc" {
    const allocator = testing.allocator;

    const result = try nfd(allocator, "Héllo World! \u{3d3}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("He\u{301}llo World! \u{3d2}\u{301}", result.slice);
}

test "nfd !ASCII already normalized / no-alloc" {
    const allocator = testing.allocator;
    const input = "He\u{301}llo World! \u{3d2}\u{301}";

    const result = try nfd(allocator, input);
    defer result.deinit(allocator);

    try testing.expectEqualStrings(input, result.slice);
    try testing.expect(!result.allocated);
    try testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(result.slice.ptr));
}

test "nfd normalizes only unstable windows" {
    const allocator = testing.allocator;
    const input = "prefix A\u{0315}\u{0328} suffix";

    const result = try nfd(allocator, input);
    defer result.deinit(allocator);

    try testing.expectEqualStrings("prefix A\u{0328}\u{0315} suffix", result.slice);
}

test "nfkd ASCII / no-alloc" {
    const allocator = testing.allocator;

    const result = try nfkd(allocator, "Hello World!");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Hello World!", result.slice);
}

test "nfkd !ASCII / alloc" {
    const allocator = testing.allocator;

    const result = try nfkd(allocator, "Héllo World! \u{3d3}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("He\u{301}llo World! \u{3a5}\u{301}", result.slice);
}

test "nfc" {
    const allocator = testing.allocator;

    const result = try nfcExact(allocator, "Complex char: \u{3D2}\u{301}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Complex char: \u{3D3}", result.slice);
}

test "nfkc" {
    const allocator = testing.allocator;

    const result = try nfkc(allocator, "Complex char: \u{03A5}\u{0301}");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("Complex char: \u{038E}", result.slice);
}

test "isNfcGoodEnough" {
    try testing.expect(isNfc("déjà vu"));
    try testing.expect(!isNfc("de\u{301}ja\u{300} vu"));
    try testing.expect(!isNfc("\u{1E0A}\u{0323}"));
    try testing.expect(isNfc("prefix: déjà vu"));
    try testing.expect(isNfc("prefix A\u{0316}\u{0316} suffix"));
    try testing.expect(!isNfc("A\u{0315}\u{0328}"));
    try testing.expect(!isNfc("\u{1100}\u{1161}"));

    var built = std.array_list.Managed(u8).init(testing.allocator);
    defer built.deinit();
    try built.append('A');

    var buf: [4]u8 = undefined;
    const mark_len = try unicode.utf8Encode(0x0316, &buf);
    for (0..31) |_| {
        try built.appendSlice(buf[0..mark_len]);
    }

    try testing.expect(isNfc(built.items));

    const acute_len = try unicode.utf8Encode(0x0301, &buf);
    try built.appendSlice(buf[0..acute_len]);
    try testing.expect(isNfc(built.items));

    const bad_len = try unicode.utf8Encode(0x0374, &buf);
    try built.appendSlice(buf[0..bad_len]);
    try testing.expect(!isNfc(built.items));
}

test "nfcGoodEnough" {
    {
        const input = "déjà vu";
        const result = try nfc(testing.allocator, input);
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings(input, result.slice);
        try testing.expect(!result.allocated);
        try testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(result.slice.ptr));
    }

    {
        const input = "prefix: déjà vu";
        const result = try nfc(testing.allocator, input);
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings(input, result.slice);
        try testing.expect(!result.allocated);
        try testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(result.slice.ptr));
    }

    {
        var built = std.array_list.Managed(u8).init(testing.allocator);
        defer built.deinit();
        try built.append('A');

        var buf: [4]u8 = undefined;
        const mark_len = try unicode.utf8Encode(0x0316, &buf);
        for (0..31) |_| {
            try built.appendSlice(buf[0..mark_len]);
        }

        const result = try nfc(testing.allocator, built.items);
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings(built.items, result.slice);
        try testing.expect(!result.allocated);
        try testing.expectEqual(@intFromPtr(built.items.ptr), @intFromPtr(result.slice.ptr));
    }

    {
        const input = "de\u{301}ja\u{300} vu";
        const result = try nfc(testing.allocator, input);
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings("déjà vu", result.slice);
    }

    {
        const input = "\u{1E0A}\u{0323}";
        const result = try nfc(testing.allocator, input);
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings("\u{1E0C}\u{0307}", result.slice);
    }

    {
        const input = "prefix A\u{0301} middle O\u{0301} suffix";
        const result = try nfc(testing.allocator, input);
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings("prefix Á middle Ó suffix", result.slice);
    }
}

test "nfc normalizes only unstable windows" {
    const allocator = testing.allocator;
    const input = "prefix A\u{0301} middle O\u{0301} suffix";

    const result = try nfcExact(allocator, input);
    defer result.deinit(allocator);

    try testing.expectEqualStrings("prefix Á middle Ó suffix", result.slice);
}

test "nfkc normalizes only unstable windows" {
    const allocator = testing.allocator;
    const input = "prefix \u{00A0}middle\u{00A0} suffix";

    const result = try nfkc(allocator, input);
    defer result.deinit(allocator);

    try testing.expectEqualStrings("prefix  middle  suffix", result.slice);
}

test "eql" {
    const allocator = testing.allocator;

    try testing.expect(try eql(allocator, "foé", "foe\u{0301}"));
    try testing.expect(try eql(allocator, "foϓ", "fo\u{03D2}\u{0301}"));
}

test "isLatin1Only" {
    const latin1_only = "Hello, World! \u{fe} \u{ff}";
    try testing.expect(isLatin1Only(latin1_only));
    const not_latin1_only = "Héllo, World! \u{3d3}";
    try testing.expect(!isLatin1Only(not_latin1_only));
}

test "nfcQuickCheck" {
    try testing.expectEqual(.yes, nfcQuickCheck("déjà vu"));
    try testing.expectEqual(.maybe, nfcQuickCheck("a\u{0328}"));
    try testing.expectEqual(.no, nfcQuickCheck("\u{0374}"));
}

test "nfdQuickCheck" {
    try testing.expectEqual(.yes, nfdQuickCheck("de\u{301}ja\u{300} vu"));
    try testing.expectEqual(.no, nfdQuickCheck("déjà vu"));
    try testing.expectEqual(.no, nfdQuickCheck("A\u{0315}\u{0328}"));
}

test "nfcQuickCheckCursor" {
    {
        const str = "déjà vu";
        var cursor: usize = 0;
        try testing.expectEqual(.yes, nfcQuickCheckCursor(str, &cursor));
        try testing.expectEqual(str.len, cursor);
    }

    {
        const str = "A\u{0328}bc";
        var cursor: usize = 0;
        try testing.expectEqual(.maybe, nfcQuickCheckCursor(str, &cursor));
        try testing.expectEqual(1, cursor);
    }

    {
        const str = "A\u{0374}bc";
        var cursor: usize = 0;
        try testing.expectEqual(.no, nfcQuickCheckCursor(str, &cursor));
        try testing.expectEqual(1, cursor);
    }
}

test "nfdQuickCheckCursor" {
    {
        const str = "de\u{301}ja\u{300} vu";
        var cursor: usize = 0;
        try testing.expectEqual(.yes, nfdQuickCheckCursor(str, &cursor));
        try testing.expectEqual(str.len, cursor);
    }

    {
        const str = "déjà vu";
        var cursor: usize = 0;
        try testing.expectEqual(.no, nfdQuickCheckCursor(str, &cursor));
        try testing.expectEqual(1, cursor);
    }

    {
        const str = "A\u{0315}\u{0328}bc";
        var cursor: usize = 0;
        try testing.expectEqual(.no, nfdQuickCheckCursor(str, &cursor));
        try testing.expectEqual(3, cursor);
    }
}

const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const simd = std.simd;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = mem.Allocator;
const OOM = Allocator.Error;

const ascii = @import("ascii");
const code_point = @import("code_point");
const CodePointIterator = code_point.Iterator;

const CanonData = @import("CanonData");
const CombiningData = @import("CombiningData");
const CompatData = @import("CompatData");
const HangulData = @import("HangulData");
const NormPropsData = @import("NormPropsData");
const NormQuickCheckData = @import("NormQuickCheckData");
