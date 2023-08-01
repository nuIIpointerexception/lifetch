const std = @import("std");
const style = @import("style.zig");
const color = @import("../format/color.zig");
pub const err = struct {
    level: u8,
    message: []const u8,

    pub fn new(level: u8, message: []const u8, allocator: std.mem.Allocator) void {
        const str = std.fmt.allocPrint(allocator, "{s}: {s}", .{ getPrefix(level), message }) catch message;
        style.drawBorder(str, getColor(level), allocator);
    }

    fn getColor(level: u8) []const u8 {
        return switch (level) {
            1 => color.LIGHT_GRAY,
            2 => color.YELLOW,
            3 => color.LIGHT_RED,
            else => color.RED,
        };
    }

    fn getPrefix(level: u8) []const u8 {
        return switch (level) {
            1 => "info",
            2 => "warn",
            3 => "error",
            else => "fatal",
        };
    }
};
