const std = @import("std");
const builtin = @import("builtin");

pub const Emoji = packed struct {
    Emoji: bool = false,
    Emoji_Presentation: bool = false,
    Emoji_Modifier: bool = false,
    Emoji_Modifier_Base: bool = false,
    Emoji_Component: bool = false,
    Extended_Pictographic: bool = false,
};

const block_size = 256;
const Block = [block_size]u6;

comptime {
    if (@bitSizeOf(u6) != @bitSizeOf(Emoji)) {
        @compileError("Emoji doesn't have expected bit size.");
    }
}

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
            return std.mem.eql(u6, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emoji_map = std.AutoHashMap(u21, Emoji).init(allocator);
    defer emoji_map.deinit();

    // Process Emoji

    var @"emo-reader" = std.Io.Reader.fixed(@embedFile("emoji-data.txt"));
    var count: usize = 0; // XXX: remove
    while (@"emo-reader".takeDelimiterInclusive('\n')) |line| {
        count += 1;
        if (line.len <= 1 or line[0] == '#') continue;
        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");
        var current_code: [2]u21 = undefined;
        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
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
                    // Prop
                    const prop = std.meta.stringToEnum(std.meta.FieldEnum(Emoji), field) orelse return error.InvalidProp;
                    for (current_code[0]..current_code[1] + 1) |code| {
                        const cp: u21 = @intCast(code);
                        const gop = try emoji_map.getOrPut(cp);
                        if (!gop.found_existing) gop.value_ptr.* = .{};
                        switch (prop) {
                            inline else => |tag| {
                                @field(gop.value_ptr.*, @tagName(tag)) = true;
                            },
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

    var stage2 = std.array_list.Managed(u6).init(allocator);
    defer stage2.deinit();

    var block: Block = [_]u6{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const emoji = emoji_map.get(cp) orelse Emoji{};

        block[block_len] = @bitCast(emoji);
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
        \\pub const s2: [{}]u6 = .{{
    , .{stage2.items.len});
    for (stage2.items) |entry| {
        try writer.interface.print("{}, ", .{entry});
    }

    try writer.interface.writeAll(
        \\};
    );

    try writer.interface.flush();
}
