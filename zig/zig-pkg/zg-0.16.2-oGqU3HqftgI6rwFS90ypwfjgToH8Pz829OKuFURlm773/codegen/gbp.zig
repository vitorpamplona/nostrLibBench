const std = @import("std");
const builtin = @import("builtin");

const Indic = enum {
    none,

    Consonant,
    Extend,
    Linker,
};

const Gbp = enum {
    none,

    Control,
    CR,
    Extend,
    L,
    LF,
    LV,
    LVT,
    Prepend,
    Regional_Indicator,
    SpacingMark,
    T,
    V,
    ZWJ,
};

const block_size = 256;
const Block = [block_size]u16;

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
            return std.mem.eql(u16, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main(init: std.process.Init) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var indic_map = std.AutoHashMap(u21, Indic).init(allocator);
    defer indic_map.deinit();

    var gbp_map = std.AutoHashMap(u21, Gbp).init(allocator);
    defer gbp_map.deinit();

    var emoji_set = std.AutoHashMap(u21, void).init(allocator);
    defer emoji_set.deinit();

    // Process Indic
    const indic_file = @embedFile("DerivedCoreProperties.txt");
    var indic_reader = std.Io.Reader.fixed(indic_file);

    while (indic_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "InCB") == null) continue;
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
                2 => {
                    // Prop
                    const prop = std.meta.stringToEnum(Indic, field) orelse return error.InvalidPorp;
                    for (current_code[0]..current_code[1] + 1) |cp| try indic_map.put(@intCast(cp), prop);
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
    // Process GBP

    var gbp_reader = std.Io.Reader.fixed(@embedFile("GraphemeBreakProperty.txt"));

    while (gbp_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;
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
                    const prop = std.meta.stringToEnum(Gbp, field) orelse return error.InvalidPorp;
                    for (current_code[0]..current_code[1] + 1) |cp| try gbp_map.put(@intCast(cp), prop);
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
    // Process Emoji

    var emoji_reader = std.Io.Reader.fixed(@embedFile("emoji-data.txt"));

    while (emoji_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "Extended_Pictographic") == null) continue;
        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
                        const from = try std.fmt.parseInt(u21, field[0..dots], 16);
                        const to = try std.fmt.parseInt(u21, field[dots + 2 ..], 16);
                        for (from..to + 1) |cp| try emoji_set.put(@intCast(cp), {});
                    } else {
                        const cp = try std.fmt.parseInt(u21, field, 16);
                        try emoji_set.put(@intCast(cp), {});
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

    var stage2 = std.array_list.Managed(u16).init(allocator);
    defer stage2.deinit();

    var stage3: std.array_hash_map.Auto(u8, u16) = .empty;
    defer stage3.deinit(allocator);
    var stage3_len: u16 = 0;

    var block: Block = [_]u16{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const gbp_prop: u8 = @intFromEnum(gbp_map.get(cp) orelse .none);
        const indic_prop: u8 = @intFromEnum(indic_map.get(cp) orelse .none);
        const emoji_prop: u1 = @intFromBool(emoji_set.contains(cp));
        var props_byte: u8 = gbp_prop << 4;
        props_byte |= indic_prop << 1;
        props_byte |= emoji_prop;

        const stage3_idx = blk: {
            const gop = try stage3.getOrPut(allocator, props_byte);
            if (!gop.found_existing) {
                gop.value_ptr.* = stage3_len;
                stage3_len += 1;
            }

            break :blk gop.value_ptr.*;
        };

        block[block_len] = stage3_idx;
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
        \\pub const s2: [{}]u7 = .{{
    , .{stage2.items.len});
    for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});

    const keys = stage3.keys();

    try writer.interface.print(
        \\}};
        \\
        \\pub const s3: [{}]u8 = .{{
    , .{keys.len});
    for (keys) |entry| try writer.interface.print("{}, ", .{entry});
    try writer.interface.writeAll(
        \\};
    );

    try writer.interface.flush();
}
