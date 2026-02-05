const std = @import("std");
const process = std.process;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_username_len = 32;
pub const max_shell_len = 64;

pub const UserError = error{
    UserInfoFailed,
    BufferTooSmall,
} || std.mem.Allocator.Error;

pub const User = struct {
    username: []const u8,
    shell: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator, environ: process.Environ) UserError!User {
        const logger = log.ScopedLogger.init("user");

        const username = if (process.Environ.getPosix(environ, "USER")) |name|
            try allocator.dupe(u8, name)
        else
            try allocator.dupe(u8, "unknown");

        var shell_buf: [max_shell_len]u8 = undefined;
        const shell = if (process.Environ.getPosix(environ, "SHELL")) |sh| blk: {
            const shell_name = std.fs.path.basename(sh);
            if (shell_name.len >= shell_buf.len) return UserError.BufferTooSmall;
            @memcpy(shell_buf[0..shell_name.len], shell_name);
            break :blk try allocator.dupe(u8, shell_buf[0..shell_name.len]);
        } else try allocator.dupe(u8, "sh");

        return User{
            .username = username,
            .shell = shell,
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *User) void {
        self.allocator.free(self.username);
        self.allocator.free(self.shell);
    }

    pub fn formatComponent(self: User, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var ctx = utils.FormatContext.init(allocator);
        defer ctx.deinit();

        try ctx.add("user", self.username);
        try ctx.add("shell", self.shell);

        return ctx.format(input);
    }
};

comptime {
    if (max_username_len > 64) @compileError("Username buffer too large");
    if (max_shell_len > 128) @compileError("Shell buffer too large");
    if (!std.math.isPowerOfTwo(max_username_len)) @compileError("Buffer size must be power of two for optimal alignment");
    if (!std.math.isPowerOfTwo(max_shell_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
