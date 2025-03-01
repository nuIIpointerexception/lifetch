const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const PackageError = error{
    PackageCountFailed,
    DirectoryOpenFailed,
};

pub const PackageManager = struct {
    pkg_count: usize,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    const pkg_paths = [_]struct { path: []const u8, name: []const u8 }{
        .{ .path = "/var/lib/pacman/local", .name = "pacman" },
        .{ .path = "/var/db/pkg", .name = "portage" },
        .{ .path = "/var/lib/dpkg/info", .name = "dpkg" },
        .{ .path = "/var/lib/rpm", .name = "rpm" },
        .{ .path = "/var/lib/flatpak/app", .name = "flatpak" },
        .{ .path = "/var/lib/snap", .name = "snap" },
    };

    pub fn init(allocator: std.mem.Allocator) PackageError!PackageManager {
        var logger = log.ScopedLogger.init("pkg");
        var total_count: usize = 0;

        for (pkg_paths) |pkg_info| {
            if (countPackagesInDir(pkg_info.path)) |count| {
                logger.debug("Found {d} packages in {s}", .{ count, pkg_info.name });
                total_count += count;
            } else |err| {
                logger.debug("Failed to count packages in {s}: {}", .{ pkg_info.name, err });
                continue;
            }
        }

        return PackageManager{
            .pkg_count = total_count,
            .allocator = allocator,
            .logger = logger,
        };
    }

    fn countPackagesInDir(path: []const u8) !usize {
        var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            return if (err == error.FileNotFound) @as(usize, 0) else err;
        };
        defer dir.close();

        var count: usize = 0;
        var it = dir.iterate();

        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;

            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            count += 1;
        }

        return count;
    }

    pub fn deinit(self: *PackageManager) void {
        _ = self;
    }

    pub fn formatComponent(self: PackageManager, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var buf: [16]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&buf, "{d}", .{self.pkg_count});
        return utils.formatReplace(allocator, input, "pkgs", count_str);
    }
};
