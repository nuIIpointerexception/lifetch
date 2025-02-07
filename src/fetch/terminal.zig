const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_term_len = 32;

pub const TerminalError = error{
    TerminalDetectionFailed,
    EnvironReadFailed,
    BufferTooSmall,
} || std.mem.Allocator.Error;

pub const Terminal = struct {
    name: []const u8,
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

        const terminal_name = if (utils.getEnvValue(environ_content, term_program_prefix)) |name| blk: {
            const clean_name = if (mem.eql(u8, name, "WarpTerminal"))
                "warp"
            else
                name;
            break :blk try allocator.dupe(u8, clean_name);
        } else if (utils.getEnvValue(environ_content, term_prefix)) |name| blk: {
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
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.allocator.free(self.name);
    }

    pub fn formatComponent(self: Terminal, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        return utils.replaceAlloc(allocator, input, "{term}", self.name);
    }
};

comptime {
    if (max_term_len > 64) @compileError("Terminal name buffer too large");
    if (!std.math.isPowerOfTwo(max_term_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
