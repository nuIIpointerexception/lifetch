const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const sys = @import("sys.zig");
const out = @import("out.zig");

/// One slot per real filesystem: virtual mounts and repeat mounts of one device are not disks.
pub const max_disks = 8;

pub const Slot = struct {
    /// Mount path, unescaped: a slice into the mounts text in `Storage`, stable for the run (the
    /// only NUL-terminated copy is the scratch `collect` hands to `statfs`).
    mount: []const u8,
    /// Device string, unescaped: a slice into the mounts text in `Storage`.
    dev: []const u8,
    used: []const u8,
    total: []const u8,
    percent: []const u8,
    /// `"{used} / {total} ({percent})"`.
    composite: []const u8,
};

pub const Slots = struct { items: [max_disks]Slot, len: usize };

/// /proc/self/mounts is small; 8 KiB holds a big one, and anything past that is a partial line
/// that gets cut at the last newline anyway.
const mounts_len = 8 * 1024;
/// A mount path has to fit NUL-terminated in the one scratch copy for `statfs`; one that cannot
/// is skipped. Slots slice the mounts text instead of per-slot copies, so one scratch suffices.
const path_len = linux.PATH_MAX;

const size_len = @typeInfo(out.SizeBuf).array.len;
const percent_len = @typeInfo(out.PercentBuf).array.len;
/// `"{used} / {total} ({percent})"` plus the NUL `join_z` appends.
const composite_len = size_len + " / ".len + size_len + " (".len + percent_len + ")".len + 1;

/// The formatted text of one slot; the string fields of `Slot` point here.
const SlotText = struct {
    used: out.SizeBuf,
    total: out.SizeBuf,
    percent: out.PercentBuf,
    composite: [composite_len]u8,
};

/// Every buffer of a run in one object, so first touches land on as few stack pages as possible.
pub const Storage = struct {
    mounts: [mounts_len]u8,
    /// One NUL-terminated scratch path, reused for every `statfs`.
    path: [path_len]u8,
    texts: [max_disks]SlotText,
};

const mounts_path = "/proc/self/mounts";

/// Slots in first-seen mount-table order; every string slice points into `storage`.
pub fn collect(storage: *Storage, opts: out.Opts) Slots {
    var slots: Slots = .{ .items = undefined, .len = 0 };
    const read = sys.read_file(mounts_path, &storage.mounts) catch return slots;
    // A read that filled the buffer may have cut a line in half; parse whole lines only.
    const text = if (read.len == storage.mounts.len) cut_at_last_newline(read) else read;
    const found = scan(text);
    for (found.items[0..found.len]) |candidate| {
        // The only NUL-terminated copy of a path: `statfs` needs one, the slices do not.
        const path = out.join_z(&storage.path, &.{candidate.mount}) orelse continue;
        var fs: sys.Statfs = undefined;
        if (sys.statfs(path, &fs) != .SUCCESS) continue;
        const counts = usage(&fs);
        const texts = &storage.texts[slots.len];
        const used_text = out.format_size(counts.used, opts, &texts.used);
        const total_text = out.format_size(counts.total, opts, &texts.total);
        // The `df` convention throughout: the ceiling-rounded `Use%` over used + avail.
        const percent_text = out.format_percent_ceil(counts.used, counts.used +| counts.avail, &texts.percent);
        slots.items[slots.len] = .{
            .mount = candidate.mount,
            .dev = candidate.dev,
            .used = used_text,
            .total = total_text,
            .percent = percent_text,
            .composite = out.join_z(&texts.composite, &.{
                used_text, " / ", total_text, " (", percent_text, ")",
            }).?,
        };
        slots.len += 1;
    }
    return slots;
}

/// The byte counts one statfs record reports, df's arithmetic: blocks reserved for root count as
/// used (`Used`) but stay out of `avail` (`Avail`), so used + avail is the `Use%` denominator.
fn usage(fs: *const sys.Statfs) struct { used: u64, total: u64, avail: u64 } {
    const unit = block_unit(fs);
    return .{
        .used = clamp_mul(fs.f_blocks -| fs.f_bfree, unit),
        .total = clamp_mul(fs.f_blocks, unit),
        .avail = clamp_mul(fs.f_bavail, unit),
    };
}

/// The byte unit of the block counts: `f_frsize` when the filesystem reports one (df reads the
/// counts in these units too), `f_bsize` when `f_frsize` is 0.
fn block_unit(fs: *const sys.Statfs) u64 {
    return if (fs.f_frsize != 0) fs.f_frsize else fs.f_bsize;
}

/// `blocks * unit` in u128, clamped instead of wrapped when a filesystem reports huge counts.
fn clamp_mul(a: u64, b: u64) u64 {
    return @intCast(@min(@as(u128, a) * b, std.math.maxInt(u64)));
}

/// A read that filled the buffer may end mid-line; keep only through the last newline. Text with
/// no newline at all is one partial line and becomes empty.
fn cut_at_last_newline(text: []u8) []u8 {
    const last = mem.findScalarLast(u8, text, '\n') orelse return text[0..0];
    return text[0 .. last + 1];
}

const Candidate = struct { dev: []const u8, mount: []const u8 };

const Candidates = struct { items: [max_disks]Candidate, len: usize };

/// The pure half of `collect`: allowlist the fstype, keep the first mount per device. Escape
/// decoding shrinks `text` in place, and the kept dev and mount slice it: `Slot.mount`/`Slot.dev`
/// point here, and only `collect`'s statfs scratch ever copies a path.
fn scan(text: []u8) Candidates {
    var found: Candidates = .{ .items = undefined, .len = 0 };
    var rest = text;
    while (rest.len > 0) {
        const newline = mem.findScalar(u8, rest, '\n');
        const line = rest[0 .. newline orelse rest.len];
        rest = if (newline) |at| rest[at + 1 ..] else rest[rest.len..];
        const parsed = parse_line(line) orelse continue;
        if (!fstype_allowed(parsed.fstype)) continue;
        if (seen(&found, parsed.dev)) continue;
        found.items[found.len] = .{ .dev = parsed.dev, .mount = parsed.mount };
        found.len += 1;
        if (found.len == max_disks) break; // extra mounts are ignored
    }
    return found;
}

/// The device string decides: btrfs subvolumes mount one device many times, and the first mount
/// stands for all of them, so no later one is probed.
fn seen(found: *const Candidates, dev: []const u8) bool {
    for (found.items[0..found.len]) |kept| {
        if (mem.eql(u8, kept.dev, dev)) return true;
    }
    return false;
}

const Line = struct { dev: []const u8, mount: []const u8, fstype: []const u8 };

/// One `dev mount fstype options 0 0` line. dev and mount are unescaped in place: octal escapes
/// are three digits, so decoding only shrinks and each field stays inside the line.
fn parse_line(line: []u8) ?Line {
    var fields: [3][]u8 = undefined;
    var rest = line;
    for (&fields) |*field| {
        const space = mem.findScalar(u8, rest, ' ') orelse return null;
        field.* = rest[0..space];
        rest = rest[space + 1 ..];
    }
    return .{
        .dev = unescape(fields[0]) orelse return null,
        .mount = unescape(fields[1]) orelse return null,
        .fstype = fields[2],
    };
}

/// The mounts table spells space, tab, newline and backslash as three-digit octal. Any valid
/// octal triple decodes (the four spellings above are all the kernel writes); anything else keeps
/// its bytes. A NUL byte, decoded or literal, rejects the whole field: it would truncate the
/// `statfs` path while the slot shows more, and the kernel never writes one into this file.
/// Unescaping only shrinks, so it is safe in place.
fn unescape(text: []u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 3 < text.len) {
            var byte: u16 = 0;
            var octal = true;
            for (text[i + 1 .. i + 4]) |digit| {
                if (digit < '0' or digit > '7') {
                    octal = false;
                    break;
                }
                byte = byte * 8 + (digit - '0');
            }
            if (octal and byte <= std.math.maxInt(u8)) {
                if (byte == 0) return null; // a decoded NUL would truncate the statfs path
                text[len] = @intCast(byte);
                len += 1;
                i += 4;
                continue;
            }
        }
        if (text[i] == 0) return null;
        text[len] = text[i];
        len += 1;
        i += 1;
    }
    return text[0..len];
}

/// Filesystems backed by storage; virtual mounts and FUSE are not disks.
const fstypes = [_][]const u8{
    "ext2",  "ext3", "ext4",  "btrfs",    "xfs", "zfs",      "f2fs",   "vfat",
    "exfat", "ntfs", "ntfs3", "bcachefs", "jfs", "reiserfs", "nilfs2",
};

fn fstype_allowed(fstype: []const u8) bool {
    for (fstypes) |allowed| {
        if (mem.eql(u8, fstype, allowed)) return true;
    }
    return false;
}

test "scan: fstype allowlist, dev dedupe and first-seen order" {
    const fixture =
        \\/dev/sda1 / xfs rw,relatime 0 0
        \\/dev/sda2 /home xfs rw,relatime 0 0
        \\/dev/sda1 /btrfs-subvol btrfs rw,relatime 0 0
        \\/dev/sdb1 /boot vfat rw,relatime 0 0
        \\tmpfs /dev/shm tmpfs rw,nosuid 0 0
        \\proc /proc proc rw,nosuid 0 0
        \\gvfsd-fuse /run/user/1000/gvfs fuse.gvfsd-fuse rw 0 0
        \\
    ;
    var text = fixture.*;
    const found = scan(&text);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("/dev/sda1", found.items[0].dev);
    try std.testing.expectEqualStrings("/", found.items[0].mount);
    try std.testing.expectEqualStrings("/dev/sda2", found.items[1].dev);
    try std.testing.expectEqualStrings("/home", found.items[1].mount);
    try std.testing.expectEqualStrings("/dev/sdb1", found.items[2].dev);
    try std.testing.expectEqualStrings("/boot", found.items[2].mount);
}

test "parse_line: octal escapes unescape in place" {
    var line = "/dev/mapper/x\\040y /my\\040mount ext4 rw 0 0".*;
    const parsed = parse_line(&line).?;
    try std.testing.expectEqualStrings("/dev/mapper/x y", parsed.dev);
    try std.testing.expectEqualStrings("/my mount", parsed.mount);
    try std.testing.expectEqualStrings("ext4", parsed.fstype);

    var specials = "a\\011b\\012c\\134d /t\\011x xfs rw 0 0".*;
    const parsed_specials = parse_line(&specials).?;
    try std.testing.expectEqualStrings("a\tb\nc\\d", parsed_specials.dev);
    try std.testing.expectEqualStrings("/t\tx", parsed_specials.mount);

    var short = "dev mount".*;
    try std.testing.expect(parse_line(&short) == null);

    // A NUL, decoded or literal, rejects the line: it would truncate the statfs path.
    var decoded_nul = "/dev/x\\000y /my\\000mount ext4 rw 0 0".*;
    try std.testing.expect(parse_line(&decoded_nul) == null);
    var literal_nul = "/dev/x\x00y /m ext4 rw 0 0".*;
    try std.testing.expect(parse_line(&literal_nul) == null);
    var mount_nul = "/dev/x /m\x00y ext4 rw 0 0".*;
    try std.testing.expect(parse_line(&mount_nul) == null);
}

test "cut_at_last_newline: drops a partial trailing line" {
    var torn = "one\ntwo\nthr".*;
    try std.testing.expectEqualStrings("one\ntwo\n", cut_at_last_newline(&torn));
    var whole = "one\ntwo\n".*;
    try std.testing.expectEqualStrings("one\ntwo\n", cut_at_last_newline(&whole));
    var single = "no-newline-anywhere".*;
    try std.testing.expectEqualStrings("", cut_at_last_newline(&single));
}

test "usage: f_frsize is the block unit, f_bsize when it is zero" {
    const with_frsize: sys.Statfs = .{
        .f_type = 0,
        .f_bsize = 4096,
        .f_blocks = 50_000_000,
        .f_bfree = 10_900_000,
        .f_bavail = 10_900_000,
        .f_frsize = 1000,
    };
    try std.testing.expectEqual(@as(u64, 1000), block_unit(&with_frsize));
    const u = usage(&with_frsize);
    try std.testing.expectEqual(@as(u64, 39_100_000_000), u.used);
    try std.testing.expectEqual(@as(u64, 50_000_000_000), u.total);
    try std.testing.expectEqual(@as(u64, 10_900_000_000), u.avail);
    // 39.1G of 50G is 78.2%: the df ceiling says 79%.
    var buf: out.PercentBuf = undefined;
    try std.testing.expectEqualStrings("79%", out.format_percent_ceil(u.used, u.used +| u.avail, &buf));

    var no_frsize = with_frsize;
    no_frsize.f_frsize = 0;
    try std.testing.expectEqual(@as(u64, 4096), block_unit(&no_frsize));
    try std.testing.expectEqual(@as(u64, 160_153_600_000), usage(&no_frsize).used);

    // Huge counts clamp instead of wrapping.
    const huge: sys.Statfs = .{
        .f_type = 0,
        .f_bsize = 4096,
        .f_blocks = std.math.maxInt(u64),
        .f_bfree = 0,
        .f_bavail = 0,
        .f_frsize = 4096,
    };
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), usage(&huge).total);
}

// `collect` is syscalls around the pure parse fns; taking its address makes `zig test` compile
// the syscall layer without the tests ever touching statfs or /proc.
test "collect: the syscall layer compiles without running" {
    std.testing.refAllDecls(@This());
}
