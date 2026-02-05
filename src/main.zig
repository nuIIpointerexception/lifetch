const std = @import("std");
const builtin = @import("builtin");
const process = std.process;
const Io = std.Io;

const log = @import("log.zig");
const fetch = @import("fetch/root.zig");

var logger = log.ScopedLogger.init("lifetch/main");

pub fn main(init: process.Init) !void {
    if (builtin.mode == .Debug) {
        logger.warn("RUNNING IN DEBUG MODE", .{});
    }

    const stdout_file = Io.File.stdout();
    var buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.Writer.initStreaming(stdout_file, init.io, &buffer);

    var fetch_info = try fetch.Fetch.init(init.gpa, init.io, init.minimal.environ);
    defer fetch_info.deinit();

    fetch_info.format(&stdout_writer.interface) catch |err| {
        logger.err("Failed to print fetch info: {}", .{err});
        return err;
    };

    stdout_writer.interface.flush() catch |err| {
        logger.err("Failed to flush stdout: {}", .{err});
        return err;
    };
}
