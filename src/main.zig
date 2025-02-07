const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const fetch = @import("fetch/root.zig");
const fs = std.fs;

fn runFetch(writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        return err;
    };
    defer allocator.free(home_dir);

    const environ_file = fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only }) catch |err| {
        return err;
    };
    environ_file.close();

    var fetch_info = fetch.Fetch.init(allocator) catch |err| {
        try writer.print("Error initializing fetch: {}\n", .{err});
        return err;
    };
    defer fetch_info.deinit();

    try writer.print("{s}", .{fetch_info});
}

fn timeIt(comptime fun: anytype, args: anytype) !void {
    if (builtin.mode == .Debug) {
        const start = time.nanoTimestamp();
        try @call(.auto, fun, args);
        const end = time.nanoTimestamp();

        const elapsed_ns = @as(f64, @floatFromInt(end - start));
        const stdout = std.io.getStdOut().writer();
        try stdout.print("\nfetch took {d:.3}ms\n", .{elapsed_ns / 1_000_000.0});
    } else {
        try @call(.auto, fun, args);
    }
}

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    timeIt(runFetch, .{stdout}) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Fatal error: {}\n", .{err});
        try bw.flush();
        return err;
    };
    try bw.flush();
}
