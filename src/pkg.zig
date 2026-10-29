const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const join_z = @import("out.zig").join_z;
const sys = @import("sys.zig");

const Kind = union(enum) {
    dirs,
    files_with_suffix: []const u8,
    dirs_in_subdirs,
};

const Source = struct { path: [:0]const u8, kind: Kind };

const sources = [_]Source{
    .{ .path = "/var/lib/pacman/local", .kind = .dirs },
    .{ .path = "/var/db/xbps", .kind = .{ .files_with_suffix = "-files.plist" } },
    .{ .path = "/var/db/pkg", .kind = .dirs_in_subdirs },
    .{ .path = "/var/lib/dpkg/info", .kind = .{ .files_with_suffix = ".list" } },
    .{ .path = "/var/lib/flatpak/app", .kind = .dirs },
};

/// Filesystems whose directory link count is 2 plus the number of subdirectories.
const nlink_counts_subdirs = [_]u64{
    0xEF53, // ext2, ext3, ext4
    0x58465342, // xfs
    0x01021994, // tmpfs
    0xF2F52010, // f2fs
};

const dirents_buf_len = 32 * 1024;
const dirents_reads_max = 4096;

/// Null when a package database exists but could not be read to the end.
pub fn count() ?u64 {
    var total: u64 = 0;
    for (sources) |source| {
        total += switch (source.kind) {
            .dirs => count_dirs(source.path),
            else => count_entries(source.path, source.kind),
        } orelse return null;
    }
    return total;
}

/// One statx instead of a walk where the link count is exact. ext4 reports 1 once a directory
/// passes 65000 subdirectories, and that falls through to the walk.
fn count_dirs(path: [:0]const u8) ?u64 {
    var fs: u64 = undefined;
    switch (sys.fs_type(path, &fs)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return 0,
        else => return count_entries(path, .dirs),
    }
    if (mem.findScalar(u64, &nlink_counts_subdirs, fs) != null) {
        var stx: linux.Statx = undefined;
        if (sys.statx(path, .{ .NLINK = true }, &stx) == .SUCCESS and stx.nlink >= 2) {
            return stx.nlink - 2;
        }
    }
    return count_entries(path, .dirs);
}

fn count_entries(path: [:0]const u8, kind: Kind) ?u64 {
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = sys.open(path, flags, 0) catch |err| return switch (err) {
        error.FileNotFound => 0,
        error.OpenFailed => null,
    };
    defer sys.close(fd);
    return walk(fd, path, kind);
}

/// `noinline` keeps the dirent buffer out of the callers' frames, where it would spread their
/// first-touched stack pages apart; only a directory that exists pays for it.
noinline fn walk(fd: sys.fd_t, path: [:0]const u8, kind: Kind) ?u64 {
    var buf: [dirents_buf_len]u8 align(8) = undefined;
    var total: u64 = 0;
    for (0..dirents_reads_max) |_| {
        const len = sys.getdents(fd, &buf) catch return null;
        if (len == 0) return total;
        var it: Dirents = .{ .buf = buf[0..len] };
        while (it.next()) |entry| {
            total += switch (kind) {
                .dirs => @intFromBool(is_subdir(entry)),
                .files_with_suffix => |suffix| @intFromBool(entry.type == linux.DT.REG and
                    entry.name.len > suffix.len and mem.endsWith(u8, entry.name, suffix)),
                .dirs_in_subdirs => if (is_subdir(entry))
                    count_subdir(path, entry.name) orelse return null
                else
                    0,
            };
        }
    }
    return null;
}

/// Every directory but `.` and `..`, which is what the link count counts.
fn is_subdir(entry: Dirents.Entry) bool {
    if (entry.type != linux.DT.DIR) return false;
    return !mem.eql(u8, entry.name, ".") and !mem.eql(u8, entry.name, "..");
}

/// Recursion stops here: a subdirectory is counted as `.dirs`, never walked into further.
noinline fn count_subdir(path: [:0]const u8, name: [:0]const u8) ?u64 {
    var path_buf: [linux.PATH_MAX]u8 = undefined;
    const sub = join_z(&path_buf, &.{ path, "/", name }) orelse return null;
    return count_dirs(sub);
}

const Dirents = struct {
    buf: []const u8,
    pos: usize = 0,

    const Entry = struct { type: u8, name: [:0]const u8 };
    const header = @offsetOf(linux.dirent64, "name");
    const reclen_at = @offsetOf(linux.dirent64, "reclen");
    const type_at = @offsetOf(linux.dirent64, "type");

    fn next(self: *Dirents) ?Entry {
        if (self.pos >= self.buf.len) return null;
        const record = self.buf[self.pos..];
        std.debug.assert(record.len > header);
        const reclen = mem.readInt(u16, record[reclen_at..][0..2], .little);
        std.debug.assert(reclen > header and reclen <= record.len);
        self.pos += reclen;
        const name: [*:0]const u8 = @ptrCast(record[header..].ptr);
        return .{ .type = record[type_at], .name = mem.span(name) };
    }
};

test "Dirents: walks records by reclen" {
    var buf: [64]u8 align(8) = @splat(0);
    const records = [_]struct { type: u8, name: []const u8 }{
        .{ .type = linux.DT.DIR, .name = "a" },
        .{ .type = linux.DT.REG, .name = "b.list" },
    };
    var pos: usize = 0;
    for (records) |record| {
        const reclen: u16 = 32;
        mem.writeInt(u16, buf[pos + Dirents.reclen_at ..][0..2], reclen, .little);
        buf[pos + Dirents.type_at] = record.type;
        @memcpy(buf[pos + Dirents.header ..][0..record.name.len], record.name);
        pos += reclen;
    }
    var it: Dirents = .{ .buf = &buf };
    const first = it.next().?;
    try std.testing.expectEqual(linux.DT.DIR, first.type);
    try std.testing.expectEqualStrings("a", first.name);
    try std.testing.expectEqualStrings("b.list", it.next().?.name);
    try std.testing.expect(it.next() == null);
}

test "count_entries: suffix files and nested dirs; the link count agrees with the walk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    for ([_][]const u8{ "cat-a/one", "cat-a/two", "cat-b/three", ".hidden" }) |dir| {
        try tmp.dir.createDirPath(io, dir);
    }
    for ([_][]const u8{ "a.list", "b.list", "c.md5sums", "d.list.bak" }) |file| {
        (try tmp.dir.createFile(io, file, .{})).close(io);
    }
    var root_buf: [linux.PATH_MAX]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    var path_buf: [linux.PATH_MAX]u8 = undefined;
    const root = join_z(&path_buf, &.{root_buf[0..root_len]}).?;

    try std.testing.expectEqual(2, count_entries(root, .{ .files_with_suffix = ".list" }));
    try std.testing.expectEqual(3, count_entries(root, .dirs));
    try std.testing.expectEqual(3, count_entries(root, .dirs_in_subdirs));
    try std.testing.expectEqual(3, count_dirs(root));
    try std.testing.expectEqual(0, count_entries("/nonexistent/lifetch", .dirs));
}
