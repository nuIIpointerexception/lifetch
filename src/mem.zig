const std = @import("std");
const mem = std.mem;

const out = @import("out.zig");
const sys = @import("sys.zig");

/// RAM and swap as "used / total (percent)" plus the parts; the parts are fields too because a
/// template may print only one. Slices point into `Storage` or at string literals.
pub const Stats = struct {
    mem: []const u8,
    mem_used: []const u8,
    mem_total: []const u8,
    mem_percent: []const u8,
    swap: []const u8,
    swap_used: []const u8,
    swap_total: []const u8,
    swap_percent: []const u8,
};

/// /proc/meminfo stays under 2K even on a 64-socket machine, so one read gets it whole.
const file_len = 2048;

const size_len = @typeInfo(out.SizeBuf).array.len;
const percent_len = @typeInfo(out.PercentBuf).array.len;

/// Worst case of "{used} / {total} ({percent})": two size texts, " / ", " (", a percent and ")".
const composite_len = 2 * size_len + percent_len + " / ".len + " (".len + ")".len;

/// Every buffer of a collection in one caller-owned object, so first touches land on as few stack
/// pages as possible and nothing is allocated. The field buffers double as the parse scratch.
pub const Storage = struct {
    file: [file_len]u8,
    mem_used: out.SizeBuf,
    mem_total: out.SizeBuf,
    mem_percent: out.PercentBuf,
    mem: [composite_len]u8,
    swap_used: out.SizeBuf,
    swap_total: out.SizeBuf,
    swap_percent: out.PercentBuf,
    swap: [composite_len]u8,
};

/// Reads /proc/meminfo and hands the text to `parse`. An unreadable file parses as empty text,
/// which reports "unknown" — the same answer as a kernel too old to name its fields.
pub fn collect(storage: *Storage, opts: out.Opts) Stats {
    const text: []const u8 = sys.read_file("/proc/meminfo", &storage.file) catch "";
    return parse(text, opts, storage);
}

/// All the work, over the file text alone. Values are kB in the file and become bytes here. A
/// missing field that cannot be worked around reports every field as "unknown": a half-trusted
/// line is worse than none. Swap of a kernel without swap is "off" instead of a zero division.
pub fn parse(text: []const u8, opts: out.Opts, storage: *Storage) Stats {
    const f = scan(text);
    const total = f.mem_total orelse return unknown();
    const used = if (f.mem_available) |available|
        total -| available
    else used: {
        // MemAvailable arrived in 3.14; its classic approximation is free + buffers + cached.
        const free = f.mem_free orelse return unknown();
        const buffers = f.buffers orelse return unknown();
        const cached = f.cached orelse return unknown();
        break :used total -| (free +| buffers +| cached);
    };
    const swap_total = f.swap_total orelse 0;
    var swap_used: u64 = 0;
    if (swap_total != 0) {
        const free = f.swap_free orelse return unknown();
        swap_used = swap_total -| free;
    }

    const mem_used = out.format_size(used, opts, &storage.mem_used);
    const mem_total = out.format_size(total, opts, &storage.mem_total);
    const mem_percent = out.format_percent(used, total, &storage.mem_percent);
    var stats: Stats = .{
        .mem = composite(&storage.mem, mem_used, mem_total, mem_percent),
        .mem_used = mem_used,
        .mem_total = mem_total,
        .mem_percent = mem_percent,
        .swap = "off",
        .swap_used = "0B",
        .swap_total = "0B",
        .swap_percent = "0%",
    };
    if (swap_total != 0) {
        stats.swap_used = out.format_size(swap_used, opts, &storage.swap_used);
        stats.swap_total = out.format_size(swap_total, opts, &storage.swap_total);
        stats.swap_percent = out.format_percent(swap_used, swap_total, &storage.swap_percent);
        stats.swap = composite(&storage.swap, stats.swap_used, stats.swap_total, stats.swap_percent);
    }
    return stats;
}

/// The seven fields parse cares about, in bytes. Absent fields stay null.
const Fields = struct {
    mem_total: ?u64 = null,
    mem_available: ?u64 = null,
    mem_free: ?u64 = null,
    buffers: ?u64 = null,
    cached: ?u64 = null,
    swap_total: ?u64 = null,
    swap_free: ?u64 = null,
};

fn scan(text: []const u8) Fields {
    var f: Fields = .{};
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = mem.trim(u8, line[0..colon], " \t");
        const value = value_kbytes(line[colon + 1 ..]) orelse continue;
        if (mem.eql(u8, key, "MemTotal")) {
            f.mem_total = value;
        } else if (mem.eql(u8, key, "MemAvailable")) {
            f.mem_available = value;
        } else if (mem.eql(u8, key, "MemFree")) {
            f.mem_free = value;
        } else if (mem.eql(u8, key, "Buffers")) {
            f.buffers = value;
        } else if (mem.eql(u8, key, "Cached")) {
            f.cached = value;
        } else if (mem.eql(u8, key, "SwapTotal")) {
            f.swap_total = value;
        } else if (mem.eql(u8, key, "SwapFree")) {
            f.swap_free = value;
        }
    }
    return f;
}

/// The kB count at the start of a value ("67076920 kB") as bytes; null when the digits are absent
/// or their scaled form would overflow u64.
fn value_kbytes(text: []const u8) ?u64 {
    // The file pads values with spaces before the digits.
    const value = mem.trim(u8, text, " \t");
    var end: usize = 0;
    while (end < value.len and value[end] >= '0' and value[end] <= '9') end += 1;
    const count = parse_uint(value[0..end]) orelse return null;
    if (count > std.math.maxInt(u64) / 1024) return null;
    return count * 1024;
}

/// Decimal text to a value; null on empty text, a non-digit or overflow.
fn parse_uint(text: []const u8) ?u64 {
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u64 = c - '0';
        if (value > (std.math.maxInt(u64) - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return if (text.len == 0) null else value;
}

/// Plain appends into the fixed buffer: the parts are already formatted and there is no formatter
/// for ad-hoc layouts without std.io.
fn composite(buf: *[composite_len]u8, used: []const u8, total: []const u8, percent: []const u8) []const u8 {
    var len: usize = 0;
    for ([_][]const u8{ used, " / ", total, " (", percent, ")" }) |part| {
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    return buf[0..len];
}

fn unknown() Stats {
    const u: []const u8 = "unknown";
    return .{ .mem = u, .mem_used = u, .mem_total = u, .mem_percent = u, .swap = u, .swap_used = u, .swap_total = u, .swap_percent = u };
}

const fixture =
    \\MemTotal:       67076920 kB
    \\MemFree:        22086872 kB
    \\MemAvailable:   43324832 kB
    \\Buffers:          238692 kB
    \\Cached:         21692264 kB
    \\SwapCached:       112740 kB
    \\Active:         25376704 kB
    \\Inactive:       14666332 kB
    \\SwapTotal:      16767000 kB
    \\SwapFree:        5263000 kB
    \\Dirty:             2432 kB
    \\Writeback:             0 kB
    \\AnonPages:      22883784 kB
    \\Mapped:          3128584 kB
    \\Shmem:            672328 kB
    \\VmallocTotal:   34359738367 kB
;

test "parse: typical values fill every field" {
    var storage: Storage = undefined;
    const stats = parse(fixture, .{}, &storage);
    // used = 67076920 - 43324832 = 23752088 kB; the 6.5 of 22.65G rounds to 22.7G.
    try std.testing.expectEqualStrings("22.7G / 64G (35%)", stats.mem);
    try std.testing.expectEqualStrings("22.7G", stats.mem_used);
    try std.testing.expectEqualStrings("64G", stats.mem_total);
    try std.testing.expectEqualStrings("35%", stats.mem_percent);
    // used = 16767000 - 5263000 = 11504000 kB; both sizes round up into the integer part.
    try std.testing.expectEqualStrings("11G / 16G (69%)", stats.swap);
    try std.testing.expectEqualStrings("11G", stats.swap_used);
    try std.testing.expectEqualStrings("16G", stats.swap_total);
    try std.testing.expectEqualStrings("69%", stats.swap_percent);
}

test "parse: swap off, MemAvailable fallback and missing MemTotal" {
    var storage: Storage = undefined;

    const no_swap =
        \\MemTotal:       67076920 kB
        \\MemFree:        22086872 kB
        \\MemAvailable:   43324832 kB
        \\Buffers:          238692 kB
        \\Cached:         21692264 kB
        \\SwapTotal:              0 kB
        \\SwapFree:               0 kB
    ;
    const off = parse(no_swap, .{}, &storage);
    try std.testing.expectEqualStrings("off", off.swap);
    try std.testing.expectEqualStrings("0B", off.swap_used);
    try std.testing.expectEqualStrings("0B", off.swap_total);
    try std.testing.expectEqualStrings("0%", off.swap_percent);
    try std.testing.expectEqualStrings("22.7G / 64G (35%)", off.mem);

    // Kernels before 3.14: used = MemTotal - (MemFree + Buffers + Cached) = 23059092 kB.
    const old_kernel =
        \\MemTotal:       67076920 kB
        \\MemFree:        22086872 kB
        \\Buffers:          238692 kB
        \\Cached:         21692264 kB
        \\SwapTotal:      16767000 kB
        \\SwapFree:        5263000 kB
    ;
    const old = parse(old_kernel, .{}, &storage);
    try std.testing.expectEqualStrings("22G / 64G (34%)", old.mem);
    try std.testing.expectEqualStrings("22G", old.mem_used);
    try std.testing.expectEqualStrings("64G", old.mem_total);
    try std.testing.expectEqualStrings("34%", old.mem_percent);
    try std.testing.expectEqualStrings("11G / 16G (69%)", old.swap);

    const no_total =
        \\MemFree:        22086872 kB
        \\MemAvailable:   43324832 kB
        \\SwapTotal:      16767000 kB
        \\SwapFree:        5263000 kB
    ;
    const missing = parse(no_total, .{}, &storage);
    try std.testing.expectEqualStrings("unknown", missing.mem);
    try std.testing.expectEqualStrings("unknown", missing.mem_used);
    try std.testing.expectEqualStrings("unknown", missing.mem_total);
    try std.testing.expectEqualStrings("unknown", missing.mem_percent);
    try std.testing.expectEqualStrings("unknown", missing.swap);
    try std.testing.expectEqualStrings("unknown", missing.swap_used);
    try std.testing.expectEqualStrings("unknown", missing.swap_total);
    try std.testing.expectEqualStrings("unknown", missing.swap_percent);
}
