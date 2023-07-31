const std = @import("std");
const style = @import("style.zig");
const color = @import("../format/color.zig");
pub const err = struct {
    level: u8,
    message: []const u8,

    const Self = @This();

    pub fn new(level: u8, message: []const u8, allocator: std.mem.Allocator) void {
        style.border(message, getColor(level), allocator);
    }

    fn getColor(level: u8) []const u8 {
        return switch (level) {
            0 => color.GRAY,
            1 => color.YELLOW,
            2 => color.LIGHT_RED,
            else => color.RED,
        };
    }

    fn getPrefix(level: u8) []const u8 {
        return switch (level) {
            0 => "info",
            1 => "warn",
            2 => "error",
            else => "fatal",
        };
    }
};
