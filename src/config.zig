const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const format = @import("format.zig");
const out = @import("out.zig");
const sys = @import("sys.zig");

pub const default_file = @embedFile("config");

pub const default_format: []const u8 = blk: {
    @setEvalBranchQuota(default_file.len * 100);
    var buf = default_file.*;
    const template = extract_format(&buf).?;
    const final = template[0..template.len].*;
    break :blk &final;
};

pub const file_len_max = 4096;
pub const path_suffix = "/.config/lifetch/config";

comptime {
    std.debug.assert(default_file.len < file_len_max);
}

pub const Error = error{ ConfigTooLarge, ConfigUnreadable, ConfigInvalid };

pub const Parsed = struct { format: []const u8, settings: format.Settings };

const format_key = "format = ";

pub const Config = struct {
    buf: [file_len_max]u8,
    create_failed: bool,
    /// The offending option line, valid when `load` returns `error.ConfigInvalid`.
    invalid: []const u8 = "",

    /// Reads `home ++ path_suffix`, writing the default file there when it is missing. Options
    /// before the format line are parsed into `settings`; a file without a format line uses the
    /// default format. The result may point into `self`.
    pub fn load(self: *Config, home: ?[]const u8) Error!Parsed {
        self.create_failed = false;
        self.invalid = "";
        const parts = .{ home orelse return self.default(), path_suffix };
        const path = out.join_z(&self.buf, &parts) orelse return self.default();
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| {
            switch (err) {
                error.FileNotFound => self.create_failed = !create(&self.buf, path.len),
                error.OpenFailed => return error.ConfigUnreadable,
            }
            return self.default();
        };
        defer sys.close(fd);
        const len = sys.read(fd, &self.buf) catch return error.ConfigUnreadable;
        if (len == self.buf.len) return error.ConfigTooLarge;
        const text = self.buf[0..len];
        const settings = parse_options(text, &self.invalid) catch return error.ConfigInvalid;
        return .{ .format = extract_format(text) orelse default_format, .settings = settings };
    }

    /// The embedded default file, whose options the comptime block in main.zig has checked.
    fn default(self: *Config) Parsed {
        const settings: format.Settings = parse_options(default_file, &self.invalid) catch .{};
        return .{ .format = default_format, .settings = settings };
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

/// The option lines before `format = `. Unknown keys are ignored so a newer config keeps working
/// on an older binary; a bad value of a known key fails with the offending line in `invalid`.
/// Lines after the format line are template text and never options: a future option can not eat
/// someone's output.
pub fn parse_options(text: []const u8, invalid: *[]const u8) error{ConfigInvalid}!format.Settings {
    invalid.* = text;
    var settings: format.Settings = .{};
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        // Trim the start only: a separator or text variable may end in spaces on purpose.
        const line = mem.trimStart(u8, text[line_start..line_end], &std.ascii.whitespace);
        line_start = line_end + 1;
        if (line.len == 0 or line[0] == '#') continue;
        if (mem.startsWith(u8, line, format_key)) break;
        option(line, &settings, invalid) catch return error.ConfigInvalid;
    }
    return settings;
}

fn option(line: []const u8, settings: *format.Settings, invalid: *[]const u8) error{ConfigInvalid}!void {
    const eq = mem.findScalar(u8, line, '=') orelse return;
    const key = mem.trim(u8, line[0..eq], &std.ascii.whitespace);
    var value: []const u8 = line[eq + 1 ..];
    if (value.len > 0 and value[0] == ' ') value = value[1..];
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1]; // quotes keep leading and trailing spaces
    }
    if (mem.eql(u8, key, "units")) {
        settings.opts.unit = out.parse_unit(mem.trim(u8, value, &std.ascii.whitespace)) orelse return fail(invalid, line);
        return;
    }
    if (mem.eql(u8, key, "precision")) {
        const text = mem.trim(u8, value, &std.ascii.whitespace);
        const n = std.fmt.parseInt(u8, text, 10) catch return fail(invalid, line);
        if (n > 4) return fail(invalid, line); // out.Opts accepts 0..=4
        settings.opts.precision = n;
        return;
    }
    if (mem.eql(u8, key, "sep.disk")) {
        if (!settings.sep_disk.set(value)) return fail(invalid, line);
        return;
    }
    if (mem.eql(u8, key, "sep.gpu")) {
        if (!settings.sep_gpu.set(value)) return fail(invalid, line);
        return;
    }
    if (mem.startsWith(u8, key, "var.")) {
        const name = key["var.".len..];
        if (name.len == 0 or name.len > format.var_name_max) return fail(invalid, line);
        settings.palette.put_text(name, value) catch return fail(invalid, line);
        return;
    }
    if (mem.startsWith(u8, key, "color.")) {
        const name = key["color.".len..];
        if (name.len == 0 or name.len > format.var_name_max) return fail(invalid, line);
        const color = format.parse_color_value(value) orelse return fail(invalid, line);
        settings.palette.put_color(name, color) catch return fail(invalid, line);
        return;
    }
    // Unknown keys are ignored: a config from a newer lifetch keeps working here.
}

fn fail(invalid: *[]const u8, line: []const u8) error{ConfigInvalid} {
    invalid.* = line;
    return error.ConfigInvalid;
}

/// In place: the value after `format = ` plus each later line that is neither blank nor a
/// comment, joined with newlines.
pub fn extract_format(text: []u8) ?[]const u8 {
    const key = format_key;
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
    const template = extract_format(&buf).?;
    try std.testing.expectEqualStrings("{user}@{host}\n{shell}\n{term}", template);
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
    const template = extract_format(buf[0..len]) orelse return;
    try std.testing.expect(template.len <= len);
    var lines = mem.splitScalar(u8, template, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        try std.testing.expect(line.len > 0 and line[0] != '#');
    }
}

test "parse_options: known keys fill settings, unknown keys are ignored" {
    var invalid: []const u8 = undefined;
    const text =
        \\# comment
        \\bogus = 1
        \\units = g
        \\precision = 3
        \\sep.disk = " | "
        \\sep.gpu = +
        \\var.label = ram:
        \\color.accent = 180,142,173
        \\color.warn = red
        \\
        \\format = x
        \\units = t
    ;
    const settings = try parse_options(text, &invalid);
    try std.testing.expectEqual(out.Unit.g, settings.opts.unit);
    try std.testing.expectEqual(@as(u8, 3), settings.opts.precision);
    try std.testing.expectEqualStrings(" | ", settings.sep_disk.slice());
    try std.testing.expectEqualStrings("+", settings.sep_gpu.slice());
    try std.testing.expectEqualStrings("ram:", settings.palette.text("label").?);
    const accent = settings.palette.color("accent").?;
    try std.testing.expect(accent == .rgb);
    try std.testing.expectEqual(format.Rgb{ .r = 180, .g = 142, .b = 173 }, accent.rgb);
    const warn = settings.palette.color("warn").?;
    try std.testing.expect(warn == .basic);
    try std.testing.expectEqualStrings("\x1b[31m", warn.basic);
    // The `units = t` after the format line is template text, not an option.
    try std.testing.expectEqual(out.Unit.g, settings.opts.unit);
}

test "parse_options: trailing spaces survive, quotes protect them" {
    var invalid: []const u8 = undefined;
    const settings = try parse_options("var.label = ram:  \nsep.disk = \"  \"\nformat = x", &invalid);
    try std.testing.expectEqualStrings("ram:  ", settings.palette.text("label").?);
    try std.testing.expectEqualStrings("  ", settings.sep_disk.slice());
}

test "parse_options: bad values name their line, first definition wins" {
    var invalid: []const u8 = undefined;
    try std.testing.expectError(error.ConfigInvalid, parse_options("units = q\nformat = x", &invalid));
    try std.testing.expectEqualStrings("units = q", invalid);
    try std.testing.expectError(error.ConfigInvalid, parse_options("precision = 9\nformat = x", &invalid));
    try std.testing.expectEqualStrings("precision = 9", invalid);
    try std.testing.expectError(error.ConfigInvalid, parse_options("precision = x\nformat = x", &invalid));
    try std.testing.expectError(error.ConfigInvalid, parse_options("color.a = nope\nformat = x", &invalid));
    try std.testing.expectEqualStrings("color.a = nope", invalid);
    try std.testing.expectError(error.ConfigInvalid, parse_options("var. = 1\nformat = x", &invalid));
    try std.testing.expectError(error.ConfigInvalid, parse_options("var.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx = 1\nformat = x", &invalid)); // 33 > var_name_max
    try std.testing.expectError(error.ConfigInvalid, parse_options("sep.disk = x y z 4567890123456789012345678901234567890123456789012345678901234567890\nformat = x", &invalid));

    const settings = try parse_options("var.a = 1\nvar.a = 2\nformat = x", &invalid);
    try std.testing.expectEqualStrings("1", settings.palette.text("a").?);
}

test "parse_options: the default file parses" {
    var invalid: []const u8 = undefined;
    const settings = try parse_options(default_file, &invalid);
    try std.testing.expectEqual(out.Unit.auto, settings.opts.unit);
    try std.testing.expectEqual(@as(u8, 1), settings.opts.precision);
}

test "default_format: the shipped config's format" {
    try std.testing.expect(mem.startsWith(u8, default_format, "{rgb(108,108,108)}[ {/}"));
    try std.testing.expect(mem.find(u8, default_format, "Lifetch Configuration") == null);
}
