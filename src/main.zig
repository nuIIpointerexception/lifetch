const std = @import("std");
const time = std.time;
const builtin = @import("builtin");

const debug = @import("debug.zig");
const log = @import("log.zig");
const fetch = @import("fetch/root.zig");

var logger = log.ScopedLogger.init("lifetch/main");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

fn runFetch(writer: anytype, allocator: std.mem.Allocator) !void {
    if (builtin.mode == .Debug) {
        logger.warn("RUNNING IN DEBUG MODE", .{});
    }

    var fetch_info = try fetch.Fetch.init(allocator);
    defer fetch_info.deinit();

    try writer.print("{s}", .{fetch_info});
}

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        if (@import("builtin").os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    if (builtin.mode == .Debug) {
        logger.warn("RUNNING IN DEBUG MODE", .{});
    }

    var fetch_info = try fetch.Fetch.init(allocator);
    defer fetch_info.deinit();

    stdout.print("{s}", .{fetch_info}) catch |err| {
        logger.err("Failed to print fetch info: {}", .{err});
        return err;
    };

    try bw.flush();
}
