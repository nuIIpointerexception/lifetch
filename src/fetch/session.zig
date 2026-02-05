const std = @import("std");
const process = std.process;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const SessionError = error{
    SessionDetectionFailed,
} || std.mem.Allocator.Error;

pub const Session = struct {
    desktop: []const u8,
    display_server: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator, environ: process.Environ) SessionError!Session {
        const logger = log.ScopedLogger.init("session");

        const desktop = if (process.Environ.getPosix(environ, "XDG_CURRENT_DESKTOP")) |de|
            try allocator.dupe(u8, de)
        else
            try allocator.dupe(u8, "unknown");

        const display_server = if (process.Environ.getPosix(environ, "WAYLAND_DISPLAY")) |_|
            try allocator.dupe(u8, "wayland")
        else if (process.Environ.getPosix(environ, "DISPLAY")) |_|
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
        const de_exists = std.mem.indexOf(u8, input, "{de}") != null;
        const session_exists = std.mem.indexOf(u8, input, "{session}") != null;

        if (!de_exists and !session_exists) {
            return allocator.dupe(u8, input);
        }

        if (de_exists and !session_exists) {
            return utils.formatReplace(allocator, input, "de", self.desktop);
        }

        if (!de_exists and session_exists) {
            return utils.formatReplace(allocator, input, "session", self.display_server);
        }

        var ctx = utils.FormatContext.init(allocator);
        defer ctx.deinit();

        try ctx.add("de", self.desktop);
        try ctx.add("session", self.display_server);

        return ctx.format(input);
    }
};
