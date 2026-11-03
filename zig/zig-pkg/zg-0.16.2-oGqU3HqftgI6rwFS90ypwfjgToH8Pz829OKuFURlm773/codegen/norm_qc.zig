const std = @import("std");
const builtin = @import("builtin");

const block_size = 256;
const Block = [block_size]u2;

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
            return std.mem.eql(u2, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub const NormKind = enum {
    nfc,
    nfd,
    nfkc,
    nfkd,

    none,
};

pub fn main(init: std.process.Init) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_nfc = std.AutoHashMap(u21, u2).init(allocator);
    defer map_nfc.deinit();
    var map_nfd = std.AutoHashMap(u21, u2).init(allocator);
    defer map_nfd.deinit();
    var map_nfkc = std.AutoHashMap(u21, u2).init(allocator);
    defer map_nfkc.deinit();
    var map_nfkd = std.AutoHashMap(u21, u2).init(allocator);
    defer map_nfkd.deinit();

    var nf_kind: NormKind = .none;

    // Process DerivedNormalizationProps.txt
    var in_reader = std.Io.Reader.fixed(@embedFile("DerivedNormalizationProps.txt"));
    lines: while (in_reader.takeDelimiterInclusive('\n')) |took| {
        const line = std.mem.trimEnd(u8, took, "\n");
        if (line.len == 0 or line[0] == '#') continue;

        // Skip non-quickcheck fields
        _ = std.mem.indexOf(u8, line, "_QC") orelse continue;
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
                    // Which norm check
                    if (std.mem.eql(u8, field, "NFC_QC")) {
                        nf_kind = .nfc;
                    } else if (std.mem.eql(u8, field, "NFD_QC")) {
                        nf_kind = .nfd;
                    } else if (std.mem.eql(u8, field, "NFKC_QC")) {
                        nf_kind = .nfkc;
                    } else if (std.mem.eql(u8, field, "NFKD_QC")) {
                        nf_kind = .nfkd;
                    } else { // Spurious _QC? Possible
                        continue :lines;
                    }
                },
                2 => {
                    // Norm props
                    const n_prop: u2 = prop: {
                        if (field[0] == 'N') {
                            break :prop 1;
                        } else {
                            std.debug.assert(field[0] == 'M');
                            break :prop 2;
                        }
                    };
                    for (current_code[0]..current_code[1] + 1) |cp| {
                        switch (nf_kind) {
                            .nfc => {
                                try map_nfc.putNoClobber(@intCast(cp), n_prop);
                            },
                            .nfd => {
                                try map_nfd.putNoClobber(@intCast(cp), n_prop);
                            },
                            .nfkc => {
                                try map_nfkc.putNoClobber(@intCast(cp), n_prop);
                            },
                            .nfkd => {
                                try map_nfkd.putNoClobber(@intCast(cp), n_prop);
                            },
                            .none => unreachable,
                        }
                    }
                    continue :lines;
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

    // Implementation note: the nature of these sets is that they have
    // relatively little overlap, and in use, tend to be consulted separately,
    // not together.  So, while the data could be packed into one `u8`, we don't
    // do this.  The overlap question dominates not combining -C and -D forms,
    // and the separate use question dominates not combining canonicals with
    // their compatibility cousins.

    // Set up the writer first, makes life a little easier
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    var write_buf: [4096]u8 = undefined;
    var out_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer out_file.close(init.io);
    var writer = out_file.writer(init.io, &write_buf);
    { // NFC_QC
        var blocks_map = BlockMap.init(allocator);
        defer blocks_map.deinit();

        var stage1 = std.array_list.Managed(u16).init(allocator);
        defer stage1.deinit();

        var stage2 = std.array_list.Managed(u2).init(allocator);
        defer stage2.deinit();

        var block: Block = [_]u2{0} ** block_size;
        var block_len: u16 = 0;

        for (0..0x110000) |i| {
            const cp: u21 = @intCast(i);
            const props = map_nfc.get(cp) orelse 0;

            // Process block
            block[block_len] = props;
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

        try writer.interface.print(
            \\//! This file is auto-generated. Do not edit.
            \\
            \\pub const nfc1: [{}]u16 = .{{
        , .{stage1.items.len});
        for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.print(
            \\
            \\}};
            \\
            \\pub const nfc2: [{}]u2 = .{{
        , .{stage2.items.len});
        for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.writeAll(
            \\};
        );
    }

    { // NFD_QC
        var blocks_map = BlockMap.init(allocator);
        defer blocks_map.deinit();

        var stage1 = std.array_list.Managed(u16).init(allocator);
        defer stage1.deinit();

        var stage2 = std.array_list.Managed(u2).init(allocator);
        defer stage2.deinit();

        var block: Block = [_]u2{0} ** block_size;
        var block_len: u16 = 0;

        for (0..0x110000) |i| {
            const cp: u21 = @intCast(i);
            const props = map_nfd.get(cp) orelse 0;

            // Process block
            block[block_len] = props;
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

        try writer.interface.print(
            \\
            \\pub const nfd1: [{}]u16 = .{{
        , .{stage1.items.len});
        for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.print(
            \\
            \\}};
            \\
            \\pub const nfd2: [{}]u2 = .{{
        , .{stage2.items.len});
        for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.writeAll(
            \\};
        );
    }

    { // NFKC_QC
        var blocks_map = BlockMap.init(allocator);
        defer blocks_map.deinit();

        var stage1 = std.array_list.Managed(u16).init(allocator);
        defer stage1.deinit();

        var stage2 = std.array_list.Managed(u2).init(allocator);
        defer stage2.deinit();

        var block: Block = [_]u2{0} ** block_size;
        var block_len: u16 = 0;

        for (0..0x110000) |i| {
            const cp: u21 = @intCast(i);
            const props = map_nfkc.get(cp) orelse 0;

            // Process block
            block[block_len] = props;
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

        try writer.interface.print(
            \\
            \\pub const nfkc1: [{}]u16 = .{{
        , .{stage1.items.len});
        for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.print(
            \\
            \\}};
            \\
            \\pub const nfkc2: [{}]u2 = .{{
        , .{stage2.items.len});
        for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.writeAll(
            \\};
        );
    }

    { // NFKD_QC
        var blocks_map = BlockMap.init(allocator);
        defer blocks_map.deinit();

        var stage1 = std.array_list.Managed(u16).init(allocator);
        defer stage1.deinit();

        var stage2 = std.array_list.Managed(u2).init(allocator);
        defer stage2.deinit();

        var block: Block = [_]u2{0} ** block_size;
        var block_len: u16 = 0;

        for (0..0x110000) |i| {
            const cp: u21 = @intCast(i);
            const props = map_nfkd.get(cp) orelse 0;

            // Process block
            block[block_len] = props;
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

        try writer.interface.print(
            \\
            \\pub const nfkd1: [{}]u16 = .{{
        , .{stage1.items.len});
        for (stage1.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.print(
            \\
            \\}};
            \\
            \\pub const nfkd2: [{}]u2 = .{{
        , .{stage2.items.len});
        for (stage2.items) |entry| try writer.interface.print("{}, ", .{entry});

        try writer.interface.writeAll(
            \\};
        );
    }

    try writer.interface.flush();
}
