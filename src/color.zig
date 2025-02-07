const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

pub const ColorSupport = struct {
    truecolor: bool = false,
    color256: bool = false,
    basic: bool = false,

    pub fn init() ColorSupport {
        var self = ColorSupport{};

        if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLORTERM")) |colorterm| {
            defer std.heap.page_allocator.free(colorterm);
            self.truecolor = std.mem.eql(u8, colorterm, "truecolor") or
                std.mem.eql(u8, colorterm, "24bit");
        } else |_| {}

        if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM")) |term| {
            defer std.heap.page_allocator.free(term);
            self.color256 = std.mem.indexOf(u8, term, "256color") != null;
            self.basic = std.mem.indexOf(u8, term, "color") != null or
                self.color256 or self.truecolor;
        } else |_| {}

        if (std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR")) |_| {
            self.truecolor = false;
            self.color256 = false;
            self.basic = false;
        } else |_| {}

        return self;
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

    pub inline fn bright(self: Color) u8 {
        return switch (self) {
            .reset => 0,
            else => @intFromEnum(self) + 60,
        };
    }

    pub inline fn ansiSequence(self: Color) []const u8 {
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

    pub inline fn format(
        self: Color,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(self.ansiSequence());
    }

    pub inline fn fg(self: Color) Formatter {
        return .{ .kind = .basic_fg, .code = @intFromEnum(self) };
    }

    pub inline fn bg(self: Color) Formatter {
        return .{ .kind = .basic_bg, .code = @intFromEnum(self) + 10 };
    }

    pub inline fn bright_fg(self: Color) Formatter {
        return .{ .kind = .basic_fg, .code = self.bright() };
    }

    pub inline fn bright_bg(self: Color) Formatter {
        return .{ .kind = .basic_bg, .code = self.bright() + 10 };
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

var color_support: ?ColorSupport = null;

pub fn getColorSupport() ColorSupport {
    if (color_support) |cs| {
        return cs;
    }
    color_support = ColorSupport.init();
    return color_support.?;
}
