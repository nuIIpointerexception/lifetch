const std = @import("std");
const Io = std.Io;
const process = std.process;
const mem = std.mem;

const color = @import("../color.zig");
const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_term_len = 32;

pub const TerminalError = error{
    TerminalDetectionFailed,
    BufferTooSmall,
} || std.mem.Allocator.Error;

pub const ColorSupport = struct {
    truecolor: bool = false,
    color256: bool = false,
    basic: bool = false,

    fn readTermInfo(io: Io, term: []const u8) !bool {
        if (term.len == 0) return false;

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/usr/share/terminfo/{c}/{s}", .{ term[0], term }) catch return false;

        _ = Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };

        return true;
    }

    fn parseColorTag(tag: []const u8) ?color.Color {
        return color.ColorSupport.parseColorTag(tag);
    }

    fn parseStyleTag(tag: []const u8) ?[]const u8 {
        return color.ColorSupport.parseStyleTag(tag);
    }

    fn parseRgbTag(tag: []const u8) !color.Rgb {
        return color.ColorSupport.parseRgbTag(tag);
    }

    pub fn init(io: Io, environ: process.Environ) ColorSupport {
        var self = ColorSupport{};

        if (process.Environ.getPosix(environ, "NO_COLOR")) |value| {
            if (value.len > 0) {
                return self;
            }
        }

        if (process.Environ.getPosix(environ, "COLORTERM")) |value| {
            if (std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit")) {
                self.truecolor = true;
                self.basic = true;
            }
        }

        if (process.Environ.getPosix(environ, "TERM")) |term| {
            const known_color_terms = [_][]const u8{
                "linux", "xterm", "rxvt", "screen", "tmux", "vt100", "vt220",
                "ansi", "cygwin", "putty", "konsole", "gnome", "alacritty",
                "kitty", "foot", "wezterm", "st", "urxvt",
            };

            for (known_color_terms) |known| {
                if (std.mem.startsWith(u8, term, known)) {
                    self.basic = true;
                    break;
                }
            }

            self.color256 = std.mem.indexOf(u8, term, "256color") != null;
            if (self.color256) self.basic = true;

            if (!self.basic) {
                if (readTermInfo(io, term)) |has_colors| {
                    self.basic = has_colors;
                } else |_| {
                    self.basic = std.mem.indexOf(u8, term, "color") != null or self.truecolor;
                }
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

const known_terminals = [_][]const u8{
    "foot", "alacritty", "kitty", "wezterm", "konsole", "gnome-terminal",
    "xfce4-terminal", "terminator", "tilix", "st", "urxvt", "rxvt",
    "xterm", "mate-terminal", "lxterminal", "qterminal", "terminology",
    "sakura", "guake", "tilda", "yakuake", "cool-retro-term",
};

fn detectParentTerminal(io: Io) !?[]const u8 {
    const stat_file = Io.Dir.openFileAbsolute(io, "/proc/self/stat", .{}) catch return null;
    defer stat_file.close(io);
    var stat_buf: [256]u8 = undefined;
    const stat_len = Io.File.readPositionalAll(stat_file, io, &stat_buf, 0) catch return null;
    const stat_content = stat_buf[0..stat_len];

    const close_paren = mem.lastIndexOfScalar(u8, stat_content, ')') orelse return null;
    const after_paren = stat_content[close_paren + 2 ..];
    var iter = mem.splitScalar(u8, after_paren, ' ');
    _ = iter.next();
    const ppid_str = iter.next() orelse return null;

    var comm_path_buf: [64]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{s}/comm", .{ppid_str}) catch return null;

    const comm_file = Io.Dir.openFileAbsolute(io, comm_path, .{}) catch return null;
    defer comm_file.close(io);
    var comm_buf: [64]u8 = undefined;
    const comm_len = Io.File.readPositionalAll(comm_file, io, &comm_buf, 0) catch return null;
    const comm = mem.trimEnd(u8, comm_buf[0..comm_len], "\n");

    for (known_terminals) |term| {
        if (mem.eql(u8, comm, term)) {
            return term;
        }
    }

    if (mem.eql(u8, comm, "fish") or mem.eql(u8, comm, "bash") or
        mem.eql(u8, comm, "zsh") or mem.eql(u8, comm, "sh"))
    {
        var gstat_path_buf: [64]u8 = undefined;
        const gstat_path = std.fmt.bufPrint(&gstat_path_buf, "/proc/{s}/stat", .{ppid_str}) catch return null;

        const gstat_file = Io.Dir.openFileAbsolute(io, gstat_path, .{}) catch return null;
        defer gstat_file.close(io);
        var gstat_buf: [256]u8 = undefined;
        const gstat_len = Io.File.readPositionalAll(gstat_file, io, &gstat_buf, 0) catch return null;
        const gstat_content = gstat_buf[0..gstat_len];

        const gclose_paren = mem.lastIndexOfScalar(u8, gstat_content, ')') orelse return null;
        const gafter_paren = gstat_content[gclose_paren + 2 ..];
        var giter = mem.splitScalar(u8, gafter_paren, ' ');
        _ = giter.next();
        const gppid_str = giter.next() orelse return null;

        var gcomm_path_buf: [64]u8 = undefined;
        const gcomm_path = std.fmt.bufPrint(&gcomm_path_buf, "/proc/{s}/comm", .{gppid_str}) catch return null;

        const gcomm_file = Io.Dir.openFileAbsolute(io, gcomm_path, .{}) catch return null;
        defer gcomm_file.close(io);
        var gcomm_buf: [64]u8 = undefined;
        const gcomm_len = Io.File.readPositionalAll(gcomm_file, io, &gcomm_buf, 0) catch return null;
        const gcomm = mem.trimEnd(u8, gcomm_buf[0..gcomm_len], "\n");

        for (known_terminals) |term| {
            if (mem.eql(u8, gcomm, term)) {
                return term;
            }
        }
    }

    return null;
}

pub const Terminal = struct {
    name: []const u8,
    color_support: ColorSupport,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator, io: Io, environ: process.Environ) TerminalError!Terminal {
        const logger = log.ScopedLogger.init("terminal");

        const term_name = process.Environ.getPosix(environ, "TERM");
        const term_program = process.Environ.getPosix(environ, "TERM_PROGRAM");

        const parent_term = detectParentTerminal(io) catch null;

        const terminal_name = if (term_program) |name| blk: {
            const clean_name = if (mem.eql(u8, name, "WarpTerminal"))
                "warp"
            else
                name;
            break :blk try allocator.dupe(u8, clean_name);
        } else if (parent_term) |name| blk: {
            break :blk try allocator.dupe(u8, name);
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
            .color_support = ColorSupport.init(io, environ),
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
