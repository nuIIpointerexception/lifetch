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

    fn readEnviron() ![]const u8 {
        var environ_buf: [4096]u8 = undefined;
        const file = try fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only });
        defer file.close();

        const bytes_read = file.readAll(&environ_buf) catch return error.EnvironReadFailed;
        return environ_buf[0..bytes_read];
    }

    pub fn init(allocator: std.mem.Allocator) SessionError!Session {
        const logger = log.ScopedLogger.init("session");

        const environ_content = try readEnviron();

        var desktop_value: []const u8 = "unknown";
        var display_value: []const u8 = "tty";

        if (utils.getEnvValue(environ_content, desktop_prefix)) |value| {
            if (value.len > 0) desktop_value = value;
        }

        if (utils.getEnvValue(environ_content, wayland_prefix)) |value| {
            if (value.len > 0) display_value = "wayland";
        } else if (utils.getEnvValue(environ_content, display_prefix)) |value| {
            if (value.len > 0) display_value = "x11";
        }

        return Session{
            .desktop = try allocator.dupe(u8, desktop_value),
            .display_server = try allocator.dupe(u8, display_value),
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
