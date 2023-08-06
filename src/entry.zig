const std = @import("std");
const err = @import("error/error.zig").err;
const Config = @import("config/config.zig").Config;

const print = std.debug.print;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = gpa.allocator();

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(global_allocator);
    defer arena.deinit();
    const path = "config.ini";
    var cfg = try Config.init(path, arena.allocator());
    defer cfg.deinit();

    std.debug.print("string: {s}\n", .{try cfg.getString("test", "string")});
    std.debug.print("boolean: {}\n", .{try cfg.getBool("test", "boolean")});
    std.debug.print("unsigned: {d}\n", .{try cfg.getUnsigned("test", "unsigned")});
    std.debug.print("float: {d}\n", .{try cfg.getFloat("test", "float")});
}
