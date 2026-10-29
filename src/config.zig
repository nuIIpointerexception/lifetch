const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const out = @import("out.zig");
const sys = @import("sys.zig");

const default_file = @embedFile("config");

pub const default_format: []const u8 = blk: {
    @setEvalBranchQuota(default_file.len * 100);
    var buf = default_file.*;
    const format = extract_format(&buf).?;
    const final = format[0..format.len].*;
    break :blk &final;
};

pub const file_len_max = 4096;
pub const path_suffix = "/.config/lifetch/config";

comptime {
    std.debug.assert(default_file.len < file_len_max);
}

pub const Error = error{ ConfigTooLarge, ConfigUnreadable };

pub const Config = struct {
    buf: [file_len_max]u8,
    create_failed: bool,

    /// Reads `home ++ path_suffix`, writing the default file there when it is missing. A file
    /// without a format line uses the default format. The result may point into `self`.
    pub fn load(self: *Config, home: ?[]const u8) Error![]const u8 {
        self.create_failed = false;
        const parts = .{ home orelse return default_format, path_suffix };
        const path = out.join_z(&self.buf, &parts) orelse return default_format;
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| {
            switch (err) {
                error.FileNotFound => self.create_failed = !create(&self.buf, path.len),
                error.OpenFailed => return error.ConfigUnreadable,
            }
            return default_format;
        };
        defer sys.close(fd);
        const len = sys.read(fd, &self.buf) catch return error.ConfigUnreadable;
        if (len == self.buf.len) return error.ConfigTooLarge;
        return extract_format(self.buf[0..len]) orelse default_format;
    }
};

fn create(buf: *[file_len_max]u8, path_len: usize) bool {
    const file_at = path_len - "/config".len;
    const dir_at = file_at - "/lifetch".len;
    for ([_]usize{ dir_at, file_at }) |end| {
        buf[end] = 0;
        const status = sys.mkdir(@ptrCast(buf));
        buf[end] = '/';
        if (status != .SUCCESS and status != .EXIST) return false;
    }
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const fd = sys.open(@ptrCast(buf), flags, 0o644) catch return false;
    defer sys.close(fd);
    return sys.write_all(fd, default_file);
}

/// In place: the value after `format = ` plus each later line that is neither blank nor a
/// comment, joined with newlines.
pub fn extract_format(text: []u8) ?[]const u8 {
    const key = "format = ";
    const space = &std.ascii.whitespace;
    var len: usize = 0;
    var found = false;
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const trimmed_start = line_start + (line.len - mem.trimStart(u8, line, space).len);
        const trimmed = mem.trim(u8, line, space);
        line_start = line_end + 1;
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var skip: usize = 0;
        if (found) {
            text[len] = '\n';
            len += 1;
        } else if (mem.startsWith(u8, trimmed, key)) {
            skip = key.len;
            found = true;
        } else continue;
        const part_start = trimmed_start + skip;
        const part_len = trimmed.len - skip;
        std.debug.assert(len <= part_start);
        mem.copyForwards(u8, text[len..][0..part_len], text[part_start..][0..part_len]);
        len += part_len;
    }
    return if (found) text[0..len] else null;
}

test "extract_format: joins continuation lines, skips comments" {
    var buf =
        \\# comment
        \\other = 1
        \\format = {user}@{host}
        \\
        \\  # inner comment
        \\{shell}
        \\  {term}
    .*;
    const format = extract_format(&buf).?;
    try std.testing.expectEqualStrings("{user}@{host}\n{shell}\n{term}", format);
    var none = "# only\n".*;
    try std.testing.expect(extract_format(&none) == null);
}

test "extract_format: in place, never longer than its input, no comment lines" {
    try std.testing.fuzz({}, fuzz_extract_format, .{ .corpus = &.{
        "format = a\n  b\n# c\n\n d ",
        "format = ",
        "\n\nformat = {x}\n",
        default_file,
    } });
}

fn fuzz_extract_format(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const format = extract_format(buf[0..len]) orelse return;
    try std.testing.expect(format.len <= len);
    var lines = mem.splitScalar(u8, format, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        try std.testing.expect(line.len > 0 and line[0] != '#');
    }
}

test "default_format: the shipped config's format" {
    try std.testing.expect(mem.startsWith(u8, default_format, "{rgb(108,108,108)}[ {/}"));
    try std.testing.expect(mem.find(u8, default_format, "Lifetch Configuration") == null);
}
