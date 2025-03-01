const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_hostname_len = 64;

pub const HostError = error{
    HostnameReadFailed,
    BufferTooSmall,
};

pub const Host = struct {
    hostname: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator) HostError!Host {
        var logger = log.ScopedLogger.init("host");
        var hostname_buf: [max_hostname_len]u8 = undefined;

        const hostname_file = fs.cwd().openFile("/etc/hostname", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to read hostname: {}", .{err});
            return HostError.HostnameReadFailed;
        };
        defer hostname_file.close();

        const hostname_len = hostname_file.readAll(&hostname_buf) catch |err| {
            logger.err("Failed to read hostname content: {}", .{err});
            return HostError.HostnameReadFailed;
        };

        const trimmed_hostname = mem.trimRight(u8, hostname_buf[0..hostname_len], "\n");
        const duped_hostname = allocator.dupe(u8, trimmed_hostname) catch |err| {
            logger.err("Failed to allocate hostname: {}", .{err});
            return HostError.HostnameReadFailed;
        };

        return Host{
            .hostname = duped_hostname,
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Host) void {
        self.allocator.free(self.hostname);
    }

    pub fn formatComponent(self: Host, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        return utils.formatReplace(allocator, input, "host", self.hostname);
    }
};

comptime {
    if (max_hostname_len > 64) @compileError("Hostname buffer too large");
    if (!std.math.isPowerOfTwo(max_hostname_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
