const std = @import("std");
const print = std.debug.print;

pub fn main() void {
    print("Hello from Zig!\n", .{});
}

test "assertion" {
    try std.testing.expectEqual(5, 2 + 3);
}
