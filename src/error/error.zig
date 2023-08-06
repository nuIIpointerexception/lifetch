const std = @import("std");
const style = @import("../format/style.zig");
const color = @import("../format/color.zig");
pub const err = struct {
    level: u8,
    message: []const u8,

    pub fn new(level: u8, message: []const u8, allocator: std.mem.Allocator) !void {
        const prefix = getPrefix(level);
        const formattedMessage = try allocator.alloc(u8, prefix.len + message.len + 2);
        defer allocator.free(formattedMessage);

        std.mem.copy(u8, formattedMessage, prefix);
        std.mem.copy(u8, formattedMessage[prefix.len..], ": ");
        std.mem.copy(u8, formattedMessage[prefix.len + 2 ..], message);

        try style.drawBorder(formattedMessage, getColor(level), allocator);
        std.os.exit(0);
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
