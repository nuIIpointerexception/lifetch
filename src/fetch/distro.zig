const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const hash_map = std.hash_map;
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
    pretty_name: []const u8,
    version: []const u8,
    id: []const u8,
};

pub const Distro = struct {
    pretty_name: []const u8,
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
        pretty_name: []const u8,
        id: []const u8,
    };

    const distro_files = [_]DistroFile{
        .{ .path = "/etc/arch-release", .pretty_name = "Arch Linux", .id = "arch" },
        .{ .path = "/etc/gentoo-release", .pretty_name = "Gentoo", .id = "gentoo" },
        .{ .path = "/etc/fedora-release", .pretty_name = "Fedora", .id = "fedora" },
        .{ .path = "/etc/debian_version", .pretty_name = "Debian", .id = "debian" },
        .{ .path = "/etc/alpine-release", .pretty_name = "Alpine", .id = "alpine" },
    };

    const DistroMapping = struct {
        id: []const u8,
        pretty_name: []const u8,
    };

    const distro_mappings = [_]DistroMapping{
        .{ .id = "arch", .pretty_name = "Arch Linux" },
        .{ .id = "alpine", .pretty_name = "Alpine" },
        .{ .id = "debian", .pretty_name = "Debian" },
        .{ .id = "endeavouros", .pretty_name = "EndeavourOS" },
        .{ .id = "fedora", .pretty_name = "Fedora" },
        .{ .id = "gentoo", .pretty_name = "Gentoo" },
        .{ .id = "manjaro", .pretty_name = "Manjaro" },
        .{ .id = "nixos", .pretty_name = "NixOS" },
        .{ .id = "ubuntu", .pretty_name = "Ubuntu" },
        .{ .id = "void", .pretty_name = "Void" },
    };

    fn getDistroName(id: []const u8) []const u8 {
        if (id.len == 0) return id;

        for (distro_mappings) |mapping| {
            if (id.len == mapping.id.len and mem.eql(u8, id, mapping.id)) {
                return mapping.pretty_name;
            }
        }
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
                .pretty_name = try allocator.dupe(u8, df.pretty_name),
                .version = try allocator.dupe(u8, ""),
                .id = try allocator.dupe(u8, df.id),
                .allocator = allocator,
                .logger = logger,
            };
        }

        for (release_files) |path| {
            if (readReleaseFile(allocator, path, &release_buf)) |info| {
                return Distro{
                    .pretty_name = info.pretty_name,
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

            const equals_pos = mem.indexOfScalar(u8, line, '=') orelse continue;
            if (equals_pos == 0 or equals_pos == line.len - 1) continue;

            const key = mem.trim(u8, line[0..equals_pos], " ");
            var value = mem.trim(u8, line[equals_pos + 1 ..], " ");

            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }

            if (name_value != null and version_value != null and id_value != null) break;

            switch (key[0]) {
                'N' => if (mem.eql(u8, key, "NAME") and name_value == null) {
                    name_value = try allocator.dupe(u8, value);
                },
                'V' => if (mem.eql(u8, key, "VERSION_ID") and version_value == null) {
                    version_value = try allocator.dupe(u8, value);
                },
                'I' => if (mem.eql(u8, key, "ID") and id_value == null) {
                    id_value = try allocator.dupe(u8, value);
                },
                else => continue,
            }
        }

        const id = id_value orelse try allocator.dupe(u8, "linux");
        const pretty_name = if (name_value) |n|
            n
        else
            try allocator.dupe(u8, getDistroName(id));

        return ReleaseInfo{
            .pretty_name = pretty_name,
            .version = version_value orelse try allocator.dupe(u8, ""),
            .id = id,
        };
    }

    pub fn deinit(self: *Distro) void {
        self.allocator.free(self.pretty_name);
        self.allocator.free(self.version);
        self.allocator.free(self.id);
    }

    pub fn formatComponent(self: Distro, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = try utils.replaceAlloc(allocator, input, "{distro}", self.id);
        result = try utils.replaceAlloc(allocator, result, "{distro_pretty}", self.pretty_name);
        result = try utils.replaceAlloc(allocator, result, "{distro_version}", self.version);
        return result;
    }
};

comptime {
    if (max_distro_len > 64) @compileError("Distro name buffer too large");
    if (max_release_len > 1024) @compileError("Release file buffer too large");
    if (!std.math.isPowerOfTwo(max_distro_len)) @compileError("Buffer size must be power of two for optimal alignment");
}
