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

    fn readEnviron(buf: []u8) ![]const u8 {
        @setRuntimeSafety(false);
        const file = try fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only });
        defer file.close();
        return file.readAll(buf) catch return error.EnvironReadFailed;
    }

    pub fn init(allocator: std.mem.Allocator) SessionError!Session {
        @setRuntimeSafety(false);
        const logger = log.ScopedLogger.init("session");

        var environ_buf: [4096]u8 = undefined;
        const bytes_read = try readEnviron(&environ_buf);
        const environ_content = environ_buf[0..bytes_read];

        var desktop_value: []const u8 = "unknown";
        var display_value: []const u8 = "tty";

        var start: usize = 0;
        while (start < environ_content.len) {
            const end = if (mem.indexOfScalarPos(u8, environ_content, start, 0)) |e| e else environ_content.len;
            const entry = environ_content[start..end];

            if (mem.startsWith(u8, entry, desktop_prefix)) {
                desktop_value = entry[desktop_prefix.len..];
            } else if (mem.startsWith(u8, entry, wayland_prefix)) {
                display_value = "wayland";
            } else if (display_value.len == 3 and mem.startsWith(u8, entry, display_prefix)) {
                display_value = "x11";
            }
            start = end + 1;
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
