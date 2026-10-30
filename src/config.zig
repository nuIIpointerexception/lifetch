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

/// The shipped file's options, parsed at comptime next to `default_format` (main.zig validates
/// the tags against these at build time too). A runtime config that defines no option points
/// here, so the common `{user}`-only config never writes a settings copy at all.
pub const default_settings: format.Settings = blk: {
    @setEvalBranchQuota(default_file.len * 300);
    // The shipped file must parse clean: the build fails naming any offending line.
    const Capture = struct {
        bad: *[]const u8,
        fn warn(self: @This(), line: []const u8) void {
            if (self.bad.*.len == 0) self.bad.* = line;
        }
    };
    var bad: []const u8 = "";
    var settings: format.Settings = .{};
    _ = parse_options(default_file, Capture{ .bad = &bad }, &settings);
    if (bad.len != 0) @compileError("config.ini: bad option \"" ++ bad ++ "\"");
    break :blk settings;
};

pub const file_len_max = 4096;
pub const path_suffix = "/.config/lifetch/config";

comptime {
    std.debug.assert(default_file.len < file_len_max);
}

pub const Error = error{ ConfigTooLarge, ConfigUnreadable };

pub const Parsed = struct {
    format: []const u8,
    /// The options the file defines, or `default_settings` when it defines none. Both outlive the
    /// run (the `Config` and static storage respectively), so nothing here is copied.
    settings: *const format.Settings,
};

const format_key = "format = ";

/// Non-fatal notices about config lines: `warn` receives the offending line as written.
pub const Stderr = struct {
    home: []const u8 = "",
    pub fn warn(self: Stderr, line: []const u8) void {
        for ([_][]const u8{ "lifetch: ignoring \"", line, "\" in ", self.home, path_suffix, "\n" }) |part| {
            _ = sys.write_all(2, part);
        }
    }
};

/// A capturing sink, for tests that check the warning path without printing. It copies each
/// line: `load` compacts its buffer after parsing, so borrowed slices would not stay valid.
pub const Warnings = struct {
    text: [8 * 256]u8 = undefined,
    lines: [8][]const u8 = undefined,
    len: usize = 0,
    pub fn warn(self: *Warnings, line: []const u8) void {
        if (self.len < self.lines.len) {
            const n = @min(line.len, 256);
            const start = self.len * 256;
            out.copy(self.text[start..][0..n], line[0..n]);
            self.lines[self.len] = self.text[start..][0..n];
            self.len += 1;
        }
    }
};

pub const Config = struct {
    /// First and smallest: a `{user}`-only run touches this and the head of `buf` on one page.
    create_failed: bool,
    buf: [file_len_max]u8,
    /// The options of the file `load` reads; `Parsed.settings` points here or at
    /// `default_settings`. Written only when the file names an option key.
    settings: format.Settings,

    /// Reads `home ++ path_suffix`, writing the default file there when it is missing. Options
    /// before the format line are parsed into `settings`; a file without a format line uses the
    /// default format. A bad value warns through `sink` and keeps the key's default instead of
    /// failing (see `parse_options`). The result may point into `self`.
    pub fn load(self: *Config, home: ?[]const u8, sink: anytype) Error!Parsed {
        self.create_failed = false;
        const parts = .{ home orelse return default(), path_suffix };
        const path = out.join_z(&self.buf, &parts) orelse return default();
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| {
            switch (err) {
                error.FileNotFound => self.create_failed = !create(&self.buf, path.len),
                error.OpenFailed => return error.ConfigUnreadable,
            }
            return default();
        };
        defer sys.close(fd);
        const len = sys.read(fd, &self.buf) catch return error.ConfigUnreadable;
        if (len == self.buf.len) return error.ConfigTooLarge;
        const text = self.buf[0..len];
        // Options parse before `extract_format`, which compacts the buffer in place.
        const applied = parse_options(text, sink, &self.settings);
        return .{
            .format = extract_format(text) orelse default_format,
            .settings = if (applied) &self.settings else &default_settings,
        };
    }
};

/// The embedded default file, whose options and tags the comptime blocks above have checked.
fn default() Parsed {
    return .{ .format = default_format, .settings = &default_settings };
}

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
/// on an older binary; a known key with an invalid VALUE warns one line through `sink` and keeps
/// the key's current value (its default unless an earlier line set it) — an old config with a
/// stray bad line still renders. Lines after the format line are template text and never options:
/// a future option can not eat someone's output. One trailing `\r` per line goes first, so a CRLF
/// config parses like an LF one while a quoted value that really ends in `\r` keeps it. Returns
/// whether `settings` was written; false means the file defines no option and `default_settings`
/// applies untouched.
pub fn parse_options(text: []const u8, sink: anytype, settings: *format.Settings) bool {
    var applied = false;
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        // Trim the start only: a separator or text variable may end in spaces on purpose.
        var line = mem.trimStart(u8, text[line_start..line_end], &std.ascii.whitespace);
        line_start = line_end + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        if (mem.startsWith(u8, line, format_key)) break;
        option(line, sink, &applied, settings);
    }
    return applied;
}

fn option(line: []const u8, sink: anytype, applied: *bool, settings: *format.Settings) void {
    const eq = mem.findScalar(u8, line, '=') orelse return;
    const key = mem.trim(u8, line[0..eq], &std.ascii.whitespace);
    var value: []const u8 = line[eq + 1 ..];
    if (value.len > 0 and value[0] == ' ') value = value[1..];
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1]; // quotes keep leading and trailing spaces
    }
    const known = mem.eql(u8, key, "units") or mem.eql(u8, key, "precision") or
        mem.eql(u8, key, "sep.disk") or mem.eql(u8, key, "sep.gpu") or
        mem.startsWith(u8, key, "var.") or mem.startsWith(u8, key, "color.");
    if (!known) return; // unknown keys are ignored: a config from a newer lifetch keeps working
    if (!applied.*) {
        settings.* = .{}; // a file that names a key owns its settings from here on
        applied.* = true;
    }
    if (mem.eql(u8, key, "units")) {
        const unit = out.parse_unit(mem.trim(u8, value, &std.ascii.whitespace)) orelse return sink.warn(line);
        settings.opts.unit = unit;
    } else if (mem.eql(u8, key, "precision")) {
        const digits = mem.trim(u8, value, &std.ascii.whitespace);
        const n = std.fmt.parseInt(u8, digits, 10) catch return sink.warn(line);
        if (n > 4) return sink.warn(line); // out.Opts accepts 0..=4
        settings.opts.precision = n;
    } else if (mem.eql(u8, key, "sep.disk")) {
        if (!settings.sep_disk.set(value)) return sink.warn(line);
    } else if (mem.eql(u8, key, "sep.gpu")) {
        if (!settings.sep_gpu.set(value)) return sink.warn(line);
    } else if (mem.startsWith(u8, key, "var.")) {
        const name = key["var.".len..];
        if (name.len == 0 or name.len > format.var_name_max) return sink.warn(line);
        settings.palette.put_text(name, value) catch return sink.warn(line);
    } else if (mem.startsWith(u8, key, "color.")) {
        const name = key["color.".len..];
        if (name.len == 0 or name.len > format.var_name_max) return sink.warn(line);
        const color = format.parse_color_value(value) orelse return sink.warn(line);
        settings.palette.put_color(name, color) catch return sink.warn(line);
    }
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
        out.copy(text[len..][0..part_len], text[part_start..][0..part_len]);
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
    var warnings: Warnings = .{};
    var settings: format.Settings = undefined;
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
    try std.testing.expect(parse_options(text, &warnings, &settings));
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
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
    var warnings: Warnings = .{};
    var settings: format.Settings = undefined;
    try std.testing.expect(parse_options("var.label = ram:  \nsep.disk = \"  \"\nformat = x", &warnings, &settings));
    try std.testing.expectEqualStrings("ram:  ", settings.palette.text("label").?);
    try std.testing.expectEqualStrings("  ", settings.sep_disk.slice());
}

test "parse_options: a bad value warns and keeps the key's value, never failing" {
    var warnings: Warnings = .{};
    var settings: format.Settings = undefined;
    try std.testing.expect(parse_options("units = q\nformat = x", &warnings, &settings));
    try std.testing.expectEqual(out.Unit.auto, settings.opts.unit); // the default
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expectEqualStrings("units = q", warnings.lines[0]);

    warnings = .{};
    var precision: format.Settings = undefined;
    try std.testing.expect(parse_options("precision = 9\nprecision = x\nformat = x", &warnings, &precision));
    try std.testing.expectEqual(@as(u8, 1), precision.opts.precision); // both fell back
    try std.testing.expectEqual(@as(usize, 2), warnings.len);
    try std.testing.expectEqualStrings("precision = 9", warnings.lines[0]);
    try std.testing.expectEqualStrings("precision = x", warnings.lines[1]);

    // An earlier valid definition survives a later bad one.
    warnings = .{};
    var earlier: format.Settings = undefined;
    try std.testing.expect(parse_options("precision = 3\nprecision = 9\nformat = x", &warnings, &earlier));
    try std.testing.expectEqual(@as(u8, 3), earlier.opts.precision);
    try std.testing.expectEqualStrings("precision = 9", warnings.lines[0]);

    warnings = .{};
    var palette: format.Settings = undefined;
    try std.testing.expect(parse_options(
        \\color.a = nope
        \\var. = 1
        \\var.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx = 1
        \\sep.disk = x y z 4567890123456789012345678901234567890123456789012345678901234567890
        \\format = x
    , &warnings, &palette));
    try std.testing.expectEqual(@as(usize, 4), warnings.len); // 33 > var_name_max
    try std.testing.expect(palette.palette.color("a") == null);
    try std.testing.expectEqual(out.Unit.auto, palette.opts.unit);

    // First definition wins and is not a warning.
    warnings = .{};
    var first: format.Settings = undefined;
    try std.testing.expect(parse_options("var.a = 1\nvar.a = 2\nformat = x", &warnings, &first));
    try std.testing.expectEqualStrings("1", first.palette.text("a").?);
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "parse_options: CRLF lines parse like LF ones" {
    var warnings: Warnings = .{};
    var settings: format.Settings = undefined;
    try std.testing.expect(parse_options(
        "units = g\r\nprecision = 3\r\nsep.disk = \" | \"\r\nvar.label = ram:\r\nformat = {@label}\r\n",
        &warnings,
        &settings,
    ));
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
    try std.testing.expectEqual(out.Unit.g, settings.opts.unit);
    try std.testing.expectEqual(@as(u8, 3), settings.opts.precision);
    try std.testing.expectEqualStrings(" | ", settings.sep_disk.slice()); // the '\r' is gone
    try std.testing.expectEqualStrings("ram:", settings.palette.text("label").?);
}

test "parse_options: a file with no options leaves settings untouched" {
    var warnings: Warnings = .{};
    var settings: format.Settings = undefined;
    try std.testing.expect(!parse_options("# just a comment\nformat = {user}\n", &warnings, &settings));
    try std.testing.expect(!parse_options("bogus = 1\nformat = {user}", &warnings, &settings));
    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "load: end to end with a CRLF options file and a non-fatal bad value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = tmp.dir.createDirPathOpen(io, ".config/lifetch", .{}) catch unreachable;
    dir.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".config/lifetch/config",
        .data = "units = g\r\nsep.disk = \" | \"\r\nprecision = high\r\nvar.label = ram:\r\nformat = {@label}{mem}\r\n",
    });
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var warnings: Warnings = .{};
    var config: Config = undefined;
    const parsed = try config.load(home, &warnings);
    try std.testing.expectEqualStrings("{@label}{mem}", parsed.format);
    try std.testing.expect(parsed.settings == &config.settings); // the file defines options
    try std.testing.expectEqual(out.Unit.g, parsed.settings.opts.unit);
    try std.testing.expectEqualStrings(" | ", parsed.settings.sep_disk.slice()); // CRLF is gone
    try std.testing.expectEqualStrings("ram:", parsed.settings.palette.text("label").?);
    try std.testing.expectEqual(@as(u8, 1), parsed.settings.opts.precision); // the bad value fell back
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expectEqualStrings("precision = high", warnings.lines[0]);
    try std.testing.expect(!config.create_failed);

    // A file with no options points at the shared comptime default instead of a per-run copy.
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/lifetch/config", .data = "format = {user}\n" });
    var quiet: Warnings = .{};
    var plain: Config = undefined;
    const parsed_plain = try plain.load(home, &quiet);
    try std.testing.expect(parsed_plain.settings == &default_settings);
    try std.testing.expectEqual(@as(usize, 0), quiet.len);
}

test "parse_options: the default file parses clean" {
    try std.testing.expectEqual(out.Unit.auto, default_settings.opts.unit);
    try std.testing.expectEqual(@as(u8, 1), default_settings.opts.precision);
}

test "default_format: the shipped config's format" {
    try std.testing.expect(mem.startsWith(u8, default_format, "{rgb(108,108,108)}[ {/}"));
    try std.testing.expect(mem.find(u8, default_format, "Lifetch Configuration") == null);
}
