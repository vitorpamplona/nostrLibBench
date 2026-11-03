//! A copypasta of Vexu's comptime hashmap:
//!
//! https://github.com/Vexu/comptime_hash_map
//!
//! (License at base of file, thanks Vexu!)
//!

/// A comptime hashmap constructed with automatically selected hash and eql functions.
pub fn AutoComptimeHashMap(comptime K: type, comptime V: type, comptime values: anytype) type {
    return ComptimeHashMap(K, V, StableAutoContext(K), values);
}

/// Builtin hashmap for strings as keys.
pub fn ComptimeStringHashMap(comptime V: type, comptime values: anytype) type {
    return ComptimeHashMap([]const u8, V, hash_map.StringContext, values);
}

/// A hashmap which is constructed at compile time from constant values.
/// Intended to be used as a faster lookup table.
pub fn ComptimeHashMap(comptime K: type, comptime V: type, comptime ctx: type, comptime values: anytype) type {
    std.debug.assert(values.len != 0);
    @setEvalBranchQuota(1000 * values.len);

    const Entry = struct {
        key: K = undefined,
        val: V = undefined,
        used: bool = false,
    };

    // ensure that the hash map will be at most 60% full
    const size = math.ceilPowerOfTwo(usize, values.len * 5 / 3) catch unreachable;
    comptime var slots = [1]Entry{.{}} ** size;
    comptime var distance: [size]usize = .{0} ** size;

    comptime var max_distance_from_start_index = 0;

    slot_loop: for (values) |kv| {
        var key: K = kv.@"0";
        var value: V = kv.@"1";

        const start_index = reduceMulHi(ctx.hash(undefined, key), size);

        var roll_over = 0;
        var distance_from_start_index = 0;
        while (roll_over < size) : ({
            roll_over += 1;
            distance_from_start_index += 1;
        }) {
            const index = (start_index + roll_over) & (size - 1);
            const entry = &slots[index];

            if (entry.used and !ctx.eql(undefined, entry.key, key)) {
                if (distance[index] < distance_from_start_index) {
                    // robin hood to the rescue
                    const tmp = slots[index];
                    max_distance_from_start_index = @max(max_distance_from_start_index, distance_from_start_index);
                    entry.* = .{
                        .used = true,
                        .key = key,
                        .val = value,
                    };
                    const tmp_distance = distance[index];
                    distance[index] = distance_from_start_index;
                    key = tmp.key;
                    value = tmp.val;
                    distance_from_start_index = tmp_distance;
                }
                continue;
            }

            max_distance_from_start_index = @max(distance_from_start_index, max_distance_from_start_index);
            entry.* = .{
                .used = true,
                .key = key,
                .val = value,
            };
            distance[index] = distance_from_start_index;
            continue :slot_loop;
        }
        unreachable; // put into a full map
    }

    return struct {
        const entries = slots;

        pub fn has(key: K) bool {
            return get(key) != null;
        }

        pub fn get(key: K) ?*const V {
            const start_index = reduceMulHi(ctx.hash(undefined, key), size);
            {
                var roll_over: usize = 0;
                while (roll_over <= max_distance_from_start_index) : (roll_over += 1) {
                    const index = (start_index + roll_over) & (size - 1);
                    const entry = &entries[index];

                    if (!entry.used) return null;
                    if (ctx.eql(undefined, entry.key, key)) return &entry.val;
                }
            }
            return null;
        }
    };
}

fn reduceMulHi(h: u64, m: u64) u64 {
    // floor((h * m) / 2^64)
    return @as(u64, @truncate((@as(u128, h) * @as(u128, m)) >> 64));
}

fn StableAutoContext(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), key: K) u64 {
            var hasher = std.hash.Wyhash.init(0);
            stableAutoHash(&hasher, key);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return std.meta.eql(a, b);
        }
    };
}

fn stableAutoHash(hasher: anytype, key: anytype) void {
    const Key = @TypeOf(key);

    switch (@typeInfo(Key)) {
        .int => |int| {
            const Unsigned = @Int(.unsigned, int.bits);
            const unsigned: Unsigned = if (int.signedness == .signed) @bitCast(key) else key;
            hashUnsigned(hasher, unsigned);
        },
        .bool => hashUnsigned(hasher, @intFromBool(key)),
        .@"enum" => hashUnsigned(hasher, @intFromEnum(key)),
        .array => for (key) |item| stableAutoHash(hasher, item),
        .@"struct" => |info| inline for (info.fields) |field| {
            stableAutoHash(hasher, @field(key, field.name));
        },
        else => std.hash.autoHash(hasher, key),
    }
}

fn hashUnsigned(hasher: anytype, value: anytype) void {
    const bits = @bitSizeOf(@TypeOf(value));
    const byte_len = comptime std.math.divCeil(comptime_int, bits, 8) catch unreachable;
    const wide: u64 = value;

    inline for (0..byte_len) |i| {
        const byte: u8 = @truncate(wide >> @intCast(i * 8));
        hasher.update(&.{byte});
    }
}

test "basic usage" {
    const map = ComptimeStringHashMap(usize, .{
        .{ "foo", 1 },
        .{ "bar", 2 },
        .{ "baz", 3 },
        .{ "quux", 4 },
        .{ "Foo", 1 },
        .{ "Bar", 2 },
        .{ "Baz", 3 },
        .{ "Quux", 4 },
    });

    try testing.expect(map.has("foo"));
    try testing.expect(map.has("bar"));
    try testing.expect(map.has("Foo"));
    try testing.expect(map.has("Bar"));
    try testing.expect(!map.has("zig"));
    try testing.expect(!map.has("ziguana"));

    try testing.expect(map.get("baz").?.* == 3);
    try testing.expect(map.get("quux").?.* == 4);
    try testing.expect(map.get("nah") == null);
    try testing.expect(map.get("...") == null);
}

test "auto comptime hash map" {
    const map = AutoComptimeHashMap(usize, []const u8, .{
        .{ 1, "foo" },
        .{ 2, "bar" },
        .{ 3, "baz" },
        .{ 45, "quux" },
    });

    try testing.expect(map.has(1));
    try testing.expect(map.has(2));
    try testing.expect(!map.has(4));
    try testing.expect(!map.has(1_000_000));

    try testing.expectEqualStrings("foo", map.get(1).?.*);
    try testing.expectEqualStrings("bar", map.get(2).?.*);
    try testing.expect(map.get(4) == null);
    try testing.expect(map.get(4_000_000) == null);
}

test "array pair comptime hash map" {
    const map = AutoComptimeHashMap([2]u32, u21, .{
        .{ .{ 2, 3 }, 5 },
        .{ .{ 42, 56 }, 12 },
        .{ .{ 2, 4 }, 6 },
    });
    try testing.expect(map.has(.{ 2, 4 }));
}

test "non-byte-aligned integer array keys" {
    const map = AutoComptimeHashMap([2]u21, u21, .{
        .{ .{ 2, 3 }, 5 },
        .{ .{ 42, 56 }, 12 },
        .{ .{ 2, 4 }, 6 },
    });
    try testing.expect(map.has(.{ 2, 3 }));
    try testing.expect(!map.has(.{ 23, 42 }));
}

const std = @import("std");
const hash_map = std.hash_map;
const testing = std.testing;
const math = std.math;

// MIT License
//
// Copyright (c) 2020 Veikka Tuominen
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
