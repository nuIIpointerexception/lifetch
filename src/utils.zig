const std = @import("std");
const mem = std.mem;
const builtin = std.builtin.Type.Vector;

pub inline fn findPrefix(bytes: []const u8, pattern: []const u8) ?usize {
    const vec_size = 16;

    if (bytes.len < pattern.len) return null;
    if (pattern.len == 0) return 0;

    const pre_len = @min(bytes.len, vec_size);
    for (0..pre_len) |i| {
        if (i + pattern.len <= bytes.len and mem.startsWith(u8, bytes[i..], pattern)) {
            return i;
        }
    }

    if (bytes.len <= vec_size) return null;

    var i: usize = vec_size;
    const aligned_len = bytes.len - (bytes.len % vec_size);

    const first_char = @as(@Vector(vec_size, u8), @splat(pattern[0]));
    while (i < aligned_len) : (i += vec_size) {
        const chunk: @Vector(vec_size, u8) = bytes[i..][0..vec_size].*;
        const matches = chunk == first_char;
        const mask = @as(u16, @bitCast(matches));

        if (mask != 0) {
            var bit_pos: u4 = @truncate(@ctz(mask));
            while (bit_pos < vec_size) : (bit_pos +%= 1) {
                const pos = i + bit_pos;
                if (pos + pattern.len <= bytes.len and mem.startsWith(u8, bytes[pos..], pattern)) {
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
        if (i + pattern.len <= bytes.len and bytes[i] == pattern[0] and
            mem.startsWith(u8, bytes[i..], pattern))
        {
            return i;
        }
    }

    return null;
}

pub fn getEnvValue(content: []const u8, comptime prefix: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < content.len) {
        if (i + prefix.len <= content.len and mem.eql(u8, content[i..][0..prefix.len], prefix)) {
            const start = i + prefix.len;
            const end = if (mem.indexOfScalarPos(u8, content, start, 0)) |e|
                e
            else
                content.len;
            const value = content[start..end];
            return if (value.len == 0) null else value;
        }
        while (i < content.len and content[i] != 0) : (i += 1) {}
        i += 1;
    }
    return null;
}

pub fn formatUptime(seconds: u64, buf: []u8) []const u8 {
    const days = seconds / (24 * 60 * 60);
    const hours = (seconds % (24 * 60 * 60)) / (60 * 60);
    const minutes = (seconds % (60 * 60)) / 60;

    if (days > 0) {
        return std.fmt.bufPrintZ(buf, "{d}d {d}h {d}m", .{ days, hours, minutes }) catch buf[0..0];
    } else if (hours > 0) {
        return std.fmt.bufPrintZ(buf, "{d}h {d}m", .{ hours, minutes }) catch buf[0..0];
    } else {
        return std.fmt.bufPrintZ(buf, "{d}m", .{minutes}) catch buf[0..0];
    }
}

pub fn replaceAlloc(allocator: mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0 or input.len == 0) {
        return allocator.dupe(u8, input);
    }

    if (mem.indexOf(u8, input, needle) == null) {
        return allocator.dupe(u8, input);
    }

    var count: usize = 0;
    var i: usize = 0;
    while (mem.indexOfPos(u8, input, i, needle)) |pos| {
        count += 1;
        i = pos + needle.len;
    }

    const final_size = input.len - (count * needle.len) + (count * replacement.len);
    const result = try allocator.alloc(u8, final_size);
    errdefer allocator.free(result);

    var out_pos: usize = 0;
    i = 0;
    while (i < input.len) {
        if (i <= input.len - needle.len and mem.eql(u8, input[i..][0..needle.len], needle)) {
            @memcpy(result[out_pos..][0..replacement.len], replacement);
            out_pos += replacement.len;
            i += needle.len;
        } else {
            result[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    return result;
}

pub const FormatContext = struct {
    allocator: mem.Allocator,
    replacements: std.StringHashMap([]const u8),

    const Token = struct {
        start: usize,
        end: usize,
        key: []const u8,
        replacement: []const u8,
    };

    pub fn init(allocator: mem.Allocator) FormatContext {
        return .{
            .allocator = allocator,
            .replacements = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FormatContext) void {
        self.replacements.deinit();
    }

    pub fn add(self: *FormatContext, key: []const u8, value: []const u8) !void {
        try self.replacements.put(key, value);
    }

    pub fn format(self: *const FormatContext, template: []const u8) ![]const u8 {
        var tokens = std.ArrayList(Token).init(self.allocator);
        defer tokens.deinit();

        var size_diff: isize = 0;
        var pos: usize = 0;

        while (pos < template.len) {
            if (template[pos] == '{' and pos + 2 < template.len) {
                const end_pos = mem.indexOfPos(u8, template, pos + 1, "}") orelse {
                    pos += 1;
                    continue;
                };

                const key = template[pos + 1 .. end_pos];

                if (self.replacements.get(key)) |replacement| {
                    try tokens.append(Token{
                        .start = pos,
                        .end = end_pos + 1,
                        .key = key,
                        .replacement = replacement,
                    });

                    size_diff += @as(isize, @intCast(replacement.len)) -
                        @as(isize, @intCast(end_pos + 1 - pos));

                    pos = end_pos + 1;
                } else {
                    pos += 1;
                }
            } else {
                pos += 1;
            }
        }

        if (tokens.items.len == 0) {
            return self.allocator.dupe(u8, template);
        }

        const result_len = @as(usize, @intCast(@as(isize, @intCast(template.len)) + size_diff));
        const result = try self.allocator.alloc(u8, result_len);
        errdefer self.allocator.free(result);

        var last_pos: usize = 0;
        var out_pos: usize = 0;

        for (tokens.items) |token| {
            const before_len = token.start - last_pos;
            if (before_len > 0) {
                @memcpy(result[out_pos..][0..before_len], template[last_pos..token.start]);
                out_pos += before_len;
            }

            @memcpy(result[out_pos..][0..token.replacement.len], token.replacement);
            out_pos += token.replacement.len;

            last_pos = token.end;
        }

        if (last_pos < template.len) {
            const remaining = template.len - last_pos;
            @memcpy(result[out_pos..][0..remaining], template[last_pos..]);
            out_pos += remaining;
        }

        return result;
    }
};

pub fn formatReplace(allocator: mem.Allocator, template: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    const full_key_len = key.len + 2;
    _ = full_key_len;
    const full_key = try std.fmt.allocPrint(allocator, "{{{s}}}", .{key});
    defer allocator.free(full_key);

    if (mem.indexOf(u8, template, full_key) == null) {
        return allocator.dupe(u8, template);
    }

    var count: usize = 0;
    var i: usize = 0;
    while (mem.indexOfPos(u8, template, i, full_key)) |pos| {
        count += 1;
        i = pos + full_key.len;
    }

    const final_size = template.len - (count * full_key.len) + (count * value.len);
    const result = try allocator.alloc(u8, final_size);
    errdefer allocator.free(result);

    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    i = 0;

    while (i < template.len) {
        if (i <= template.len - full_key.len and mem.eql(u8, template[i..][0..full_key.len], full_key)) {
            if (i > src_pos) {
                const len = i - src_pos;
                @memcpy(result[dst_pos..][0..len], template[src_pos..i]);
                dst_pos += len;
            }

            @memcpy(result[dst_pos..][0..value.len], value);
            dst_pos += value.len;

            i += full_key.len;
            src_pos = i;
        } else {
            i += 1;
        }
    }

    if (src_pos < template.len) {
        const len = template.len - src_pos;
        @memcpy(result[dst_pos..][0..len], template[src_pos..]);
    }

    return result;
}
