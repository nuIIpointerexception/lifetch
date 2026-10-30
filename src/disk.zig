const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const sys = @import("sys.zig");
const out = @import("out.zig");

/// One slot per real filesystem: virtual mounts and repeat mounts of one device are not disks.
pub const max_disks = 8;

pub const Slot = struct {
    /// Mount path, unescaped: the per-slot NUL-terminated copy in `Storage` that `statfs` was
    /// called on, so the slice is stable and safe to hand to a syscall.
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
/// A mount path has to fit NUL-terminated for `statfs`; one that cannot be probed is skipped.
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
    paths: [max_disks][path_len]u8,
    texts: [max_disks]SlotText,
};

const mounts_path = "/proc/self/mounts";

/// Slots in first-seen mount-table order; every string slice points into `storage`.
pub fn collect(storage: *Storage, opts: out.Opts) Slots {
    var slots: Slots = .{ .items = undefined, .len = 0 };
    const read = sys.read_file(mounts_path, &storage.mounts) catch return slots;
    // A read that filled the buffer may have cut a line in half; parse whole lines only.
    const text = if (read.len == storage.mounts.len) cut_at_last_newline(read) else read;
    const found = scan(text, &storage.paths);
    for (found.items[0..found.len]) |candidate| {
        var fs: sys.Statfs = undefined;
        if (sys.statfs(candidate.mount, &fs) != .SUCCESS) continue;
        const used = clamp_mul(fs.f_blocks -| fs.f_bfree, fs.f_bsize);
        const total = clamp_mul(fs.f_blocks, fs.f_bsize);
        // The `df` convention: blocks reserved for root stay out of the denominator.
        const avail = clamp_mul(fs.f_bavail, fs.f_bsize);
        const texts = &storage.texts[slots.len];
        const used_text = out.format_size(used, opts, &texts.used);
        const total_text = out.format_size(total, opts, &texts.total);
        const percent_text = out.format_percent(used, used +| avail, &texts.percent);
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

/// `f_blocks * f_bsize` in u128, clamped instead of wrapped when a filesystem reports huge counts.
fn clamp_mul(a: u64, b: u64) u64 {
    return @intCast(@min(@as(u128, a) * b, std.math.maxInt(u64)));
}

/// A read that filled the buffer may end mid-line; keep only through the last newline. Text with
/// no newline at all is one partial line and becomes empty.
fn cut_at_last_newline(text: []u8) []u8 {
    const last = mem.findScalarLast(u8, text, '\n') orelse return text[0..0];
    return text[0 .. last + 1];
}

const Candidate = struct { dev: []const u8, mount: [:0]const u8 };

const Candidates = struct { items: [max_disks]Candidate, len: usize };

/// The pure half of `collect`: allowlist the fstype, keep the first mount per device, and copy
/// each kept mount path NUL-terminated into `paths`. Escape decoding shrinks `text` in place.
fn scan(text: []u8, paths: *[max_disks][path_len]u8) Candidates {
    var found: Candidates = .{ .items = undefined, .len = 0 };
    var rest = text;
    while (rest.len > 0) {
        const newline = mem.findScalar(u8, rest, '\n');
        const line = rest[0 .. newline orelse rest.len];
        rest = if (newline) |at| rest[at + 1 ..] else rest[rest.len..];
        const parsed = parse_line(line) orelse continue;
        if (!fstype_allowed(parsed.fstype)) continue;
        if (seen(&found, parsed.dev)) continue;
        // Lines in the mounts buffer end at a newline, not a NUL: the copy is what `statfs`
        // gets, and what `Slot.mount` later slices.
        const mount = out.join_z(&paths[found.len], &.{parsed.mount}) orelse continue;
        found.items[found.len] = .{ .dev = parsed.dev, .mount = mount };
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
    return .{ .dev = unescape(fields[0]), .mount = unescape(fields[1]), .fstype = fields[2] };
}

/// The mounts table spells space, tab, newline and backslash as three-digit octal. Any valid
/// octal triple decodes (the four spellings above are all the kernel writes); anything else keeps
/// its bytes. Unescaping only shrinks, so it is safe in place.
fn unescape(text: []u8) []const u8 {
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
                text[len] = @intCast(byte);
                len += 1;
                i += 4;
                continue;
            }
        }
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
    var paths: [max_disks][path_len]u8 = undefined;
    const found = scan(&text, &paths);
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
}

test "cut_at_last_newline: drops a partial trailing line" {
    var torn = "one\ntwo\nthr".*;
    try std.testing.expectEqualStrings("one\ntwo\n", cut_at_last_newline(&torn));
    var whole = "one\ntwo\n".*;
    try std.testing.expectEqualStrings("one\ntwo\n", cut_at_last_newline(&whole));
    var single = "no-newline-anywhere".*;
    try std.testing.expectEqualStrings("", cut_at_last_newline(&single));
}

// `collect` is syscalls around the pure parse fns; taking its address makes `zig test` compile
// the syscall layer without the tests ever touching statfs or /proc.
test "collect: the syscall layer compiles without running" {
    std.testing.refAllDecls(@This());
}
