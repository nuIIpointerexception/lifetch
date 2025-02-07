const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const SessionError = error{
    SessionDetectionFailed,
    EnvironReadFailed,
} || std.mem.Allocator.Error;

pub const Session = struct {
    desktop: []const u8,
    display_server: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    const desktop_prefix = "XDG_CURRENT_DESKTOP=";
    const display_prefix = "DISPLAY=";
    const wayland_prefix = "WAYLAND_DISPLAY=";

    pub fn init(allocator: std.mem.Allocator) SessionError!Session {
        var logger = log.ScopedLogger.init("session");

        const environ_file = fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to open environ: {}", .{err});
            return SessionError.EnvironReadFailed;
        };
        defer environ_file.close();

        var environ_buf: [2048]u8 = undefined;
        const bytes_read = environ_file.readAll(&environ_buf) catch |err| {
            logger.err("Failed to read environ: {}", .{err});
            return SessionError.EnvironReadFailed;
        };
        const environ_content = environ_buf[0..bytes_read];

        const desktop = if (utils.getEnvValue(environ_content, desktop_prefix)) |de|
            try allocator.dupe(u8, de)
        else
            try allocator.dupe(u8, "unknown");

        const display_server = if (utils.getEnvValue(environ_content, wayland_prefix)) |_|
            try allocator.dupe(u8, "wayland")
        else if (utils.getEnvValue(environ_content, display_prefix)) |_|
            try allocator.dupe(u8, "x11")
        else
            try allocator.dupe(u8, "tty");

        return Session{
            .desktop = desktop,
            .display_server = display_server,
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.desktop);
        self.allocator.free(self.display_server);
    }

    pub fn formatComponent(self: Session, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = try utils.replaceAlloc(allocator, input, "{de}", self.desktop);
        result = try utils.replaceAlloc(allocator, result, "{session}", self.display_server);
        return result;
    }
};
