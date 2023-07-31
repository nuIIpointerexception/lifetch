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

    var fetchText: []const u8 = cfg.get("general", "fetchText").?;

    std.debug.print("{s}\n", .{fetchText});
}
