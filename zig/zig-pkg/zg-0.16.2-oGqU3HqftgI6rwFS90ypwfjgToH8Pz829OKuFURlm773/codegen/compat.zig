const std = @import("std");
const builtin = @import("builtin");

const block_size = 256;
const Block = [block_size][]const u21;

const BlockMap = std.HashMap(
    Block,
    u16,
    struct {
        pub fn hash(_: @This(), k: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: @This(), aBlock: Block, bBlock: Block) bool {
            return for (aBlock, bBlock) |a, b| {
                if (a.len != b.len) return false;
                for (a, b) |a_cp, b_cp| {
                    if (a_cp != b_cp) return false;
                }
            } else true;
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main(init: std.process.Init) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Process UnicodeData.txt
    var in_reader = std.Io.Reader.fixed(@embedFile("UnicodeData.txt"));
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    var compat_map = std.AutoHashMap(u21, []u21).init(allocator);
    defer compat_map.deinit();

    while (in_reader.takeDelimiterInclusive('\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var cp: u21 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            if (field.len == 0) continue;

            switch (i) {
                0 => {
                    cp = try std.fmt.parseInt(u21, field, 16);
                },

                5 => {
                    // Not compatibility.
                    if (field[0] != '<') continue;

                    var cp_iter = std.mem.tokenizeScalar(u8, field, ' ');
                    _ = cp_iter.next(); // <compat type>

                    var cps: [18]u21 = undefined;
                    var len: u8 = 0;

                    while (cp_iter.next()) |cp_str| : (len += 1) {
                        cps[len] = try std.fmt.parseInt(u21, cp_str, 16);
                    }

                    const slice = try allocator.dupe(u21, cps[0..len]);
                    try compat_map.put(cp, slice);
                },

                else => {},
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            return err;
        },
    }

    // Build multi-tiered lookup tables for compatibility decompositions
    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.array_list.Managed(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.array_list.Managed([]const u21).init(allocator);
    defer stage2.deinit();

    var block: Block = [_][]const u21{&[_]u21{}} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const compat: []const u21 = compat_map.get(cp) orelse &[_]u21{};

        block[block_len] = compat;
        block_len += 1;

        if (block_len < block_size and cp != 0x10ffff) continue;

        const gop = try blocks_map.getOrPut(block);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(stage2.items.len);
            try stage2.appendSlice(&block);
        }

        try stage1.append(gop.value_ptr.*);
        block_len = 0;
    }
    // Write out
    var write_buf: [4096]u8 = undefined;
    var out_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer out_file.close(init.io);
    var writer = out_file.writer(init.io, &write_buf);

    try writer.interface.print(
        \\//! This file is auto-generated. Do not edit.
        \\
        \\pub const s1: [{}]u16 = .{{
    , .{stage1.items.len});
    for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

    try writer.interface.print(
        \\
        \\}};
        \\
        \\pub const s2: [{}][]const u21 = .{{
    , .{stage2.items.len});
    for (stage2.items) |entry| {
        try writer.interface.print("&.{any}, ", .{entry});
    }

    try writer.interface.writeAll(
        \\};
    );

    try writer.interface.flush();
}
