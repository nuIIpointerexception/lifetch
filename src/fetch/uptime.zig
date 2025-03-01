const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const UptimeError = error{
    UptimeReadFailed,
    BufferTooSmall,
} || std.mem.Allocator.Error || std.fmt.BufPrintError;

pub const Uptime = struct {
    seconds: u64,
    formatted: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator) UptimeError!Uptime {
        var logger = log.ScopedLogger.init("uptime");

        const uptime_file = fs.openFileAbsolute("/proc/uptime", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to open uptime: {}", .{err});
            return UptimeError.UptimeReadFailed;
        };
        defer uptime_file.close();

        var uptime_buf: [32]u8 = undefined;
        const uptime_str = uptime_file.reader().readUntilDelimiter(&uptime_buf, ' ') catch |err| {
            logger.err("Failed to read uptime: {}", .{err});
            return UptimeError.UptimeReadFailed;
        };

        const uptime_float = std.fmt.parseFloat(f64, uptime_str) catch |err| {
            logger.err("Failed to parse uptime: {}", .{err});
            return UptimeError.UptimeReadFailed;
        };

        const seconds = @as(u64, @intFromFloat(uptime_float));
        const format_buf = try allocator.alloc(u8, 64);
        defer allocator.free(format_buf);
        const formatted = try formatUptime(seconds, format_buf);
        const duped_formatted = try allocator.dupe(u8, formatted);

        return Uptime{
            .seconds = seconds,
            .formatted = duped_formatted,
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Uptime) void {
        self.allocator.free(self.formatted);
    }

    pub fn formatComponent(self: Uptime, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        return utils.formatReplace(allocator, input, "uptime", self.formatted);
    }

    fn formatUptime(seconds: u64, buf: []u8) ![]const u8 {
        const minutes = seconds / 60;
        const hours = minutes / 60;
        const days = hours / 24;

        const display_minutes = minutes % 60;
        const display_hours = hours % 24;

        if (days > 0) {
            return std.fmt.bufPrint(buf, "{d}d {d}h {d}m", .{ days, display_hours, display_minutes });
        } else if (hours > 0) {
            return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, display_minutes });
        } else {
            return std.fmt.bufPrint(buf, "{d}m", .{minutes});
        }
    }
};
