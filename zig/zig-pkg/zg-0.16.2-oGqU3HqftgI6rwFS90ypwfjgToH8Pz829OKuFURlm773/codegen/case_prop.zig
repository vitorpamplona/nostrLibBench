const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

const block_size = 256;
const Block = [block_size]u8;

const BlockMap = std.HashMap(
    Block,
    u16,
    struct {
        pub fn hash(_: @This(), k: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Block, b: Block) bool {
            return mem.eql(u8, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main(init: std.process.Init) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var flat_map = std.AutoHashMap(u21, u8).init(allocator);
    defer flat_map.deinit();

    // Process DerivedCoreProperties.txt
    var in_reader = std.Io.Reader.fixed(@embedFile("DerivedCoreProperties.txt"));
    while (in_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;
        const no_comment = if (mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = mem.tokenizeAny(u8, no_comment, "; ");
        var current_code: [2]u21 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (mem.indexOf(u8, field, "..")) |dots| {
                        current_code = .{
                            try std.fmt.parseInt(u21, field[0..dots], 16),
                            try std.fmt.parseInt(u21, field[dots + 2 ..], 16),
                        };
                    } else {
                        const code = try std.fmt.parseInt(u21, field, 16);
                        current_code = .{ code, code };
                    }
                },
                1 => {
                    // Props
                    var bit: u8 = 0;

                    if (mem.eql(u8, field, "Lowercase")) bit = 1;
                    if (mem.eql(u8, field, "Uppercase")) bit = 2;
                    if (mem.eql(u8, field, "Cased")) bit = 4;

                    if (bit != 0) {
                        for (current_code[0]..current_code[1] + 1) |cp| {
                            const gop = try flat_map.getOrPut(@intCast(cp));
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            gop.value_ptr.* |= bit;
                        }
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

    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.array_list.Managed(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.array_list.Managed(u8).init(allocator);
    defer stage2.deinit();

    var block: Block = [_]u8{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const prop = flat_map.get(cp) orelse 0;

        // Process block
        block[block_len] = prop;
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

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    var write_buf: [4096]u8 = undefined;
    var out_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer out_file.close(init.io);
    var writer = out_file.writer(init.io, &write_buf);

    const endian = builtin.cpu.arch.endian();
    try writer.interface.writeInt(u16, @intCast(stage1.items.len), endian);
    for (stage1.items) |i| try writer.interface.writeInt(u16, i, endian);

    try writer.interface.writeInt(u16, @intCast(stage2.items.len), endian);
    try writer.interface.writeAll(stage2.items);

    try writer.interface.flush();
}
