const std = @import("std");
const mem = std.mem;

const block_size = 256;
const max_mapping_len = 3;

const SimpleMapping = packed struct(u64) {
    lower: u21 = 0,
    title: u21 = 0,
    upper: u21 = 0,
    _: u1 = 0,
};

const MultiMapping = packed struct(u16) {
    len: u2 = 0,
    index: u14 = 0,
};

const FullTable = struct {
    cutoff: u21,
    s4_start: u16,
    stage1: []const u16,
    stage2: []const u16,
    stage3: []const u21,
    stage4: []const MultiMapping,
    multis: []const u21,
};

const BlockContext = struct {
    pub fn of(comptime T: type) type {
        return struct {
            pub fn hash(_: @This(), k: [block_size]T) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
                return hasher.final();
            }

            pub fn eql(_: @This(), a: [block_size]T, b: [block_size]T) bool {
                return mem.eql(T, &a, &b);
            }
        };
    }
};

fn BlockMap(comptime T: type) type {
    return std.HashMap(
        [block_size]T,
        u16,
        BlockContext.of(T),
        std.hash_map.default_max_load_percentage,
    );
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var simple_lower = std.AutoHashMap(u21, u21).init(allocator);
    var simple_title = std.AutoHashMap(u21, u21).init(allocator);
    var simple_upper = std.AutoHashMap(u21, u21).init(allocator);
    var props = std.AutoHashMap(u21, u8).init(allocator);
    var full_lower: std.array_hash_map.Auto(u21, [max_mapping_len]u21) = .empty;
    var full_title: std.array_hash_map.Auto(u21, [max_mapping_len]u21) = .empty;
    var full_upper: std.array_hash_map.Auto(u21, [max_mapping_len]u21) = .empty;

    {
        var in_reader = std.Io.Reader.fixed(@embedFile("UnicodeData.txt"));

        while (in_reader.takeDelimiterInclusive('\n')) |line_with_newline| {
            const line = mem.trimEnd(u8, line_with_newline, "\n");
            if (line.len == 0) continue;

            var fields: [15][]const u8 = [_][]const u8{""} ** 15;
            var field_iter = mem.splitScalar(u8, line, ';');
            var i: usize = 0;
            while (i < fields.len) : (i += 1) fields[i] = field_iter.next() orelse "";

            const cp = try std.fmt.parseInt(u21, fields[0], 16);

            if (mem.eql(u8, fields[2], "Lt")) {
                const gop = try props.getOrPut(cp);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* |= 16;
            }

            if (fields[12].len != 0) {
                const upper = try std.fmt.parseInt(u21, fields[12], 16);
                try simple_upper.put(cp, upper);

                var mapping = [_]u21{0} ** max_mapping_len;
                mapping[0] = upper;
                try full_upper.put(allocator, cp, mapping);
            }

            if (fields[13].len != 0) {
                const lower = try std.fmt.parseInt(u21, fields[13], 16);
                try simple_lower.put(cp, lower);

                var mapping = [_]u21{0} ** max_mapping_len;
                mapping[0] = lower;
                try full_lower.put(allocator, cp, mapping);
            }

            if (fields[14].len != 0) {
                const title = try std.fmt.parseInt(u21, fields[14], 16);
                if (title != cp) {
                    try simple_title.put(cp, title);

                    var mapping = [_]u21{0} ** max_mapping_len;
                    mapping[0] = title;
                    try full_title.put(allocator, cp, mapping);
                }
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    {
        var in_reader = std.Io.Reader.fixed(@embedFile("DerivedCoreProperties.txt"));

        while (in_reader.takeDelimiterInclusive('\n')) |took| {
            const line = mem.trimEnd(u8, took, "\n");
            if (line.len == 0 or line[0] == '#') continue;
            const no_comment = if (mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

            var field_iter = mem.tokenizeAny(u8, no_comment, "; ");
            var current_code: [2]u21 = undefined;

            var i: usize = 0;
            while (field_iter.next()) |field| : (i += 1) {
                switch (i) {
                    0 => {
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
                        var bit: u8 = 0;
                        if (mem.eql(u8, field, "Lowercase")) bit = 1;
                        if (mem.eql(u8, field, "Uppercase")) bit = 2;
                        if (mem.eql(u8, field, "Cased")) bit = 4;
                        if (mem.eql(u8, field, "Case_Ignorable")) bit = 8;
                        if (bit == 0) continue;

                        for (current_code[0]..current_code[1] + 1) |cp_int| {
                            const cp: u21 = @intCast(cp_int);
                            const gop = try props.getOrPut(cp);
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            gop.value_ptr.* |= bit;
                        }
                    },
                    else => {},
                }
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    {
        var in_reader = std.Io.Reader.fixed(@embedFile("SpecialCasing.txt"));

        while (in_reader.takeDelimiterInclusive('\n')) |took| {
            const line = mem.trimEnd(u8, took, "\n");
            if (line.len == 0 or line[0] == '#') continue;
            const no_comment = mem.trim(u8, if (mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line, " ");
            if (no_comment.len == 0) continue;

            var fields: [5][]const u8 = [_][]const u8{""} ** 5;
            var field_iter = mem.splitScalar(u8, no_comment, ';');
            var i: usize = 0;
            while (i < fields.len) : (i += 1) fields[i] = mem.trim(u8, field_iter.next() orelse "", " ");

            const cp = try std.fmt.parseInt(u21, fields[0], 16);
            if (fields[4].len != 0) continue;

            {
                var mapping = [_]u21{0} ** max_mapping_len;
                var mapping_i: usize = 0;
                var it = mem.tokenizeScalar(u8, fields[1], ' ');
                while (it.next()) |part| {
                    if (mapping_i >= max_mapping_len) return error.MappingTooLong;
                    mapping[mapping_i] = try std.fmt.parseInt(u21, part, 16);
                    mapping_i += 1;
                }

                if (mapping[0] != 0) {
                    if (mapping[0] == cp and mem.sliceTo(&mapping, 0).len == 1) {
                        _ = full_lower.swapRemove(cp);
                    } else {
                        try full_lower.put(allocator, cp, mapping);
                    }
                }
            }

            {
                var mapping = [_]u21{0} ** max_mapping_len;
                var mapping_i: usize = 0;
                var it = mem.tokenizeScalar(u8, fields[2], ' ');
                while (it.next()) |part| {
                    if (mapping_i >= max_mapping_len) return error.MappingTooLong;
                    mapping[mapping_i] = try std.fmt.parseInt(u21, part, 16);
                    mapping_i += 1;
                }

                if (mapping[0] != 0) {
                    if (mapping[0] == cp and mem.sliceTo(&mapping, 0).len == 1) {
                        _ = full_title.swapRemove(cp);
                    } else {
                        try full_title.put(allocator, cp, mapping);
                    }
                }
            }

            {
                var mapping = [_]u21{0} ** max_mapping_len;
                var mapping_i: usize = 0;
                var it = mem.tokenizeScalar(u8, fields[3], ' ');
                while (it.next()) |part| {
                    if (mapping_i >= max_mapping_len) return error.MappingTooLong;
                    mapping[mapping_i] = try std.fmt.parseInt(u21, part, 16);
                    mapping_i += 1;
                }

                if (mapping[0] != 0) {
                    if (mapping[0] == cp and mem.sliceTo(&mapping, 0).len == 1) {
                        _ = full_upper.swapRemove(cp);
                    } else {
                        try full_upper.put(allocator, cp, mapping);
                    }
                }
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    const simple_data = simple_data: {
        var blocks_map = BlockMap(SimpleMapping).init(allocator);
        var stage1 = std.array_list.Managed(u16).init(allocator);
        var stage2 = std.array_list.Managed(SimpleMapping).init(allocator);

        const empty_block: [block_size]SimpleMapping = [_]SimpleMapping{.{}} ** block_size;
        try blocks_map.put(empty_block, 0);
        try stage2.appendSlice(&empty_block);

        var block = empty_block;
        var block_len: usize = 0;

        for (0..0x110000) |cp_int| {
            const cp: u21 = @intCast(cp_int);
            block[block_len] = .{
                .lower = simple_lower.get(cp) orelse 0,
                .title = simple_title.get(cp) orelse (simple_upper.get(cp) orelse 0),
                .upper = simple_upper.get(cp) orelse 0,
            };
            block_len += 1;

            if (block_len < block_size and cp != 0x10ffff) continue;

            const gop = try blocks_map.getOrPut(block);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(stage2.items.len);
                try stage2.appendSlice(&block);
            }

            try stage1.append(gop.value_ptr.*);
            block = empty_block;
            block_len = 0;
        }

        break :simple_data .{
            .stage1 = trimTrailingZeroBlocks(u16, stage1.items),
            .stage2 = stage2.items,
        };
    };

    const props_data = props_data: {
        var blocks_map = BlockMap(u8).init(allocator);
        var stage1 = std.array_list.Managed(u16).init(allocator);
        var stage2 = std.array_list.Managed(u8).init(allocator);

        const empty_block: [block_size]u8 = [_]u8{0} ** block_size;
        try blocks_map.put(empty_block, 0);
        try stage2.appendSlice(&empty_block);

        var block = empty_block;
        var block_len: usize = 0;

        for (0..0x110000) |cp_int| {
            const cp: u21 = @intCast(cp_int);
            block[block_len] = props.get(cp) orelse 0;
            block_len += 1;

            if (block_len < block_size and cp != 0x10ffff) continue;

            const gop = try blocks_map.getOrPut(block);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(stage2.items.len);
                try stage2.appendSlice(&block);
            }

            try stage1.append(gop.value_ptr.*);
            block = empty_block;
            block_len = 0;
        }

        break :props_data .{
            .stage1 = trimTrailingZeroBlocks(u16, stage1.items),
            .stage2 = stage2.items,
        };
    };

    const lower_full = lower_full: {
        var single_to_index = std.AutoHashMap(u21, u16).init(allocator);
        var unique_singles: std.array_hash_map.Auto(u21, u32) = .empty;
        var mappings_to_index: std.array_hash_map.Auto([max_mapping_len]u21, u16) = .empty;
        var codepoint_to_index = std.AutoHashMap(u21, u16).init(allocator);

        {
            var it = full_lower.iterator();
            while (it.next()) |entry| {
                const mapping = mem.sliceTo(entry.value_ptr, 0);
                if (mapping.len == 1) {
                    const gop = try unique_singles.getOrPut(allocator, mapping[0]);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }

            try unique_singles.put(allocator, 0, 0x10FFFF);
            const SortCtx = struct {
                vals: []u32,
                pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                    return ctx.vals[a_index] > ctx.vals[b_index];
                }
            };
            unique_singles.sort(SortCtx{ .vals = unique_singles.values() });

            var index: u16 = 0;
            var single_it = unique_singles.iterator();
            while (single_it.next()) |entry| : (index += 1) {
                try single_to_index.put(entry.key_ptr.*, index + 1);
            }
        }

        {
            var multiple_count: u16 = 0;
            var it = full_lower.iterator();
            while (it.next()) |entry| {
                const cp = entry.key_ptr.*;
                const mapping = mem.sliceTo(entry.value_ptr, 0);
                if (mapping.len > 1) {
                    const gop = try mappings_to_index.getOrPut(allocator, entry.value_ptr.*);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = multiple_count;
                        multiple_count += 1;
                    }
                    try codepoint_to_index.put(cp, @intCast(unique_singles.count() + 1 + gop.value_ptr.*));
                } else {
                    try codepoint_to_index.put(cp, single_to_index.get(mapping[0]).?);
                }
            }
        }

        const blocks = blocks: {
            var blocks_map = BlockMap(u16).init(allocator);
            var stage1 = std.array_list.Managed(u16).init(allocator);
            var stage2 = std.array_list.Managed(u16).init(allocator);

            const empty_block: [block_size]u16 = [_]u16{0} ** block_size;
            try blocks_map.put(empty_block, 0);
            try stage2.appendSlice(&empty_block);

            var block = empty_block;
            var block_len: usize = 0;

            for (0..0x110000) |cp_int| {
                const cp: u21 = @intCast(cp_int);
                block[block_len] = codepoint_to_index.get(cp) orelse 0;
                block_len += 1;

                if (block_len < block_size and cp != 0x10ffff) continue;

                const gop = try blocks_map.getOrPut(block);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(stage2.items.len);
                    try stage2.appendSlice(&block);
                }

                try stage1.append(gop.value_ptr.*);
                block = empty_block;
                block_len = 0;
            }

            break :blocks .{
                .stage1 = stage1.items,
                .stage2 = stage2.items,
            };
        };

        const meaningful_stage1 = trimTrailingZeroBlocks(u16, blocks.stage1);
        const cutoff: u21 = @intCast(meaningful_stage1.len << 8);
        const stage3 = try allocator.alloc(u21, unique_singles.count());

        var stage3_index: usize = 0;
        for (unique_singles.keys()) |single| {
            stage3[stage3_index] = single;
            stage3_index += 1;
        }

        const stage4 = try allocator.alloc(MultiMapping, mappings_to_index.count());
        var multis_len: usize = 0;
        for (mappings_to_index.keys()) |mapping| multis_len += mem.sliceTo(&mapping, 0).len;
        const multis = try allocator.alloc(u21, multis_len);
        var multis_i: usize = 0;
        for (mappings_to_index.keys(), 0..) |mapping, i| {
            const slice = mem.sliceTo(&mapping, 0);
            stage4[i] = .{ .len = @intCast(slice.len), .index = @intCast(multis_i) };
            @memcpy(multis[multis_i..][0..slice.len], slice);
            multis_i += slice.len;
        }

        break :lower_full .{
            .cutoff = cutoff,
            .s4_start = @as(u16, @intCast(unique_singles.count() + 1)),
            .stage1 = meaningful_stage1,
            .stage2 = blocks.stage2,
            .stage3 = stage3,
            .stage4 = stage4,
            .multis = multis,
        };
    };

    const upper_full = upper_full: {
        var single_to_index = std.AutoHashMap(u21, u16).init(allocator);
        var unique_singles: std.array_hash_map.Auto(u21, u32) = .empty;
        var mappings_to_index: std.array_hash_map.Auto([max_mapping_len]u21, u16) = .empty;
        var codepoint_to_index = std.AutoHashMap(u21, u16).init(allocator);

        {
            var it = full_upper.iterator();
            while (it.next()) |entry| {
                const mapping = mem.sliceTo(entry.value_ptr, 0);
                if (mapping.len == 1) {
                    const gop = try unique_singles.getOrPut(allocator, mapping[0]);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }

            try unique_singles.put(allocator, 0, 0x10FFFF);
            const SortCtx = struct {
                vals: []u32,
                pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                    return ctx.vals[a_index] > ctx.vals[b_index];
                }
            };
            unique_singles.sort(SortCtx{ .vals = unique_singles.values() });

            var index: u16 = 0;
            var single_it = unique_singles.iterator();
            while (single_it.next()) |entry| : (index += 1) {
                try single_to_index.put(entry.key_ptr.*, index + 1);
            }
        }

        {
            var multiple_count: u16 = 0;
            var it = full_upper.iterator();
            while (it.next()) |entry| {
                const cp = entry.key_ptr.*;
                const mapping = mem.sliceTo(entry.value_ptr, 0);
                if (mapping.len > 1) {
                    const gop = try mappings_to_index.getOrPut(allocator, entry.value_ptr.*);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = multiple_count;
                        multiple_count += 1;
                    }
                    try codepoint_to_index.put(cp, @intCast(unique_singles.count() + 1 + gop.value_ptr.*));
                } else {
                    try codepoint_to_index.put(cp, single_to_index.get(mapping[0]).?);
                }
            }
        }

        const blocks = blocks: {
            var blocks_map = BlockMap(u16).init(allocator);
            var stage1 = std.array_list.Managed(u16).init(allocator);
            var stage2 = std.array_list.Managed(u16).init(allocator);

            const empty_block: [block_size]u16 = [_]u16{0} ** block_size;
            try blocks_map.put(empty_block, 0);
            try stage2.appendSlice(&empty_block);

            var block = empty_block;
            var block_len: usize = 0;

            for (0..0x110000) |cp_int| {
                const cp: u21 = @intCast(cp_int);
                block[block_len] = codepoint_to_index.get(cp) orelse 0;
                block_len += 1;

                if (block_len < block_size and cp != 0x10ffff) continue;

                const gop = try blocks_map.getOrPut(block);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(stage2.items.len);
                    try stage2.appendSlice(&block);
                }

                try stage1.append(gop.value_ptr.*);
                block = empty_block;
                block_len = 0;
            }

            break :blocks .{
                .stage1 = stage1.items,
                .stage2 = stage2.items,
            };
        };

        const meaningful_stage1 = trimTrailingZeroBlocks(u16, blocks.stage1);
        const cutoff: u21 = @intCast(meaningful_stage1.len << 8);
        const stage3 = try allocator.alloc(u21, unique_singles.count());

        var stage3_index: usize = 0;
        for (unique_singles.keys()) |single| {
            stage3[stage3_index] = single;
            stage3_index += 1;
        }

        const stage4 = try allocator.alloc(MultiMapping, mappings_to_index.count());
        var multis_len: usize = 0;
        for (mappings_to_index.keys()) |mapping| multis_len += mem.sliceTo(&mapping, 0).len;
        const multis = try allocator.alloc(u21, multis_len);
        var multis_i: usize = 0;
        for (mappings_to_index.keys(), 0..) |mapping, i| {
            const slice = mem.sliceTo(&mapping, 0);
            stage4[i] = .{ .len = @intCast(slice.len), .index = @intCast(multis_i) };
            @memcpy(multis[multis_i..][0..slice.len], slice);
            multis_i += slice.len;
        }

        break :upper_full .{
            .cutoff = cutoff,
            .s4_start = @as(u16, @intCast(unique_singles.count() + 1)),
            .stage1 = meaningful_stage1,
            .stage2 = blocks.stage2,
            .stage3 = stage3,
            .stage4 = stage4,
            .multis = multis,
        };
    };

    const title_full = title_full: {
        var single_to_index = std.AutoHashMap(u21, u16).init(allocator);
        var unique_singles: std.array_hash_map.Auto(u21, u32) = .empty;
        var mappings_to_index: std.array_hash_map.Auto([max_mapping_len]u21, u16) = .empty;
        var codepoint_to_index = std.AutoHashMap(u21, u16).init(allocator);

        {
            var it = full_title.iterator();
            while (it.next()) |entry| {
                const mapping = mem.sliceTo(entry.value_ptr, 0);
                if (mapping.len == 1) {
                    const gop = try unique_singles.getOrPut(allocator, mapping[0]);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }

            try unique_singles.put(allocator, 0, 0x10FFFF);
            const SortCtx = struct {
                vals: []u32,
                pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                    return ctx.vals[a_index] > ctx.vals[b_index];
                }
            };
            unique_singles.sort(SortCtx{ .vals = unique_singles.values() });

            var index: u16 = 0;
            var single_it = unique_singles.iterator();
            while (single_it.next()) |entry| : (index += 1) {
                try single_to_index.put(entry.key_ptr.*, index + 1);
            }
        }

        {
            var multiple_count: u16 = 0;
            var it = full_title.iterator();
            while (it.next()) |entry| {
                const cp = entry.key_ptr.*;
                const mapping = mem.sliceTo(entry.value_ptr, 0);
                if (mapping.len > 1) {
                    const gop = try mappings_to_index.getOrPut(allocator, entry.value_ptr.*);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = multiple_count;
                        multiple_count += 1;
                    }
                    try codepoint_to_index.put(cp, @intCast(unique_singles.count() + 1 + gop.value_ptr.*));
                } else {
                    try codepoint_to_index.put(cp, single_to_index.get(mapping[0]).?);
                }
            }
        }

        const blocks = blocks: {
            var blocks_map = BlockMap(u16).init(allocator);
            var stage1 = std.array_list.Managed(u16).init(allocator);
            var stage2 = std.array_list.Managed(u16).init(allocator);

            const empty_block: [block_size]u16 = [_]u16{0} ** block_size;
            try blocks_map.put(empty_block, 0);
            try stage2.appendSlice(&empty_block);

            var block = empty_block;
            var block_len: usize = 0;

            for (0..0x110000) |cp_int| {
                const cp: u21 = @intCast(cp_int);
                block[block_len] = codepoint_to_index.get(cp) orelse 0;
                block_len += 1;

                if (block_len < block_size and cp != 0x10ffff) continue;

                const gop = try blocks_map.getOrPut(block);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(stage2.items.len);
                    try stage2.appendSlice(&block);
                }

                try stage1.append(gop.value_ptr.*);
                block = empty_block;
                block_len = 0;
            }

            break :blocks .{
                .stage1 = stage1.items,
                .stage2 = stage2.items,
            };
        };

        const meaningful_stage1 = trimTrailingZeroBlocks(u16, blocks.stage1);
        const cutoff: u21 = @intCast(meaningful_stage1.len << 8);
        const stage3 = try allocator.alloc(u21, unique_singles.count());

        var stage3_index: usize = 0;
        for (unique_singles.keys()) |single| {
            stage3[stage3_index] = single;
            stage3_index += 1;
        }

        const stage4 = try allocator.alloc(MultiMapping, mappings_to_index.count());
        var multis_len: usize = 0;
        for (mappings_to_index.keys()) |mapping| multis_len += mem.sliceTo(&mapping, 0).len;
        const multis = try allocator.alloc(u21, multis_len);
        var multis_i: usize = 0;
        for (mappings_to_index.keys(), 0..) |mapping, i| {
            const slice = mem.sliceTo(&mapping, 0);
            stage4[i] = .{ .len = @intCast(slice.len), .index = @intCast(multis_i) };
            @memcpy(multis[multis_i..][0..slice.len], slice);
            multis_i += slice.len;
        }

        break :title_full .{
            .cutoff = cutoff,
            .s4_start = @as(u16, @intCast(unique_singles.count() + 1)),
            .stage1 = meaningful_stage1,
            .stage2 = blocks.stage2,
            .stage3 = stage3,
            .stage4 = stage4,
            .multis = multis,
        };
    };

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
        \\pub const SimpleMapping = packed struct(u64) {{
        \\    lower: u21,
        \\    title: u21,
        \\    upper: u21,
        \\    _: u1 = 0,
        \\}};
        \\
        \\pub const MultiMapping = packed struct(u16) {{
        \\    len: u2,
        \\    index: u14, // As of Unicode 17, 158 is the max value of index.
        \\}};
        \\
    , .{});

    try writeArray(&writer.interface, "simple_s1", u16, simple_data.stage1);
    try writeSimpleArray(&writer.interface, "simple_s2", simple_data.stage2);
    try writeArray(&writer.interface, "props_s1", u16, props_data.stage1);
    try writeArray(&writer.interface, "props_s2", u8, props_data.stage2);

    try writer.interface.print(
        \\
        \\pub const lower_full_cutoff: u21 = {};
        \\pub const lower_full_s4_start: u16 = {};
        \\
    , .{ lower_full.cutoff, lower_full.s4_start });
    try writeArray(&writer.interface, "lower_full_s1", u16, lower_full.stage1);
    try writeArray(&writer.interface, "lower_full_s2", u16, lower_full.stage2);
    try writeArray(&writer.interface, "lower_full_s3", u21, lower_full.stage3);
    try writeMultiArray(&writer.interface, "lower_full_s4", lower_full.stage4);
    try writeArray(&writer.interface, "lower_full_multis", u21, lower_full.multis);

    try writer.interface.print(
        \\
        \\pub const title_full_cutoff: u21 = {};
        \\pub const title_full_s4_start: u16 = {};
        \\
    , .{ title_full.cutoff, title_full.s4_start });
    try writeArray(&writer.interface, "title_full_s1", u16, title_full.stage1);
    try writeArray(&writer.interface, "title_full_s2", u16, title_full.stage2);
    try writeArray(&writer.interface, "title_full_s3", u21, title_full.stage3);
    try writeMultiArray(&writer.interface, "title_full_s4", title_full.stage4);
    try writeArray(&writer.interface, "title_full_multis", u21, title_full.multis);

    try writer.interface.print(
        \\
        \\pub const upper_full_cutoff: u21 = {};
        \\pub const upper_full_s4_start: u16 = {};
        \\
    , .{ upper_full.cutoff, upper_full.s4_start });
    try writeArray(&writer.interface, "upper_full_s1", u16, upper_full.stage1);
    try writeArray(&writer.interface, "upper_full_s2", u16, upper_full.stage2);
    try writeArray(&writer.interface, "upper_full_s3", u21, upper_full.stage3);
    try writeMultiArray(&writer.interface, "upper_full_s4", upper_full.stage4);
    try writeArray(&writer.interface, "upper_full_multis", u21, upper_full.multis);

    try writer.interface.flush();
}

fn trimTrailingZeroBlocks(comptime T: type, items: []const T) []const T {
    var len = items.len;
    while (len > 0 and items[len - 1] == 0) : (len -= 1) {}
    return items[0..len];
}

fn writeArray(writer: anytype, name: []const u8, comptime T: type, items: []const T) !void {
    const type_name = switch (T) {
        u8 => "u8",
        u16 => "u16",
        u21 => "u21",
        else => @compileError("Unsupported writeArray type."),
    };
    try writer.print("pub const {s}: [{d}]{s} = .{{\n", .{ name, items.len, type_name });
    for (items) |item| try writer.print("{}, ", .{item});
    try writer.writeAll("\n};\n\n");
}

fn writeSimpleArray(writer: anytype, name: []const u8, items: []const SimpleMapping) !void {
    try writer.print("pub const {s}: [{d}]SimpleMapping = .{{\n", .{ name, items.len });
    for (items) |item| {
        try writer.print(
            ".{{ .lower = {}, .title = {}, .upper = {} }}, ",
            .{ item.lower, item.title, item.upper },
        );
    }
    try writer.writeAll("\n};\n\n");
}

fn writeMultiArray(writer: anytype, name: []const u8, items: []const MultiMapping) !void {
    try writer.print("pub const {s}: [{d}]MultiMapping = .{{\n", .{ name, items.len });
    for (items) |item| {
        try writer.print(".{{ .len = {}, .index = {} }}, ", .{ item.len, item.index });
    }
    try writer.writeAll("\n};\n\n");
}
