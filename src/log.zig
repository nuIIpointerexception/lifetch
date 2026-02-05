const std = @import("std");
const builtin = @import("builtin");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m",
            .info => "\x1b[32m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };
    }

    pub fn prefix(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DBG",
            .info => "INF",
            .warn => "WRN",
            .err => "ERR",
        };
    }
};

pub const ScopedLogger = struct {
    scope: []const u8,
    min_level: LogLevel = .info,
    mutex: std.Thread.Mutex = .{},
    buffer: [1024]u8 = undefined,
    enabled: bool = if (builtin.mode == .Debug) true else false,

    const Self = @This();

    pub fn init(scope: []const u8) Self {
        return .{ .scope = scope };
    }

    pub fn setLevel(self: *Self, level: LogLevel) void {
        self.min_level = level;
    }

    pub fn enable(self: *Self) void {
        self.enabled = true;
    }

    pub fn disable(self: *Self) void {
        self.enabled = false;
    }

    inline fn shouldLog(self: Self, level: LogLevel) bool {
        return self.enabled and @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    pub fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLog(level)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Use std.debug.print for logging to stderr (simple and reliable)
        std.debug.print("{s}[{s}][{s}]{s} ", .{
            level.color(),
            level.prefix(),
            self.scope,
            "\x1b[0m",
        });

        if (std.fmt.bufPrint(self.buffer[0..], fmt, args)) |msg| {
            std.debug.print("{s}\n", .{msg});
        } else |_| {
            std.debug.print(fmt ++ "\n", args);
        }
    }

    pub inline fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (builtin.mode == .Debug) {
            self.log(.debug, fmt, args);
        }
    }

    pub inline fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub inline fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub inline fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

pub var global = ScopedLogger.init("global");
