const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const fs = std.fs;

pub const ColorSupport = struct {
    truecolor: bool = false,
    color256: bool = false,
    basic: bool = false,

    const TermInfo = struct {
        fn readTermInfo(term: []const u8) !bool {
            if (term.len == 0) return false;

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/usr/share/terminfo/{c}/{s}", .{ term[0], term[1..] }) catch return false;

            const file = fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer file.close();

            var header_buf: [12]u8 = undefined;
            if ((try file.readAll(&header_buf)) < 12) return false;
            if (header_buf[0] != 0x1a and header_buf[1] != 0x01) return false;

            return (@as(u16, @intCast(header_buf[10])) | (@as(u16, @intCast(header_buf[11])) << 8)) > 0;
        }
    };

    fn parseColorTag(tag: []const u8) ?Color {
        return switch (tag[0]) {
            'b' => if (std.mem.eql(u8, tag, "black")) .black else if (std.mem.eql(u8, tag, "blue")) .blue else null,
            'r' => if (std.mem.eql(u8, tag, "red")) .red else null,
            'g' => if (std.mem.eql(u8, tag, "green")) .green else null,
            'y' => if (std.mem.eql(u8, tag, "yellow")) .yellow else null,
            'm' => if (std.mem.eql(u8, tag, "magenta")) .magenta else null,
            'c' => if (std.mem.eql(u8, tag, "cyan")) .cyan else null,
            'w' => if (std.mem.eql(u8, tag, "white")) .white else null,
            else => null,
        };
    }

    fn parseStyleTag(tag: []const u8) ?[]const u8 {
        return switch (tag[0]) {
            'b' => if (std.mem.eql(u8, tag, "bold")) Style.bold else if (std.mem.eql(u8, tag, "blink")) Style.blink else null,
            'd' => if (std.mem.eql(u8, tag, "dim")) Style.dim else null,
            'i' => if (std.mem.eql(u8, tag, "italic")) Style.italic else null,
            'u' => if (std.mem.eql(u8, tag, "underline")) Style.underline else null,
            'r' => if (std.mem.eql(u8, tag, "reverse")) Style.reverse else null,
            'h' => if (std.mem.eql(u8, tag, "hidden")) Style.hidden else null,
            's' => if (std.mem.eql(u8, tag, "strike")) Style.strike else null,
            else => null,
        };
    }

    fn parseRgbTag(tag: []const u8) !Rgb {
        if (!std.mem.startsWith(u8, tag, "rgb(") or !std.mem.endsWith(u8, tag, ")")) {
            return error.InvalidColorFormat;
        }

        const rgb_content = tag[4 .. tag.len - 1];
        var values: [3]u8 = undefined;
        var value_idx: usize = 0;
        var num_start: usize = 0;

        for (rgb_content, 0..) |c, i| {
            if (c == ',' or i == rgb_content.len - 1) {
                const num_end = if (i == rgb_content.len - 1) i + 1 else i;
                const num_str = std.mem.trim(u8, rgb_content[num_start..num_end], &std.ascii.whitespace);
                values[value_idx] = std.fmt.parseInt(u8, num_str, 10) catch return error.InvalidColorFormat;
                value_idx += 1;
                if (value_idx > 2) break;
                num_start = i + 1;
            }
        }

        if (value_idx != 3) return error.InvalidColorFormat;
        return Rgb.init(values[0], values[1], values[2]);
    }

    pub fn init() ColorSupport {
        var self = ColorSupport{};
        const env = os.environ;

        for (env) |entry| {
            const entry_str = std.mem.span(entry);
            if (std.mem.startsWith(u8, entry_str, "NO_COLOR=")) return self;
        }

        for (env) |entry| {
            const entry_str = std.mem.span(entry);
            if (std.mem.startsWith(u8, entry_str, "COLORTERM=")) {
                const value = entry_str["COLORTERM=".len..];
                if (std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit")) {
                    self.truecolor = true;
                    self.basic = true;
                }
                break;
            }
        }

        for (env) |entry| {
            const entry_str = std.mem.span(entry);
            if (std.mem.startsWith(u8, entry_str, "TERM=")) {
                const term = entry_str["TERM=".len..];
                if (TermInfo.readTermInfo(term)) |has_colors| {
                    if (has_colors) {
                        self.basic = true;
                        self.color256 = std.mem.indexOf(u8, term, "256color") != null;
                    }
                } else |_| {
                    self.color256 = std.mem.indexOf(u8, term, "256color") != null;
                    if (self.color256) self.basic = true;
                    if (!self.basic) {
                        self.basic = std.mem.indexOf(u8, term, "color") != null or self.truecolor;
                    }
                }
                break;
            }
        }

        return self;
    }

    pub fn formatText(self: *const ColorSupport, text: []const u8, writer: anytype) !void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') {
                const end_idx = std.mem.indexOfScalarPos(u8, text, i, '}') orelse break;
                const tag = text[i + 1 .. end_idx];

                if (std.mem.startsWith(u8, tag, "/")) {
                    try writer.writeAll("\x1b[0m");
                    i = end_idx;
                    continue;
                }

                if (std.mem.startsWith(u8, tag, "rgb(")) {
                    if (self.truecolor) {
                        const rgb = ColorSupport.parseRgbTag(tag) catch continue;
                        try writer.print("\x1b[38;2;{};{};{}m", .{ rgb.r, rgb.g, rgb.b });
                    }
                } else if (ColorSupport.parseColorTag(tag)) |c| {
                    if (self.basic) {
                        try writer.writeAll(c.ansiSequence());
                    }
                } else if (ColorSupport.parseStyleTag(tag)) |s| {
                    try writer.writeAll(s);
                } else {
                    try writer.writeAll(text[i .. end_idx + 1]);
                }
                i = end_idx;
            } else {
                try writer.writeByte(text[i]);
            }
        }
    }
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    comptime {
        if (@sizeOf(@This()) != 3) @compileError("Rgb struct must be packed for optimal memory layout");
    }

    pub fn init(r: u8, g: u8, b: u8) Rgb {
        return .{ .r = r, .g = g, .b = b };
    }

    pub inline fn fg(self: Rgb) Formatter {
        return .{ .kind = .rgb_fg, .rgb = self };
    }

    pub inline fn bg(self: Rgb) Formatter {
        return .{ .kind = .rgb_bg, .rgb = self };
    }

    pub inline fn components(self: Rgb) struct { r: u8, g: u8, b: u8 } {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }
};

pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    reset = 0,

    pub fn ansiSequence(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .reset => "\x1b[0m",
        };
    }
};

const AnsiBuffer = struct {
    const basic_fg_prefix = "\x1b[";
    const basic_bg_prefix = "\x1b[";
    const rgb_fg_prefix = "\x1b[38;2;";
    const rgb_bg_prefix = "\x1b[48;2;";
    const color256_fg_prefix = "\x1b[38;5;";
    const color256_bg_prefix = "\x1b[48;5;";
    const suffix = "m";
};

const FormatterKind = enum {
    basic_fg,
    basic_bg,
    rgb_fg,
    rgb_bg,
    color256_fg,
    color256_bg,
};

pub const Formatter = struct {
    kind: FormatterKind,
    code: u8 = 0,
    rgb: Rgb align(1) = Rgb.init(0, 0, 0),

    pub inline fn format(
        self: Formatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        switch (self.kind) {
            .basic_fg, .basic_bg => {
                const prefix = if (self.kind == .basic_fg) AnsiBuffer.basic_fg_prefix else AnsiBuffer.basic_bg_prefix;
                try writer.writeAll(prefix);
                try writer.print("{}", .{self.code});
                try writer.writeAll(AnsiBuffer.suffix);
            },
            .rgb_fg, .rgb_bg => {
                const prefix = if (self.kind == .rgb_fg) AnsiBuffer.rgb_fg_prefix else AnsiBuffer.rgb_bg_prefix;
                const components = self.rgb.components();
                try writer.writeAll(prefix);
                try writer.print("{};{};{}", .{ components.r, components.g, components.b });
                try writer.writeAll(AnsiBuffer.suffix);
            },
            .color256_fg, .color256_bg => {
                const prefix = if (self.kind == .color256_fg) AnsiBuffer.color256_fg_prefix else AnsiBuffer.color256_bg_prefix;
                try writer.writeAll(prefix);
                try writer.print("{}", .{self.code});
                try writer.writeAll(AnsiBuffer.suffix);
            },
        }
    }

    pub inline fn color256(code: u8) Formatter {
        return .{ .kind = .color256_fg, .code = code };
    }

    pub inline fn color256_bg(code: u8) Formatter {
        return .{ .kind = .color256_bg, .code = code };
    }
};

pub const Style = struct {
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const blink = "\x1b[5m";
    pub const reverse = "\x1b[7m";
    pub const hidden = "\x1b[8m";
    pub const strike = "\x1b[9m";
    pub const reset = "\x1b[0m";

    pub inline fn format(text: []const u8, style: []const u8) std.fmt.Formatter(formatFn) {
        return .{ .data = .{ .text = text, .style = style } };
    }

    const FormatData = struct { text: []const u8, style: []const u8 };

    fn formatFn(
        data: FormatData,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}{s}{s}", .{ data.style, data.text, reset });
    }
};

// Initialize color support at runtime
var color_support: ?ColorSupport = null;

pub fn getColorSupport() ColorSupport {
    return color_support orelse {
        color_support = ColorSupport.init();
        return color_support.?;
    };
}
