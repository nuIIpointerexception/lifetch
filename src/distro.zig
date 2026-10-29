const std = @import("std");
const mem = std.mem;

const sys = @import("sys.zig");

pub const Distro = struct {
    id: []const u8,
    name: []const u8,
};

const Marker = struct { path: [:0]const u8, distro: Distro };

const markers = [_]Marker{
    .{ .path = "/etc/arch-release", .distro = .{ .id = "arch", .name = "Arch Linux" } },
    .{ .path = "/etc/gentoo-release", .distro = .{ .id = "gentoo", .name = "Gentoo" } },
    .{ .path = "/etc/fedora-release", .distro = .{ .id = "fedora", .name = "Fedora" } },
    .{ .path = "/etc/debian_version", .distro = .{ .id = "debian", .name = "Debian" } },
    .{ .path = "/etc/alpine-release", .distro = .{ .id = "alpine", .name = "Alpine" } },
};

const display_names = [_]Distro{
    .{ .id = "arch", .name = "Arch Linux" },
    .{ .id = "debian", .name = "Debian" },
    .{ .id = "ubuntu", .name = "Ubuntu" },
    .{ .id = "fedora", .name = "Fedora" },
    .{ .id = "gentoo", .name = "Gentoo" },
    .{ .id = "alpine", .name = "Alpine" },
    .{ .id = "manjaro", .name = "Manjaro" },
    .{ .id = "endeavouros", .name = "EndeavourOS" },
    .{ .id = "void", .name = "Void" },
    .{ .id = "nixos", .name = "NixOS" },
};

pub const release_buf_len = 1024;

/// os-release first, since a derivative keeps its parent's marker file (Ubuntu ships
/// /etc/debian_version); then marker files; then lsb-release. Slices point into `buf`.
pub fn detect(buf: *[release_buf_len]u8) Distro {
    for ([_][:0]const u8{ "/etc/os-release", "/usr/lib/os-release" }) |path| {
        const content = sys.read_file(path, buf) catch continue;
        return parse(content, .{ .id = "ID", .name = "NAME" });
    }
    for (markers) |marker| {
        if (sys.access(marker.path) == .SUCCESS) return marker.distro;
    }
    const content = sys.read_file("/etc/lsb-release", buf) catch
        return .{ .id = "unknown", .name = "unknown" };
    return parse(content, .{ .id = "DISTRIB_ID", .name = "DISTRIB_DESCRIPTION" });
}

const Keys = struct { id: []const u8, name: []const u8 };

fn parse(content: []const u8, keys: Keys) Distro {
    var id: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const eq = mem.findScalar(u8, line, '=') orelse continue;
        const key = mem.trim(u8, line[0..eq], " ");
        const value = unquote(mem.trim(u8, line[eq + 1 ..], " "));
        if (id == null and mem.eql(u8, key, keys.id)) id = value;
        if (name == null and mem.eql(u8, key, keys.name)) name = value;
        if (id != null and name != null) break;
    }
    const id_found = id orelse "linux";
    return .{ .id = id_found, .name = name orelse display_name(id_found) };
}

fn unquote(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    const quote = value[0];
    if (quote != '"' and quote != '\'') return value;
    if (value[value.len - 1] != quote) return value;
    return value[1 .. value.len - 1];
}

fn display_name(id: []const u8) []const u8 {
    for (display_names) |known| {
        if (mem.eql(u8, id, known.id)) return known.name;
    }
    return id;
}

test "parse: os-release keys, quotes and fallbacks" {
    const arch = parse(
        \\NAME="Arch Linux"
        \\PRETTY_NAME="Arch Linux"
        \\ID=arch
        \\# ID=ignored
    , .{ .id = "ID", .name = "NAME" });
    try std.testing.expectEqualStrings("arch", arch.id);
    try std.testing.expectEqualStrings("Arch Linux", arch.name);

    const bare = parse("ID='void'\n", .{ .id = "ID", .name = "NAME" });
    try std.testing.expectEqualStrings("void", bare.id);
    try std.testing.expectEqualStrings("Void", bare.name);

    const empty = parse("", .{ .id = "ID", .name = "NAME" });
    try std.testing.expectEqualStrings("linux", empty.id);
    try std.testing.expectEqualStrings("linux", empty.name);

    const lsb = parse(
        \\DISTRIB_ID=Ubuntu
        \\DISTRIB_DESCRIPTION="Ubuntu 24.04 LTS"
    , .{ .id = "DISTRIB_ID", .name = "DISTRIB_DESCRIPTION" });
    try std.testing.expectEqualStrings("Ubuntu", lsb.id);
    try std.testing.expectEqualStrings("Ubuntu 24.04 LTS", lsb.name);
}
