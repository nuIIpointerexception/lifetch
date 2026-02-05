const std = @import("std");
const Io = std.Io;
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

    const pkg_paths = [_]struct { path: []const u8, name: []const u8, count_files: bool }{
        .{ .path = "/var/lib/pacman/local", .name = "pacman", .count_files = false },
        .{ .path = "/var/db/xbps", .name = "xbps", .count_files = true },
        .{ .path = "/var/db/pkg", .name = "portage", .count_files = false },
        .{ .path = "/var/lib/dpkg/info", .name = "dpkg", .count_files = false },
        .{ .path = "/var/lib/rpm", .name = "rpm", .count_files = false },
        .{ .path = "/var/lib/flatpak/app", .name = "flatpak", .count_files = false },
        .{ .path = "/var/lib/snap", .name = "snap", .count_files = false },
    };

    pub fn init(allocator: std.mem.Allocator, io: Io) PackageError!PackageManager {
        var logger = log.ScopedLogger.init("pkg");
        var total_count: usize = 0;

        for (pkg_paths) |pkg_info| {
            if (pkg_info.count_files) {
                if (countFilesInDir(io, pkg_info.path, "-files.plist")) |count| {
                    logger.debug("Found {d} packages in {s}", .{ count, pkg_info.name });
                    total_count += count;
                } else |err| {
                    logger.debug("Failed to count packages in {s}: {}", .{ pkg_info.name, err });
                    continue;
                }
            } else {
                if (countPackagesInDir(io, pkg_info.path)) |count| {
                    logger.debug("Found {d} packages in {s}", .{ count, pkg_info.name });
                    total_count += count;
                } else |err| {
                    logger.debug("Failed to count packages in {s}: {}", .{ pkg_info.name, err });
                    continue;
                }
            }
        }

        return PackageManager{
            .pkg_count = total_count,
            .allocator = allocator,
            .logger = logger,
        };
    }

    fn countPackagesInDir(io: Io, path: []const u8) !usize {
        const dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
            return if (err == error.FileNotFound) @as(usize, 0) else err;
        };

        var count: usize = 0;
        var it = Io.Dir.iterate(dir);

        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            count += 1;
        }

        return count;
    }

    fn countFilesInDir(io: Io, path: []const u8, suffix: []const u8) !usize {
        const dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
            return if (err == error.FileNotFound) @as(usize, 0) else err;
        };

        var count: usize = 0;
        var it = Io.Dir.iterate(dir);

        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len > suffix.len and mem.endsWith(u8, entry.name, suffix)) {
                count += 1;
            }
        }

        return count;
    }

    pub fn deinit(self: *PackageManager) void {
        _ = self;
    }

    pub fn formatComponent(self: PackageManager, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&buf, "{d}", .{self.pkg_count}) catch return error.OutOfMemory;
        return utils.formatReplace(allocator, input, "pkgs", count_str);
    }
};
