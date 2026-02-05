const std = @import("std");
const Io = std.Io;
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

    pub fn init(allocator: std.mem.Allocator, io: Io) HostError!Host {
        var logger = log.ScopedLogger.init("host");
        var hostname_buf: [max_hostname_len]u8 = undefined;

        const hostname_file = Io.Dir.openFileAbsolute(io, "/etc/hostname", .{}) catch |err| {
            logger.err("Failed to read hostname: {}", .{err});
            return HostError.HostnameReadFailed;
        };

        const hostname_len = Io.File.readPositionalAll(hostname_file, io, &hostname_buf, 0) catch |err| {
            logger.err("Failed to read hostname content: {}", .{err});
            return HostError.HostnameReadFailed;
        };

        const trimmed_hostname = mem.trimEnd(u8, hostname_buf[0..hostname_len], "\n");
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
