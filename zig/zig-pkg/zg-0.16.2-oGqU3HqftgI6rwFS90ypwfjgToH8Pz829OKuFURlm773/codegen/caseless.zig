const std = @import("std");

const block_size = 256;
const Block = [block_size]u1;

const BlockMap = std.HashMap(
    Block,
    u16,
    struct {
        pub fn hash(_: @This(), block: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, block, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Block, b: Block) bool {
            return std.mem.eql(u1, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

const Canonicalization = struct {
    len: u2 = 0,
    cps: [2]u21 = [_]u21{0} ** 2,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    var canon_map = std.AutoHashMap(u21, Canonicalization).init(allocator);
    defer canon_map.deinit();

    var in_reader = std.Io.Reader.fixed(@embedFile("UnicodeData.txt"));
    while (in_reader.takeDelimiterInclusive('\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var cp: u21 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            if (field.len == 0) continue;

            switch (i) {
                0 => cp = try std.fmt.parseInt(u21, field, 16),
                5 => {
                    if (field[0] == '<') continue;

                    if (std.mem.indexOfScalar(u8, field, ' ')) |space| {
                        try canon_map.put(cp, .{
                            .len = 2,
                            .cps = .{
                                try std.fmt.parseInt(u21, field[0..space], 16),
                                try std.fmt.parseInt(u21, field[space + 1 ..], 16),
                            },
                        });
                    } else {
                        try canon_map.put(cp, .{
                            .len = 1,
                            .cps = .{
                                try std.fmt.parseInt(u21, field, 16),
                                0,
                            },
                        });
                    }
                },
                else => {},
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    var memo = std.AutoHashMap(u21, bool).init(allocator);
    defer memo.deinit();

    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.array_list.Managed(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.array_list.Managed(u1).init(allocator);
    defer stage2.deinit();

    var block: Block = [_]u1{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        block[block_len] = @intFromBool(contains0345(cp, &canon_map, &memo));
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
        \\pub const s2: [{}]u1 = .{{
    , .{stage2.items.len});
    for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});
    try writer.interface.writeAll(
        \\
        \\};
    );

    try writer.interface.flush();
}

fn contains0345(
    cp: u21,
    canon_map: *const std.AutoHashMap(u21, Canonicalization),
    memo: *std.AutoHashMap(u21, bool),
) bool {
    if (memo.get(cp)) |cached| return cached;

    const result = blk: {
        if (cp == 0x0345) break :blk true;
        const canon = canon_map.get(cp) orelse break :blk false;

        var i: usize = 0;
        while (i < canon.len) : (i += 1) {
            if (contains0345(canon.cps[i], canon_map, memo)) break :blk true;
        }

        break :blk false;
    };

    memo.put(cp, result) catch unreachable;
    return result;
}
