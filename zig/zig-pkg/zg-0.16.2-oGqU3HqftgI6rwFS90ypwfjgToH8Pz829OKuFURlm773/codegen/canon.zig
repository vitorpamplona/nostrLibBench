const std = @import("std");
const builtin = @import("builtin");

const block_size = 256;
const Block = [block_size]Canonicalization;

const Canonicalization = struct {
    len: u3 = 0,
    cps: [2]u21 = [_]u21{0} ** 2,
};

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
                if (a.len != b.len or a.cps[0] != b.cps[0] or a.cps[1] != b.cps[1]) return false;
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

    var canon_map = std.AutoHashMap(u21, Canonicalization).init(allocator);
    defer canon_map.deinit();

    var composite_set: std.array_hash_map.Auto(u21, [2]u21) = .empty;

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
                    // Not canonical.
                    if (field[0] == '<') continue;

                    if (std.mem.indexOfScalar(u8, field, ' ')) |space| {
                        // Canonical
                        const c0, const c1 = .{
                            try std.fmt.parseInt(u21, field[0..space], 16),
                            try std.fmt.parseInt(u21, field[space + 1 ..], 16),
                        };
                        try canon_map.put(cp, Canonicalization{
                            .len = 2,
                            .cps = [_]u21{ c0, c1 },
                        });
                        try composite_set.put(allocator, cp, [_]u21{ c0, c1 });
                    } else {
                        // Singleton
                        try canon_map.put(cp, Canonicalization{
                            .len = 1,
                            .cps = [_]u21{
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
        else => {
            return err;
        },
    }

    // Build multi-tiered lookup tables for decompositions
    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.array_list.Managed(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.array_list.Managed(Canonicalization).init(allocator);
    defer stage2.deinit();

    var block: Block = [_]Canonicalization{.{}} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);

        const canon: Canonicalization = canon_map.get(cp) orelse .{};

        block[block_len] = canon;
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
        \\pub const Canonicalization = struct {{
        \\    len: u3,
        \\    cps: [2]u21,
        \\}};
        \\
        \\pub const s1: [{}]u16 = .{{
    , .{stage1.items.len});
    for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

    try writer.interface.print(
        \\
        \\}};
        \\
        \\pub const s2: [{}]Canonicalization = .{{
    , .{stage2.items.len});
    for (stage2.items) |entry| {
        try writer.interface.print(".{{ .len = {}, .cps = .{{ {}, {} }} }}, ", .{
            entry.len,
            entry.cps[0],
            entry.cps[1],
        });
    }

    const composite = composite_set.keys();
    // TODO: cut
    try writer.interface.print(
        \\
        \\}};
        \\
        \\pub const composite: [{}]u21 = .{{
    , .{composite.len});
    for (composite) |entry| try writer.interface.print("{}, ", .{entry});

    try writer.interface.writeAll(
        \\};
    );

    try writer.interface.print(
        \\
        \\ pub const c_map: [{}]struct {{ [2]u21, u21 }} = .{{
    , .{composite.len});
    for (composite) |comp| {
        const canon = canon_map.get(comp).?;
        std.debug.assert(canon.len == 2);
        try writer.interface.print(
            \\ .{{ .{{{}, {}}}, {}}},
        ,
            .{ canon.cps[0], canon.cps[1], comp },
        );
    }
    // var c_entries = composite_set.iterator();
    // while (c_entries.next()) |entry| {
    //     try writer.interface.print(
    //         \\ .{{ .{{{}, {}}}, {}}},
    //     ,
    //         .{ entry.value_ptr[0], entry.value_ptr[1], entry.key_ptr.* },
    //     );
    // }
    try writer.interface.writeAll(
        \\};
    );

    try writer.interface.flush();
}
