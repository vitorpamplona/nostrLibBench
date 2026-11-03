//! Caseless Matching
//!
//! This module provides allocation free, stream safe caseless matching in both
//! canonical or compatibility formats.
//!
//! "Stream safe" means that a limit on the rearrangement of codepoints is
//! imposed.  The algorithm is unbounded, but real text does not take advantage
//! of this fact, so Unicode defines an algorithm which is much faster and
//! optimally useful, but cannot be used to caselessly match Zalgo text, even if
//! someone unfriendly feeds such into your program just to see what happens.

pub const Flavor = enum {
    canon,
    compat,
};

/// Canonically caseless-match `a` and `b`.
pub fn canonMatch(a: []const u8, b: []const u8) bool {
    var matcher = CaselessMatcher(.canon).default;
    return matcher.match(a, b);
}

/// Compatibility caseless-match `a` and `b`.
pub fn compatMatch(a: []const u8, b: []const u8) bool {
    var matcher = CaselessMatcher(.compat).default;
    return matcher.match(a, b);
}

pub fn nfcCaseFoldableQC(cp: u21) IsNfcCaseFoldable {
    return CaselessMatchData.nfcCaseFoldableQC(cp);
}

/// A caseless matcher for canonical matching.  You may wish to
/// keep this around if you plan to use it frequently.
pub const CanonCaselessMatcher = CaselessMatcher(.canon);

/// A caseless matcher for compatibility matching.  You may wish to
/// keep this around if you plan to use it frequently.
pub const CompatibilityCaselessMatcher = CaselessMatcher(.compat);

fn CaselessMatcher(comptime flavor: Flavor) type {
    return struct {
        state_a: TransformState(flavor) = TransformState(flavor).init(""),
        state_b: TransformState(flavor) = TransformState(flavor).init(""),
        cp_buf: [default_buffer_size]u21 = undefined,

        const CaseMatch = @This();
        pub const default: CaseMatch = .{};

        pub fn create(allocator: Allocator) OOM!*CaseMatch {
            const matcher = try allocator.create(CaseMatch);
            matcher.* = .default;
            return matcher;
        }

        pub fn destroy(cmatch: *CaseMatch, allocator: Allocator) void {
            allocator.destroy(cmatch);
        }

        pub fn match(cmatch: *CaseMatch, a: []const u8, b: []const u8) bool {
            const half = default_buffer_size / 2;
            return compareStates(
                flavor,
                a,
                b,
                &cmatch.state_a,
                &cmatch.state_b,
                cmatch.cp_buf[0..half],
                cmatch.cp_buf[half..],
            );
        }
    };
}

pub fn CaselessSearcher(
    comptime needle_cp_buffer_len: comptime_int,
    comptime flavor: Flavor,
) type {
    return struct {
        haystack_state: TransformSearchState(flavor) = TransformSearchState(flavor).init(""),
        needle_cp_buf: [needle_cp_buffer_len]u21 = undefined,
        haystack_cp_buf: [scratch_cap]u21 = undefined,
        haystack_end_buf: [scratch_cap]usize = undefined,

        const CaseSearch = @This();
        pub const default: CaseSearch = .{};

        pub fn create(allocator: Allocator) OOM!*CaseSearch {
            const searcher = try allocator.create(CaseSearch);
            searcher.* = .default;
            return searcher;
        }

        pub fn destroy(csearch: *CaseSearch, allocator: Allocator) void {
            allocator.destroy(csearch);
        }

        pub fn match(csearch: *CaseSearch, haystack: []const u8, needle: []const u8) error{NeedleTooLarge}!?[]const u8 {
            return csearch.matchPos(haystack, needle, 0);
        }

        pub fn matchPos(
            csearch: *CaseSearch,
            haystack: []const u8,
            needle: []const u8,
            index: usize,
        ) error{NeedleTooLarge}!?[]const u8 {
            if (index > haystack.len) return null;
            if (needle.len == 0) return haystack[index..][0..0];

            const needle_len = try materializeNeedleInto(
                flavor,
                needle,
                csearch.needle_cp_buf[0..],
            );

            return searchTransformedNeedle(
                flavor,
                &csearch.haystack_state,
                csearch.haystack_cp_buf[0..],
                csearch.haystack_end_buf[0..],
                haystack,
                index,
                csearch.needle_cp_buf[0..needle_len],
            );
        }

        pub fn matchAlloc(
            csearch: *CaseSearch,
            allocator: Allocator,
            haystack: []const u8,
            needle: []const u8,
        ) OOM!?[]const u8 {
            return csearch.matchAllocPos(allocator, haystack, needle, 0);
        }

        pub fn matchAllocPos(
            csearch: *CaseSearch,
            allocator: Allocator,
            haystack: []const u8,
            needle: []const u8,
            index: usize,
        ) OOM!?[]const u8 {
            return csearch.matchPos(haystack, needle, index) catch |err| switch (err) {
                error.NeedleTooLarge => {
                    const needle_cps = try materializeNeedleAlloc(flavor, allocator, needle);
                    defer allocator.free(needle_cps);

                    return searchTransformedNeedle(
                        flavor,
                        &csearch.haystack_state,
                        csearch.haystack_cp_buf[0..],
                        csearch.haystack_end_buf[0..],
                        haystack,
                        index,
                        needle_cps,
                    );
                },
            };
        }
    };
}

fn compareStates(
    comptime flavor: Flavor,
    a_raw: []const u8,
    b_raw: []const u8,
    state_a: *TransformState(flavor),
    state_b: *TransformState(flavor),
    buf_a: []u21,
    buf_b: []u21,
) bool {
    assert(buf_a.len >= scratch_cap);
    assert(buf_b.len >= scratch_cap);

    var a = a_raw;
    var b = b_raw;

    if (std.mem.eql(u8, a, b)) return true;

    const prefix_bound = @min(a.len, b.len);
    const prefix = ascii.caselessCmpLen(a[0..prefix_bound], b[0..prefix_bound]);
    if (prefix == a.len and prefix == b.len) return true;

    a = a[prefix..];
    b = b[prefix..];

    if (flavor == .canon) {
        switch (compareCanonNfcFast(a, b)) {
            .matched => return true,
            .fallback => |rem| {
                a = rem.a;
                b = rem.b;
            },
        }
    }

    state_a.* = TransformState(flavor).init(a);
    state_b.* = TransformState(flavor).init(b);

    while (true) {
        const a_cp = state_a.next(buf_a);
        const b_cp = state_b.next(buf_b);

        if (a_cp == null or b_cp == null) return a_cp == null and b_cp == null;
        if (a_cp.? != b_cp.?) return false;
    }
}

const HareCompare = union(enum) {
    matched,
    fallback: struct {
        a: []const u8,
        b: []const u8,
    },
};

const HareFill = enum {
    ready,
    eof,
    fallback,
};

const IsNfcCaseFoldable = CaselessMatchData.IsCaseFoldable;

const HareState = struct {
    bytes: []const u8,
    cursor: code_point.uoffset = 0,
    last_ccc: u8 = 0,
    queue: [3]u21 = undefined,
    queue_len: usize = 0,
    queue_pos: usize = 0,

    fn init(bytes: []const u8) HareState {
        return .{ .bytes = bytes };
    }

    fn queueEmpty(state: *const HareState) bool {
        return state.queue_pos == state.queue_len;
    }

    // nfcQuickCheck adapted to reject points which need decomposition.
    fn ensureReady(state: *HareState) HareFill {
        if (!state.queueEmpty()) return .ready;

        var cursor = state.cursor;
        const cp = code_point.decodeAtCursor(state.bytes, &cursor) orelse return .eof;
        const ccc = CombiningData.ccc(cp.code);

        if (NormQuickCheckData.isNormalNfc(cp.code) != .yes) return .fallback;
        if (ccc != 0 and state.last_ccc > ccc) return .fallback;
        if (nfcCaseFoldableQC(cp.code) != .yes) return .fallback;

        const folded = CaseFolding.caseFold(cp.code, &state.queue);
        state.cursor = cursor;
        state.last_ccc = ccc;
        state.queue_len = folded.len;
        state.queue_pos = 0;
        return .ready;
    }

    fn peek(state: *const HareState) u21 {
        return state.queue[state.queue_pos];
    }

    fn advance(state: *HareState) void {
        state.queue_pos += 1;
    }
};

fn compareCanonNfcFast(a: []const u8, b: []const u8) HareCompare {
    var state_a = HareState.init(a);
    var state_b = HareState.init(b);
    var committed_a: usize = 0;
    var committed_b: usize = 0;

    while (true) {
        if (state_a.queueEmpty() and state_b.queueEmpty()) {
            committed_a = @intCast(state_a.cursor);
            committed_b = @intCast(state_b.cursor);
        }

        const fill_a = state_a.ensureReady();
        const fill_b = state_b.ensureReady();

        if (fill_a == .fallback or fill_b == .fallback) {
            return .{ .fallback = .{ .a = a[committed_a..], .b = b[committed_b..] } };
        }

        if (fill_a == .eof or fill_b == .eof) {
            if (fill_a == .eof and fill_b == .eof) return .matched;
            return .{ .fallback = .{ .a = a[committed_a..], .b = b[committed_b..] } };
        }

        if (state_a.peek() != state_b.peek()) {
            return .{ .fallback = .{ .a = a[committed_a..], .b = b[committed_b..] } };
        }

        state_a.advance();
        state_b.advance();
    }
}

fn materializeNeedleInto(
    comptime flavor: Flavor,
    needle: []const u8,
    out: []u21,
) error{NeedleTooLarge}!usize {
    var tstate = TransformState(flavor).init(needle);
    var scratch: [scratch_cap]u21 = undefined;
    var written: usize = 0;

    while (tstate.next(scratch[0..])) |cp| {
        if (written == out.len) return error.NeedleTooLarge;
        out[written] = cp;
        written += 1;
    }

    return written;
}

fn materializeNeedleAlloc(
    comptime flavor: Flavor,
    allocator: Allocator,
    needle: []const u8,
) OOM![]u21 {
    var list = std.array_list.Managed(u21).init(allocator);
    defer list.deinit();

    var tstate = TransformState(flavor).init(needle);
    var scratch: [scratch_cap]u21 = undefined;

    while (tstate.next(scratch[0..])) |cp| {
        try list.append(cp);
    }

    return try list.toOwnedSlice();
}

fn searchTransformedNeedle(
    comptime flavor: Flavor,
    hstate: *TransformSearchState(flavor),
    haystack_cp_buf: []u21,
    haystack_end_buf: []usize,
    haystack: []const u8,
    index: usize,
    needle_cps: []const u21,
) ?[]const u8 {
    if (index > haystack.len) return null;
    if (needle_cps.len == 0) return haystack[0..0];

    var cursor: code_point.uoffset = @intCast(index);
    while (true) {
        const start: usize = @intCast(cursor);

        if (matchNeedleAt(
            flavor,
            hstate,
            haystack_cp_buf,
            haystack_end_buf,
            haystack[start..],
            needle_cps,
        )) |end| {
            return haystack[start .. start + end];
        }

        _ = code_point.decodeAtCursor(haystack, &cursor) orelse break;
    }

    return null;
}

fn matchNeedleAt(
    comptime flavor: Flavor,
    hstate: *TransformSearchState(flavor),
    haystack_cp_buf: []u21,
    haystack_end_buf: []usize,
    haystack: []const u8,
    needle_cps: []const u21,
) ?usize {
    hstate.* = TransformSearchState(flavor).init(haystack);

    var end: usize = 0;
    for (needle_cps) |needle_cp| {
        const hitem = hstate.next(haystack_cp_buf, haystack_end_buf) orelse return null;
        if (hitem.cp != needle_cp) return null;
        end = hitem.end;
    }

    return end;
}

const ByteState = struct {
    bytes: []const u8,
    cursor: code_point.uoffset = 0,

    fn init(bytes: []const u8) ByteState {
        return .{ .bytes = bytes };
    }

    fn next(state: *ByteState) ?u21 {
        const cp = code_point.decodeAtCursor(state.bytes, &state.cursor) orelse return null;
        return cp.code;
    }
};

fn StreamSafeState(comptime Upstream: type) type {
    return struct {
        upstream: Upstream,
        nonstarter_count: usize = 0,
        pending_cp: u21 = 0,
        pending_stats: Stats = .{},
        has_pending: bool = false,

        const Self = @This();

        fn init(upstream: Upstream) Self {
            return .{ .upstream = upstream };
        }

        fn next(state: *Self) ?u21 {
            if (state.has_pending) {
                state.has_pending = false;
                state.advance(state.pending_stats);
                return state.pending_cp;
            }

            const cp = state.upstream.next() orelse return null;
            const stats = nfkdStats(cp);

            if (state.nonstarter_count + stats.initial_nonstarters > stream_safe_limit) {
                state.pending_cp = cp;
                state.pending_stats = stats;
                state.has_pending = true;
                state.nonstarter_count = 0;
                return cgj;
            }

            state.advance(stats);
            return cp;
        }

        fn advance(state: *Self, stats: Stats) void {
            if (!stats.has_starter) {
                state.nonstarter_count += stats.total_len;
            } else {
                state.nonstarter_count = stats.trailing_nonstarters;
            }
            assert(state.nonstarter_count <= stream_safe_limit);
        }
    };
}

fn NormalizeState(comptime form: Form, comptime Upstream: type) type {
    return struct {
        upstream: Upstream,
        pending: [18]u21 = undefined,
        pending_len: usize = 0,
        pending_pos: usize = 0,
        queue: [scratch_cap]u21 = undefined,
        queue_len: usize = 0,
        queue_pos: usize = 0,
        segment_len: usize = 0,
        done: bool = false,

        const Self = @This();

        fn init(upstream: Upstream) Self {
            return .{ .upstream = upstream };
        }

        fn next(state: *Self) ?u21 {
            if (state.queue_pos == state.queue_len) {
                state.refill();
            }

            if (state.queue_pos == state.queue_len) return null;

            const cp = state.queue[state.queue_pos];
            state.queue_pos += 1;
            return cp;
        }

        fn refill(state: *Self) void {
            if (state.done) return;

            state.queue_pos = 0;
            state.queue_len = 0;
            state.segment_len = 0;

            while (true) {
                const cp = state.nextDecomposed() orelse {
                    state.done = true;
                    state.finalizeQueue();
                    return;
                };

                if (CombiningData.isStarter(cp) and state.segment_len != 0) {
                    state.pending_pos -= 1;
                    state.finalizeQueue();
                    return;
                }

                assert(state.segment_len < state.queue.len);
                state.queue[state.segment_len] = cp;
                state.segment_len += 1;
            }
        }

        fn nextDecomposed(state: *Self) ?u21 {
            while (state.pending_pos == state.pending_len) {
                state.pending_pos = 0;
                state.pending_len = 0;

                const cp = state.upstream.next() orelse return null;
                var dc_buf: [18]u21 = undefined;
                const dc = decompose(cp, form, &dc_buf);

                if (dc.form == .same) {
                    state.pending[0] = cp;
                    state.pending_len = 1;
                } else {
                    @memcpy(state.pending[0..dc.cps.len], dc.cps);
                    state.pending_len = dc.cps.len;
                }
            }

            const cp = state.pending[state.pending_pos];
            state.pending_pos += 1;
            return cp;
        }

        fn finalizeQueue(state: *Self) void {
            canonicalSort(state.queue[0..state.segment_len]);
            state.queue_len = state.segment_len;
        }
    };
}

fn CaseFoldState(comptime Upstream: type) type {
    return struct {
        upstream: Upstream,
        queue: [3]u21 = undefined,
        queue_len: usize = 0,
        queue_pos: usize = 0,

        const Self = @This();

        fn init(upstream: Upstream) Self {
            return .{ .upstream = upstream };
        }

        fn next(state: *Self) ?u21 {
            while (state.queue_pos == state.queue_len) {
                const cp = state.upstream.next() orelse return null;
                const folded = CaseFolding.caseFold(cp, &state.queue);
                state.queue_len = folded.len;
                state.queue_pos = 0;
            }

            const cp = state.queue[state.queue_pos];
            state.queue_pos += 1;
            return cp;
        }
    };
}

pub fn TransformState(comptime flavor: Flavor) type {
    const SafeBytes = StreamSafeState(ByteState);
    const NfdSource = NormalizeState(.nfd, SafeBytes);

    const Upstream = switch (flavor) {
        .canon => StreamSafeState(CaseFoldState(NfdSource)),
        .compat => StreamSafeState(CaseFoldState(
            NormalizeState(.nfkd, StreamSafeState(CaseFoldState(NfdSource))),
        )),
    };

    const final_form = switch (flavor) {
        .canon => Form.nfd,
        .compat => Form.nfkd,
    };

    return struct {
        upstream: Upstream,
        pending: [18]u21 = undefined,
        pending_len: usize = 0,
        pending_pos: usize = 0,
        queue_len: usize = 0,
        queue_pos: usize = 0,
        segment_len: usize = 0,
        done: bool = false,

        const Self = @This();

        fn init(bytes: []const u8) Self {
            const safe_bytes = SafeBytes.init(ByteState.init(bytes));
            const nfd_source = NfdSource.init(safe_bytes);

            return .{
                .upstream = switch (flavor) {
                    .canon => blk: {
                        const folded = CaseFoldState(NfdSource).init(nfd_source);
                        break :blk Upstream.init(folded);
                    },
                    .compat => blk: {
                        const folded_1 = CaseFoldState(NfdSource).init(nfd_source);
                        const safe_folded_1 = StreamSafeState(CaseFoldState(NfdSource)).init(folded_1);
                        const nfkd_1 = NormalizeState(
                            .nfkd,
                            StreamSafeState(CaseFoldState(NfdSource)),
                        ).init(safe_folded_1);
                        const folded_2 = CaseFoldState(
                            NormalizeState(.nfkd, StreamSafeState(CaseFoldState(NfdSource))),
                        ).init(nfkd_1);
                        break :blk Upstream.init(folded_2);
                    },
                },
            };
        }

        fn next(state: *Self, scratch: []u21) ?u21 {
            assert(scratch.len >= scratch_cap);

            if (state.queue_pos == state.queue_len) {
                state.refill(scratch);
            }

            if (state.queue_pos == state.queue_len) return null;

            const cp = scratch[state.queue_pos];
            state.queue_pos += 1;
            return cp;
        }

        fn refill(state: *Self, scratch: []u21) void {
            if (state.done) return;

            state.queue_pos = 0;
            state.queue_len = 0;
            state.segment_len = 0;

            while (true) {
                const cp = state.nextDecomposed() orelse {
                    state.done = true;
                    state.finalizeQueue(scratch);
                    return;
                };

                if (CombiningData.isStarter(cp) and state.segment_len != 0) {
                    state.pending_pos -= 1;
                    state.finalizeQueue(scratch);
                    return;
                }

                assert(state.segment_len < scratch.len);
                scratch[state.segment_len] = cp;
                state.segment_len += 1;
            }
        }

        fn nextDecomposed(state: *Self) ?u21 {
            while (state.pending_pos == state.pending_len) {
                state.pending_pos = 0;
                state.pending_len = 0;

                const cp = state.upstream.next() orelse return null;
                var dc_buf: [18]u21 = undefined;
                const dc = decompose(cp, final_form, &dc_buf);

                if (dc.form == .same) {
                    state.pending[0] = cp;
                    state.pending_len = 1;
                } else {
                    @memcpy(state.pending[0..dc.cps.len], dc.cps);
                    state.pending_len = dc.cps.len;
                }
            }

            const cp = state.pending[state.pending_pos];
            state.pending_pos += 1;
            return cp;
        }

        fn finalizeQueue(state: *Self, scratch: []u21) void {
            canonicalSort(scratch[0..state.segment_len]);
            state.queue_len = state.segment_len;
        }
    };
}

const SearchItem = struct {
    cp: u21,
    end: usize,
};

const SearchByteState = struct {
    bytes: []const u8,
    cursor: code_point.uoffset = 0,

    fn init(bytes: []const u8) SearchByteState {
        return .{ .bytes = bytes };
    }

    fn next(bstate: *SearchByteState) ?SearchItem {
        const cp = code_point.decodeAtCursor(bstate.bytes, &bstate.cursor) orelse return null;
        return .{ .cp = cp.code, .end = bstate.cursor };
    }
};

fn SearchStreamSafeState(comptime Upstream: type) type {
    return struct {
        upstream: Upstream,
        nonstarter_count: usize = 0,
        pending: SearchItem = .{ .cp = 0, .end = 0 },
        pending_stats: Stats = .{},
        has_pending: bool = false,

        const SState = @This();

        fn init(upstream: Upstream) SState {
            return .{ .upstream = upstream };
        }

        fn next(sstate: *SState) ?SearchItem {
            if (sstate.has_pending) {
                sstate.has_pending = false;
                sstate.advance(sstate.pending_stats);
                return sstate.pending;
            }

            const item = sstate.upstream.next() orelse return null;
            const stats = nfkdStats(item.cp);

            if (sstate.nonstarter_count + stats.initial_nonstarters > stream_safe_limit) {
                sstate.pending = item;
                sstate.pending_stats = stats;
                sstate.has_pending = true;
                sstate.nonstarter_count = 0;
                return .{ .cp = cgj, .end = item.end };
            }

            sstate.advance(stats);
            return item;
        }

        fn advance(sstate: *SState, stats: Stats) void {
            if (!stats.has_starter) {
                sstate.nonstarter_count += stats.total_len;
            } else {
                sstate.nonstarter_count = stats.trailing_nonstarters;
            }
            assert(sstate.nonstarter_count <= stream_safe_limit);
        }
    };
}

fn SearchNormalizeState(comptime form: Form, comptime Upstream: type) type {
    return struct {
        upstream: Upstream,
        pending: [18]u21 = undefined,
        pending_end: usize = 0,
        pending_len: usize = 0,
        pending_pos: usize = 0,
        queue: [scratch_cap]u21 = undefined,
        queue_end: [scratch_cap]usize = undefined,
        queue_len: usize = 0,
        queue_pos: usize = 0,
        segment_len: usize = 0,
        done: bool = false,

        const NState = @This();

        fn init(upstream: Upstream) NState {
            return .{ .upstream = upstream };
        }

        fn next(nstate: *NState) ?SearchItem {
            if (nstate.queue_pos == nstate.queue_len) {
                nstate.refill();
            }

            if (nstate.queue_pos == nstate.queue_len) return null;

            const idx = nstate.queue_pos;
            nstate.queue_pos += 1;
            return .{
                .cp = nstate.queue[idx],
                .end = nstate.queue_end[idx],
            };
        }

        fn refill(nstate: *NState) void {
            if (nstate.done) return;

            nstate.queue_pos = 0;
            nstate.queue_len = 0;
            nstate.segment_len = 0;

            while (true) {
                const item = nstate.nextDecomposed() orelse {
                    nstate.done = true;
                    nstate.finalizeQueue();
                    return;
                };

                if (CombiningData.isStarter(item.cp) and nstate.segment_len != 0) {
                    nstate.pending_pos -= 1;
                    nstate.finalizeQueue();
                    return;
                }

                assert(nstate.segment_len < nstate.queue.len);
                nstate.queue[nstate.segment_len] = item.cp;
                nstate.queue_end[nstate.segment_len] = item.end;
                nstate.segment_len += 1;
            }
        }

        fn nextDecomposed(nstate: *NState) ?SearchItem {
            while (nstate.pending_pos == nstate.pending_len) {
                nstate.pending_pos = 0;
                nstate.pending_len = 0;

                const item = nstate.upstream.next() orelse return null;
                var dc_buf: [18]u21 = undefined;
                const dc = decompose(item.cp, form, &dc_buf);

                nstate.pending_end = item.end;
                if (dc.form == .same) {
                    nstate.pending[0] = item.cp;
                    nstate.pending_len = 1;
                } else {
                    @memcpy(nstate.pending[0..dc.cps.len], dc.cps);
                    nstate.pending_len = dc.cps.len;
                }
            }

            const cp = nstate.pending[nstate.pending_pos];
            nstate.pending_pos += 1;
            return .{ .cp = cp, .end = nstate.pending_end };
        }

        fn finalizeQueue(nstate: *NState) void {
            canonicalSortWithEnds(
                nstate.queue[0..nstate.segment_len],
                nstate.queue_end[0..nstate.segment_len],
            );
            nstate.queue_len = nstate.segment_len;
        }
    };
}

fn SearchCaseFoldState(comptime Upstream: type) type {
    return struct {
        upstream: Upstream,
        queue: [3]u21 = undefined,
        end: usize = 0,
        queue_len: usize = 0,
        queue_pos: usize = 0,

        const CState = @This();

        fn init(upstream: Upstream) CState {
            return .{ .upstream = upstream };
        }

        fn next(cstate: *CState) ?SearchItem {
            while (cstate.queue_pos == cstate.queue_len) {
                const item = cstate.upstream.next() orelse return null;
                const folded = CaseFolding.caseFold(item.cp, &cstate.queue);
                cstate.end = item.end;
                cstate.queue_len = folded.len;
                cstate.queue_pos = 0;
            }

            const cp = cstate.queue[cstate.queue_pos];
            cstate.queue_pos += 1;
            return .{ .cp = cp, .end = cstate.end };
        }
    };
}

fn TransformSearchState(comptime flavor: Flavor) type {
    const SState = SearchStreamSafeState(SearchByteState);
    const NState = SearchNormalizeState(.nfd, SState);

    const Upstream = switch (flavor) {
        .canon => SearchStreamSafeState(SearchCaseFoldState(NState)),
        .compat => SearchStreamSafeState(SearchCaseFoldState(
            SearchNormalizeState(.nfkd, SearchStreamSafeState(SearchCaseFoldState(NState))),
        )),
    };

    const final_form = switch (flavor) {
        .canon => Form.nfd,
        .compat => Form.nfkd,
    };

    return struct {
        upstream: Upstream,
        pending: [18]u21 = undefined,
        pending_end: usize = 0,
        pending_len: usize = 0,
        pending_pos: usize = 0,
        queue_len: usize = 0,
        queue_pos: usize = 0,
        segment_len: usize = 0,
        done: bool = false,

        const TState = @This();

        fn init(bytes: []const u8) TState {
            const bstate = SearchByteState.init(bytes);
            const sstate = SState.init(bstate);
            const nstate = NState.init(sstate);

            return .{
                .upstream = switch (flavor) {
                    .canon => blk: {
                        const cstate = SearchCaseFoldState(NState).init(nstate);
                        break :blk Upstream.init(cstate);
                    },
                    .compat => blk: {
                        const cstate_1 = SearchCaseFoldState(NState).init(nstate);
                        const sstate_1 = SearchStreamSafeState(SearchCaseFoldState(NState)).init(cstate_1);
                        const nstate_1 = SearchNormalizeState(
                            .nfkd,
                            SearchStreamSafeState(SearchCaseFoldState(NState)),
                        ).init(sstate_1);
                        const cstate_2 = SearchCaseFoldState(
                            SearchNormalizeState(.nfkd, SearchStreamSafeState(SearchCaseFoldState(NState))),
                        ).init(nstate_1);
                        break :blk Upstream.init(cstate_2);
                    },
                },
            };
        }

        fn next(tstate: *TState, scratch: []u21, scratch_end: []usize) ?SearchItem {
            assert(scratch.len >= scratch_cap);
            assert(scratch_end.len >= scratch.len);

            if (tstate.queue_pos == tstate.queue_len) {
                tstate.refill(scratch, scratch_end);
            }

            if (tstate.queue_pos == tstate.queue_len) return null;

            const idx = tstate.queue_pos;
            tstate.queue_pos += 1;
            return .{
                .cp = scratch[idx],
                .end = scratch_end[idx],
            };
        }

        fn refill(tstate: *TState, scratch: []u21, scratch_end: []usize) void {
            if (tstate.done) return;

            tstate.queue_pos = 0;
            tstate.queue_len = 0;
            tstate.segment_len = 0;

            while (true) {
                const item = tstate.nextDecomposed() orelse {
                    tstate.done = true;
                    tstate.finalizeQueue(scratch, scratch_end);
                    return;
                };

                if (CombiningData.isStarter(item.cp) and tstate.segment_len != 0) {
                    tstate.pending_pos -= 1;
                    tstate.finalizeQueue(scratch, scratch_end);
                    return;
                }

                assert(tstate.segment_len < scratch.len);
                scratch[tstate.segment_len] = item.cp;
                scratch_end[tstate.segment_len] = item.end;
                tstate.segment_len += 1;
            }
        }

        fn nextDecomposed(tstate: *TState) ?SearchItem {
            while (tstate.pending_pos == tstate.pending_len) {
                tstate.pending_pos = 0;
                tstate.pending_len = 0;

                const item = tstate.upstream.next() orelse return null;
                var dc_buf: [18]u21 = undefined;
                const dc = decompose(item.cp, final_form, &dc_buf);

                tstate.pending_end = item.end;
                if (dc.form == .same) {
                    tstate.pending[0] = item.cp;
                    tstate.pending_len = 1;
                } else {
                    @memcpy(tstate.pending[0..dc.cps.len], dc.cps);
                    tstate.pending_len = dc.cps.len;
                }
            }

            const cp = tstate.pending[tstate.pending_pos];
            tstate.pending_pos += 1;
            return .{ .cp = cp, .end = tstate.pending_end };
        }

        fn finalizeQueue(tstate: *TState, scratch: []u21, scratch_end: []usize) void {
            canonicalSortWithEnds(
                scratch[0..tstate.segment_len],
                scratch_end[0..tstate.segment_len],
            );
            tstate.queue_len = tstate.segment_len;
        }
    };
}

fn nfkdStats(cp: u21) Stats {
    var buf: [18]u21 = undefined;
    const dc = decompose(cp, .nfkd, &buf);
    var same = [_]u21{cp};
    const cps = if (dc.form == .same) same[0..] else dc.cps;

    var stats = Stats{
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

fn decomposeHangul(cp: u21, buf: []u21) ?Decomp {
    const kind = HangulData.syllable(cp);
    if (kind != .LV and kind != .LVT) return null;

    const s_index: u21 = cp - SBase;
    const l_index: u21 = s_index / NCount;
    const v_index: u21 = (s_index % NCount) / TCount;
    const t_index: u21 = s_index % TCount;
    const l_part: u21 = LBase + l_index;
    const v_part: u21 = VBase + v_index;

    var dc = Decomp{ .form = .nfd };
    buf[0] = l_part;
    buf[1] = v_part;

    if (t_index == 0) {
        dc.cps = buf[0..2];
        return dc;
    }

    buf[2] = TBase + t_index;
    dc.cps = buf[0..3];
    return dc;
}

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
        else => @panic("CaselessMatch.mapping only accepts form .nfd or .nfkd."),
    }

    return dc;
}

fn decompose(cp: u21, form: Form, buf: []u21) Decomp {
    if (cp < 128) return .{};

    switch (form) {
        .nfd => if (NormPropsData.isNfd(cp)) return .{},
        .nfkd => if (NormPropsData.isNfkd(cp)) return .{},
        else => @panic("CaselessMatch.decompose only accepts form .nfd or .nfkd."),
    }

    if (decomposeHangul(cp, buf)) |dc| return dc;

    var dc = Decomp{ .form = form };
    var result_index: usize = 0;
    var work_index: usize = 1;
    var work = [_]u21{cp} ++ [_]u21{0} ** 17;

    while (work_index > 0) {
        work_index -= 1;
        const next = work[work_index];
        const m = mapping(next, form);

        if (m.form == .same) {
            buf[result_index] = next;
            result_index += 1;
            continue;
        }

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

fn canonicalSort(cps: []u21) void {
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const start = i;
        while (i < cps.len and CombiningData.ccc(cps[i]) != 0) : (i += 1) {}

        var j = start + 1;
        while (j < i) : (j += 1) {
            const cp = cps[j];
            const cc = CombiningData.ccc(cp);
            var k = j;
            while (k > start and CombiningData.ccc(cps[k - 1]) > cc) : (k -= 1) {
                cps[k] = cps[k - 1];
            }
            cps[k] = cp;
        }
    }
}

fn canonicalSortWithEnds(cps: []u21, ends: []usize) void {
    assert(cps.len == ends.len);

    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const start = i;
        while (i < cps.len and CombiningData.ccc(cps[i]) != 0) : (i += 1) {}

        var j = start + 1;
        while (j < i) : (j += 1) {
            const cp = cps[j];
            const end = ends[j];
            const cc = CombiningData.ccc(cp);
            var k = j;
            while (k > start and CombiningData.ccc(cps[k - 1]) > cc) : (k -= 1) {
                cps[k] = cps[k - 1];
                ends[k] = ends[k - 1];
            }
            cps[k] = cp;
            ends[k] = end;
        }
    }
}

pub const default_buffer_size = 64;

const Form = enum {
    nfd,
    nfkd,
    same,
};

const Decomp = struct {
    form: Form = .same,
    cps: []const u21 = &.{},
};

const Stats = struct {
    initial_nonstarters: usize = 0,
    trailing_nonstarters: usize = 0,
    total_len: usize = 0,
    has_starter: bool = false,
};

const stream_safe_limit: usize = 30;
const scratch_cap: usize = stream_safe_limit + 2;
const cgj: u21 = 0x034F; // Combining grapheme joiner

// Hangul algorithmic composition/decomposition constants from Unicode Normalization.
const SBase: u21 = 0xAC00;
const LBase: u21 = 0x1100;
const VBase: u21 = 0x1161;
const TBase: u21 = 0x11A7;
const LCount: u21 = 19;
const VCount: u21 = 21;
const TCount: u21 = 28;
const NCount: u21 = 588;
const SCount: u21 = 11172;

test "canonMatch" {
    try testing.expect(canonMatch("ascii only!", "ASCII Only!"));
    try testing.expect(canonMatch("Straße", "STRASSE"));

    const a = "prefix: Héllo World! \u{3d3}";
    const b = "PREFIX: He\u{301}llo World! \u{3a5}\u{301}";
    try testing.expect(!canonMatch(a, b));

    const c = "PREFIX: He\u{301}llo World! \u{3d2}\u{301}";
    try testing.expect(canonMatch(a, c));
}

test "compatMatch" {
    try testing.expect(compatMatch("ascii only!", "ASCII Only!"));

    const a = "prefix: Héllo World! \u{3d3}";
    const b = "PREFIX: He\u{301}llo World! \u{3a5}\u{301}";
    try testing.expect(compatMatch(a, b));

    const c = "PREFIX: He\u{301}llo World! \u{3d2}\u{301}";
    try testing.expect(compatMatch(a, c));
}

test "canonMatch stream-safe equivalence" {
    const repeated = "\u{0301}" ** 31;
    const stream_safe = ("\u{0301}" ** 30) ++ "\u{034F}\u{0301}";

    const a = "a" ++ repeated;
    const b = "a" ++ stream_safe;

    try testing.expect(canonMatch(a, b));
}

test "compatMatch stream-safe equivalence" {
    const repeated = "\u{0301}" ** 31;
    const stream_safe = ("\u{0301}" ** 30) ++ "\u{034F}\u{0301}";

    const a = "A" ++ repeated;
    const b = "a" ++ stream_safe;

    try testing.expect(compatMatch(a, b));
}

test "matcher stack init canon and compat" {
    var canon_matcher = CaselessMatcher(.canon).default;
    var compat_matcher = CaselessMatcher(.compat).default;

    try testing.expect(canon_matcher.match("Straße", "STRASSE"));
    try testing.expect(compat_matcher.match("prefix: Héllo World! \u{3d3}", "PREFIX: He\u{301}llo World! \u{3a5}\u{301}"));
}

test "matcher create destroy" {
    const allocator = testing.allocator;

    const matcher = try CaselessMatcher(.canon).create(allocator);
    defer matcher.destroy(allocator);

    try testing.expect(matcher.match("ascii only!", "ASCII Only!"));
}

test "matcher repeated match" {
    var matcher = CaselessMatcher(.canon).default;

    try testing.expect(matcher.match("ascii only!", "ASCII Only!"));
    try testing.expect(!matcher.match("Héllo World! \u{3d3}", "He\u{301}llo World! \u{3a5}\u{301}"));
    try testing.expect(matcher.match("Héllo World! \u{3d3}", "He\u{301}llo World! \u{3d2}\u{301}"));
}

test "matcher agrees with free functions" {
    const a = "A" ++ ("\u{0301}" ** 31);
    const b = "a" ++ (("\u{0301}" ** 30) ++ "\u{034F}\u{0301}");

    var canon_matcher = CaselessMatcher(.canon).default;
    var compat_matcher = CaselessMatcher(.compat).default;

    try testing.expectEqual(canonMatch(a, b), canon_matcher.match(a, b));
    try testing.expectEqual(compatMatch(a, b), compat_matcher.match(a, b));
}

test "nfcCaseFoldableQC spot checks" {
    try testing.expectEqual(.maybe, nfcCaseFoldableQC('\u{0345}'));
    try testing.expectEqual(.maybe, nfcCaseFoldableQC('\u{1FC3}'));
    try testing.expectEqual(.yes, nfcCaseFoldableQC('\u{00E9}'));
    try testing.expectEqual(.yes, nfcCaseFoldableQC('\u{00DF}'));
}

test "canon nfc hare matches direct-fold-safe strings" {
    switch (compareCanonNfcFast("Straße", "STRASSE")) {
        .matched => {},
        .fallback => return error.TestUnexpectedResult,
    }

    switch (compareCanonNfcFast("CAFÉ", "café")) {
        .matched => {},
        .fallback => return error.TestUnexpectedResult,
    }
}

test "canon nfc hare punts on ypogegrammeni family" {
    const result = compareCanonNfcFast("\u{1FC3}", "\u{1FC3}");
    switch (result) {
        .matched => return error.TestUnexpectedResult,
        .fallback => |rem| {
            try testing.expectEqualStrings("\u{1FC3}", rem.a);
            try testing.expectEqualStrings("\u{1FC3}", rem.b);
        },
    }
}

test "canon match ypogegrammeni family still succeeds" {
    try testing.expect(canonMatch("\u{1FC3}", "\u{0397}\u{0345}"));
}

test "searcher canon match" {
    var searcher = CaselessSearcher(32, .canon).default;

    const haystack = "Hello Héllo World! \u{3d3}";
    const got = try searcher.match(
        haystack,
        "he\u{301}LLO world! \u{3d2}\u{301}",
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("Héllo World! \u{3d3}", got);
}

test "searcher compat match" {
    var searcher = CaselessSearcher(32, .compat).default;

    const haystack = "hello Héllo World! \u{3d3}";
    const got = try searcher.match(
        haystack,
        "he\u{301}LLO world! \u{3a5}\u{301}",
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("Héllo World! \u{3d3}", got);
}

test "searcher no match" {
    var searcher = CaselessSearcher(32, .canon).default;
    try testing.expectEqual(@as(?[]const u8, null), try searcher.match("abc", "xyz"));
}

test "searcher empty needle" {
    var searcher = CaselessSearcher(0, .canon).default;

    const haystack = "abc";
    const got = try searcher.match(haystack, "") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", got);
}

test "searcher repeated calls" {
    var searcher = CaselessSearcher(32, .compat).default;

    const first = try searcher.match("Hello Straße", "STRASSE") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Straße", first);

    const second = try searcher.match(
        "prefix: Héllo World! \u{3d3}",
        "he\u{301}LLO world! \u{3a5}\u{301}",
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Héllo World! \u{3d3}", second);
}

test "searcher create destroy" {
    const allocator = testing.allocator;

    const searcher = try CaselessSearcher(32, .canon).create(allocator);
    defer searcher.destroy(allocator);

    const got = try searcher.match("xxStraßezz", "STRASSE") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Straße", got);
}

test "searcher needle too large" {
    var searcher = CaselessSearcher(4, .compat).default;
    try testing.expectError(error.NeedleTooLarge, searcher.match("xxStraßezz", "STRASSE"));
}

test "searcher matchAlloc fallback success" {
    const allocator = testing.allocator;
    var searcher = CaselessSearcher(4, .compat).default;

    const got = try searcher.matchAlloc(allocator, "xxStraßezz", "STRASSE") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Straße", got);
}

test "searcher matchAlloc fallback no match" {
    const allocator = testing.allocator;
    var searcher = CaselessSearcher(4, .compat).default;

    try testing.expectEqual(@as(?[]const u8, null), try searcher.matchAlloc(allocator, "abc", "STRASSE"));
}

test "searcher matchPos" {
    var searcher = CaselessSearcher(32, .compat).default;

    const haystack = "xx Straße yy Straße zz";
    const got = try searcher.matchPos(haystack, "STRASSE", 10) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Straße", got);
}

test "searcher matchPos no earlier match" {
    var searcher = CaselessSearcher(32, .compat).default;

    const haystack = "Straße xx Straße";
    const got = try searcher.matchPos(haystack, "STRASSE", 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Straße", got);
    try testing.expectEqual(@as(usize, 11), @intFromPtr(got.ptr) - @intFromPtr(haystack.ptr));
}

test "searcher matchPosAlloc fallback success" {
    const allocator = testing.allocator;
    var searcher = CaselessSearcher(4, .compat).default;

    const haystack = "xx Straße yy Straße zz";
    const got = try searcher.matchAllocPos(allocator, haystack, "STRASSE", 10) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Straße", got);
}

test "searcher matchPos out of bounds" {
    var searcher = CaselessSearcher(32, .canon).default;
    try testing.expectEqual(@as(?[]const u8, null), try searcher.matchPos("abc", "a", 4));
}

test "searcher canon stream-safe match" {
    var searcher = CaselessSearcher(64, .canon).default;

    const repeated = "\u{0301}" ** 31;
    const haystack = "zz a" ++ repeated ++ " yy";
    const needle = "a" ++ (("\u{0301}" ** 30) ++ "\u{034F}\u{0301}");

    const got = try searcher.match(haystack, needle) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a" ++ repeated, got);
}

test "searcher compat stream-safe match" {
    var searcher = CaselessSearcher(64, .compat).default;

    const repeated = "\u{0301}" ** 31;
    const haystack = "zz A" ++ repeated ++ " yy";
    const needle = "a" ++ (("\u{0301}" ** 30) ++ "\u{034F}\u{0301}");

    const got = try searcher.match(haystack, needle) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("A" ++ repeated, got);
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;

const ascii = @import("ascii");
const code_point = @import("code_point");
const CanonData = @import("CanonData");
const CaselessMatchData = @import("CaselessMatchData");
const CaseFolding = @import("CaseFolding");
const CombiningData = @import("CombiningData");
const CompatData = @import("CompatData");
const HangulData = @import("HangulData");
const NormQuickCheckData = @import("NormQuickCheckData");
const NormPropsData = @import("NormPropsData");
