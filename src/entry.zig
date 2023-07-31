const std = @import("std");
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

    std.debug.print("{s}\n", .{cfg.getString("general", "fetchText").?});
    std.debug.print("boolean: {}\n", .{cfg.getBool("general", "boolean").?});
    std.debug.print("number: {any}\n", .{cfg.getUnsigned("general", "number")});
}
