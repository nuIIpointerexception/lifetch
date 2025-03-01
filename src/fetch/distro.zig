const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const max_distro_len = 64;
pub const max_release_len = 256;

pub const DistroError = error{
    DistroDetectionFailed,
    ReleaseFileNotFound,
    BufferTooSmall,
    OutOfMemory,
} || fs.File.OpenError;

const ReleaseInfo = struct {
    name: []const u8,
    version: []const u8,
    id: []const u8,
};

pub const Distro = struct {
    name: []const u8,
    version: []const u8,
    id: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    const release_files = [_][]const u8{
        "/etc/os-release",
        "/usr/lib/os-release",
        "/etc/lsb-release",
    };

    const DistroFile = struct {
        path: []const u8,
        name: []const u8,
        id: []const u8,
    };

    const distro_files = [_]DistroFile{
        .{ .path = "/etc/arch-release", .name = "Arch Linux", .id = "arch" },
        .{ .path = "/etc/gentoo-release", .name = "Gentoo", .id = "gentoo" },
        .{ .path = "/etc/fedora-release", .name = "Fedora", .id = "fedora" },
        .{ .path = "/etc/debian_version", .name = "Debian", .id = "debian" },
        .{ .path = "/etc/alpine-release", .name = "Alpine", .id = "alpine" },
    };

    fn getDistroName(id: []const u8) []const u8 {
        if (mem.eql(u8, id, "arch")) return "Arch Linux";
        if (mem.eql(u8, id, "debian")) return "Debian";
        if (mem.eql(u8, id, "ubuntu")) return "Ubuntu";
        if (mem.eql(u8, id, "fedora")) return "Fedora";
        if (mem.eql(u8, id, "gentoo")) return "Gentoo";
        if (mem.eql(u8, id, "alpine")) return "Alpine";
        if (mem.eql(u8, id, "manjaro")) return "Manjaro";
        if (mem.eql(u8, id, "endeavouros")) return "EndeavourOS";
        if (mem.eql(u8, id, "void")) return "Void";
        if (mem.eql(u8, id, "nixos")) return "NixOS";
        return id;
    }

    pub fn init(allocator: std.mem.Allocator) DistroError!Distro {
        var logger = log.ScopedLogger.init("distro");
        var release_buf: [max_release_len]u8 = undefined;

        for (distro_files) |df| {
            const file = fs.cwd().openFile(df.path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            file.close();

            return Distro{
                .name = try allocator.dupe(u8, df.name),
                .version = try allocator.dupe(u8, ""),
                .id = try allocator.dupe(u8, df.id),
                .allocator = allocator,
                .logger = logger,
            };
        }

        for (release_files) |path| {
            if (readReleaseFile(allocator, path, &release_buf)) |info| {
                return Distro{
                    .name = info.name,
                    .version = info.version,
                    .id = info.id,
                    .allocator = allocator,
                    .logger = logger,
                };
            } else |_| {
                continue;
            }
        }

        logger.err("Failed to detect distribution", .{});
        return DistroError.DistroDetectionFailed;
    }

    fn readReleaseFile(allocator: std.mem.Allocator, path: []const u8, buf: []u8) !ReleaseInfo {
        const file = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const bytes_read = try file.readAll(buf);
        const content = buf[0..bytes_read];

        var name_value: ?[]const u8 = null;
        var version_value: ?[]const u8 = null;
        var id_value: ?[]const u8 = null;

        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (mem.indexOf(u8, line, "=")) |equals_pos| {
                const key = mem.trim(u8, line[0..equals_pos], " ");
                var value = mem.trim(u8, line[equals_pos + 1 ..], " ");

                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }

                if (name_value != null and version_value != null and id_value != null) break;

                if (mem.eql(u8, key, "NAME") and name_value == null) {
                    name_value = try allocator.dupe(u8, value);
                } else if (mem.eql(u8, key, "VERSION_ID") and version_value == null) {
                    version_value = try allocator.dupe(u8, value);
                } else if (mem.eql(u8, key, "ID") and id_value == null) {
                    id_value = try allocator.dupe(u8, value);
                }
            }
        }

        const id = id_value orelse try allocator.dupe(u8, "linux");
        const name = if (name_value) |n|
            n
        else
            try allocator.dupe(u8, getDistroName(id));

        return ReleaseInfo{
            .name = name,
            .version = version_value orelse try allocator.dupe(u8, ""),
            .id = id,
        };
    }

    pub fn deinit(self: *Distro) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.id);
    }

    pub fn formatComponent(self: Distro, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var ctx = utils.FormatContext.init(allocator);
        defer ctx.deinit();

        try ctx.add("distro", self.id);
        try ctx.add("distro_version", self.version);
        try ctx.add("distro_pretty", self.name);

        return ctx.format(input);
    }
};

comptime {
    if (max_distro_len > 64) @compileError("Distro name buffer too large");
    if (max_release_len > 1024) @compileError("Release file buffer too large");
    if (!std.math.isPowerOfTwo(max_distro_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
