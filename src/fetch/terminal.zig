const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const builtin = @import("builtin");

const color = @import("../color.zig");
const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_term_len = 32;

pub const TerminalError = error{
    TerminalDetectionFailed,
    EnvironReadFailed,
    BufferTooSmall,
} || std.mem.Allocator.Error;

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

    fn parseColorTag(tag: []const u8) ?color.Color {
        return color.ColorSupport.parseColorTag(tag);
    }

    fn parseStyleTag(tag: []const u8) ?[]const u8 {
        return color.ColorSupport.parseStyleTag(tag);
    }

    fn parseRgbTag(tag: []const u8) !color.Rgb {
        return color.ColorSupport.parseRgbTag(tag);
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
        const len = text.len;

        while (i < len) {
            if (text[i] == '{' and i + 1 < len) {
                const start_idx = i;
                const end_idx = std.mem.indexOfScalarPos(u8, text, i, '}') orelse {
                    try writer.writeByte(text[i]);
                    i += 1;
                    continue;
                };

                const tag = text[i + 1 .. end_idx];

                if (tag.len > 0 and tag[0] == '/') {
                    try writer.writeAll("\x1b[0m");
                    i = end_idx + 1;
                    continue;
                }

                var processed = false;

                if (std.mem.startsWith(u8, tag, "rgb(")) {
                    if (self.truecolor) {
                        if (ColorSupport.parseRgbTag(tag)) |rgb| {
                            try writer.print("\x1b[38;2;{};{};{}m", .{ rgb.r, rgb.g, rgb.b });
                            processed = true;
                        } else |_| {}
                    }
                } else if (self.basic) {
                    if (ColorSupport.parseColorTag(tag)) |c| {
                        try writer.writeAll(c.ansiSequence());
                        processed = true;
                    }
                }

                if (!processed) {
                    if (ColorSupport.parseStyleTag(tag)) |s| {
                        try writer.writeAll(s);
                        processed = true;
                    }
                }

                if (!processed) {
                    try writer.writeAll(text[start_idx .. end_idx + 1]);
                }

                i = end_idx + 1;
            } else {
                try writer.writeByte(text[i]);
                i += 1;
            }
        }
    }
};

var color_support: ?ColorSupport = null;

pub fn getColorSupport() ColorSupport {
    return color_support orelse {
        color_support = ColorSupport.init();
        return color_support.?;
    };
}

pub const Terminal = struct {
    name: []const u8,
    color_support: ColorSupport,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    const term_prefix = "TERM=";
    const term_program_prefix = "TERM_PROGRAM=";

    pub fn init(allocator: std.mem.Allocator) TerminalError!Terminal {
        var logger = log.ScopedLogger.init("terminal");

        const environ_file = fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to open environ: {}", .{err});
            return TerminalError.EnvironReadFailed;
        };
        defer environ_file.close();

        var environ_buf: [2048]u8 = undefined;
        const bytes_read = environ_file.readAll(&environ_buf) catch |err| {
            logger.err("Failed to read environ: {}", .{err});
            return TerminalError.EnvironReadFailed;
        };
        const environ_content = environ_buf[0..bytes_read];

        var term_name: ?[]const u8 = null;
        var term_program: ?[]const u8 = null;

        var i: usize = 0;
        while (i < environ_content.len) {
            const remaining = environ_content[i..];
            if (std.mem.startsWith(u8, remaining, term_program_prefix)) {
                const value_start = i + term_program_prefix.len;
                const value_end = std.mem.indexOfScalar(u8, environ_content[value_start..], 0) orelse break;
                term_program = environ_content[value_start..(value_start + value_end)];
            } else if (std.mem.startsWith(u8, remaining, term_prefix)) {
                const value_start = i + term_prefix.len;
                const value_end = std.mem.indexOfScalar(u8, environ_content[value_start..], 0) orelse break;
                term_name = environ_content[value_start..(value_start + value_end)];
            }

            i += std.mem.indexOfScalar(u8, environ_content[i..], 0) orelse break;
            i += 1;
        }

        const terminal_name = if (term_program) |name| blk: {
            const clean_name = if (mem.eql(u8, name, "WarpTerminal"))
                "warp"
            else
                name;
            break :blk try allocator.dupe(u8, clean_name);
        } else if (term_name) |name| blk: {
            const clean_name = if (mem.startsWith(u8, name, "xterm"))
                "xterm"
            else if (mem.startsWith(u8, name, "rxvt"))
                "rxvt"
            else if (mem.startsWith(u8, name, "screen"))
                "screen"
            else if (mem.startsWith(u8, name, "tmux"))
                "tmux"
            else
                name;
            break :blk try allocator.dupe(u8, clean_name);
        } else try allocator.dupe(u8, "unknown");

        return Terminal{
            .name = terminal_name,
            .color_support = getColorSupport(),
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.allocator.free(self.name);
    }

    pub fn formatComponent(self: Terminal, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        return utils.formatReplace(allocator, input, "term", self.name);
    }

    pub fn formatText(self: *const Terminal, text: []const u8, writer: anytype) !void {
        try self.color_support.formatText(text, writer);
    }
};

comptime {
    if (max_term_len > 64) @compileError("Terminal name buffer too large");
    if (!std.math.isPowerOfTwo(max_term_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
