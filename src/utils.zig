const std = @import("std");
const mem = std.mem;
const builtin = std.builtin.Type.Vector;

pub inline fn findPrefix(bytes: []const u8, pattern: []const u8) ?usize {
    const vec_size = 16;
    if (bytes.len < pattern.len) return null;

    var i: usize = 0;
    const aligned_len = bytes.len - (bytes.len % vec_size);
    while (i < aligned_len) : (i += vec_size) {
        const chunk: @Vector(vec_size, u8) = bytes[i..][0..vec_size].*;
        const matches = chunk == @as(@Vector(vec_size, u8), @splat(pattern[0]));
        const mask = @as(u16, @bitCast(matches));

        if (mask != 0) {
            var bit_pos: u4 = @truncate(@ctz(mask));
            while (bit_pos < vec_size) : (bit_pos +%= 1) {
                const pos = i + bit_pos;
                if (pos + pattern.len > bytes.len) continue;
                if (mem.startsWith(u8, bytes[pos..], pattern)) {
                    return pos;
                }
                if (bit_pos == vec_size - 1) break;
                const shift: u4 = bit_pos +% 1;
                const remaining = mask >> shift;
                if (remaining == 0) break;
                const next_bit: u4 = @truncate(@ctz(remaining));
                bit_pos +%= next_bit;
            }
        }
    }

    while (i < bytes.len) : (i += 1) {
        if (mem.startsWith(u8, bytes[i..], pattern)) {
            return i;
        }
    }

    return null;
}

pub inline fn getEnvValue(content: []const u8, comptime prefix: []const u8) ?[]const u8 {
    return if (findPrefix(content, prefix)) |pos| blk: {
        const start = pos + prefix.len;
        const end = if (mem.indexOfScalar(u8, content[start..], 0)) |e|
            start + e
        else
            content.len;
        const value = content[start..end];
        break :blk if (value.len == 0) null else value;
    } else null;
}

pub inline fn formatUptime(seconds: u64, buf: []u8) []const u8 {
    const days = seconds / (24 * 60 * 60);
    const hours = (seconds % (24 * 60 * 60)) / (60 * 60);
    const minutes = (seconds % (60 * 60)) / 60;

    return if (days > 0) std.fmt.bufPrintZ(buf, "{d}d {d}h {d}m", .{
        days,
        hours,
        minutes,
    }) catch buf[0..0] else if (hours > 0) std.fmt.bufPrintZ(buf, "{d}h {d}m", .{
        hours,
        minutes,
    }) catch buf[0..0] else std.fmt.bufPrintZ(
        buf,
        "{d}m",
        .{minutes},
    ) catch buf[0..0];
}

pub fn replaceAlloc(allocator: mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var final_size: usize = input.len;
    var count: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i + needle.len <= input.len and mem.startsWith(u8, input[i..], needle)) {
            final_size = final_size - needle.len + replacement.len;
            count += 1;
            i += needle.len - 1;
        }
    }

    if (count == 0) return allocator.dupe(u8, input);

    var result = try allocator.alloc(u8, final_size);
    errdefer allocator.free(result);

    var out_idx: usize = 0;
    i = 0;
    while (i < input.len) {
        if (i + needle.len <= input.len and mem.startsWith(u8, input[i..], needle)) {
            @memcpy(result[out_idx..][0..replacement.len], replacement);
            out_idx += replacement.len;
            i += needle.len;
        } else {
            result[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    return result;
}
