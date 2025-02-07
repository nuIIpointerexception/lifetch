const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_username_len = 32;
pub const max_shell_len = 64;

pub const UserError = error{
    UserInfoFailed,
    EnvironReadFailed,
    BufferTooSmall,
} || std.mem.Allocator.Error;

pub const User = struct {
    username: []const u8,
    shell: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    const shell_prefix = "SHELL=";
    const user_prefix = "USER=";

    pub fn init(allocator: std.mem.Allocator) UserError!User {
        var logger = log.ScopedLogger.init("user");

        const environ_file = fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to open environ: {}", .{err});
            return UserError.EnvironReadFailed;
        };
        defer environ_file.close();

        var environ_buf: [2048]u8 = undefined;
        const bytes_read = environ_file.readAll(&environ_buf) catch |err| {
            logger.err("Failed to read environ: {}", .{err});
            return UserError.EnvironReadFailed;
        };
        const environ_content = environ_buf[0..bytes_read];

        const username = if (utils.getEnvValue(environ_content, user_prefix)) |name|
            try allocator.dupe(u8, name)
        else
            try allocator.dupe(u8, "unknown");

        var shell_buf: [max_shell_len]u8 = undefined;
        const shell = if (utils.getEnvValue(environ_content, shell_prefix)) |sh| blk: {
            const shell_name = fs.path.basename(sh);
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
        var result = try utils.replaceAlloc(allocator, input, "{user}", self.username);
        result = try utils.replaceAlloc(allocator, result, "{shell}", self.shell);
        return result;
    }
};

comptime {
    if (max_username_len > 64) @compileError("Username buffer too large");
    if (max_shell_len > 128) @compileError("Shell buffer too large");
    if (!std.math.isPowerOfTwo(max_username_len)) @compileError("Buffer size must be power of two for optimal alignment");
    if (!std.math.isPowerOfTwo(max_shell_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
