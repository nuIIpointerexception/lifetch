const std = @import("std");
const err = @import("error/error.zig").err;
const Config = @import("config/ini/ini.zig").Config;

const print = std.debug.print;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = gpa.allocator();

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(global_allocator);
    defer arena.deinit();
    const path = "config.ini";
    var cfg = try Config.init(path, arena.allocator());
    defer cfg.deinit();

    std.debug.print("string: {s}\n", .{cfg.getString("test", "string").?});
    std.debug.print("boolean: {}\n", .{cfg.getBool("test", "boolean").?});
    std.debug.print("unsigned: {d}\n", .{cfg.getUnsigned("test", "unsigned").?});
    std.debug.print("float: {d}\n", .{cfg.getFloat("test", "float").?});

    err.new(4, "test error", arena.allocator());
    err.new(2, "It can even be very long!!!", arena.allocator());
    err.new(1, "It can also be on\nMultiple Lines!", arena.allocator());
}
