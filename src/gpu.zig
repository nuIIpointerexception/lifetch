const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const sys = @import("sys.zig");
const out = @import("out.zig");

/// One slot per DRM card; multi-GPU machines get one slot per card, in card order.
pub const max_gpus = 4;

pub const Slot = struct {
    /// "NVIDIA GeForce RTX 4070 Laptop GPU" or "intel (i915)"; comptime literals are returned as
    /// slices, anything read from a file is copied into `Storage`.
    name: []const u8,
    vram: []const u8, // formatted size, or "unknown"
    busy: []const u8, // "N%", or "unknown"
};

pub const Slots = struct { items: [max_gpus]Slot, len: usize };

/// Each probed file is a small attribute; 512 bytes holds one with room to spare.
const uevent_len = 512;
const info_len = 512;
/// A name can never exceed what the 512-byte reads extract, wrapped or not.
const name_len = 512;

/// The formatted text of one slot; the string fields of `Slot` point here.
const SlotText = struct {
    name: [name_len]u8,
    vram: out.SizeBuf,
    busy: out.PercentBuf,
};

/// Every buffer of a run in one object, so first touches land on as few stack pages as possible.
pub const Storage = struct { texts: [max_gpus]SlotText };

const drm_path = "/sys/class/drm";
const nvidia_gpus_path = "/proc/driver/nvidia/gpus";

/// Slots sorted by card number; every string slice points into `storage` or is a comptime literal.
pub fn collect(storage: *Storage, opts: out.Opts) Slots {
    var slots: Slots = .{ .items = undefined, .len = 0 };
    const cards = scan_cards();
    for (cards.nums[0..cards.len]) |num| {
        slots.items[slots.len] = probe(num, &storage.texts[slots.len], opts);
        slots.len += 1;
    }
    return slots;
}

const Cards = struct { nums: [max_gpus]u8, len: usize };

const dirents_buf_len = 4 * 1024;

/// `noinline` keeps the dirent buffer out of the callers' frames, where it would spread their
/// first-touched stack pages apart; only a machine with /sys/class/drm pays for it (see pkg.zig
/// walk). The card numbers are ordered here so `collect` probes low cards first.
noinline fn scan_cards() Cards {
    var buf: [dirents_buf_len]u8 align(8) = undefined;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = sys.open(drm_path, flags, 0) catch return .{ .nums = undefined, .len = 0 };
    defer sys.close(fd);
    var cards: Cards = .{ .nums = undefined, .len = 0 };
    while (true) {
        const len = sys.getdents(fd, &buf) catch break;
        if (len == 0) break;
        var it: Dirents = .{ .buf = buf[0..len] };
        while (it.next()) |entry| {
            if (card_index(entry.name)) |num| insert(&cards, num);
        }
    }
    return cards;
}

/// Ascending by card number; on a machine with more cards than slots the highest numbers fall off.
fn insert(cards: *Cards, num: u8) void {
    var at: usize = 0;
    while (at < cards.len and cards.nums[at] < num) at += 1;
    if (at < cards.len and cards.nums[at] == num) return; // "card1" and "card01" name one card
    if (cards.len < max_gpus) {
        cards.len += 1;
    } else if (at == cards.len) {
        return; // every slot holds a smaller number
    }
    var i = cards.len - 1;
    while (i > at) : (i -= 1) cards.nums[i] = cards.nums[i - 1];
    cards.nums[at] = num;
}

/// A bare DRM card: "card" plus one or two decimal digits and nothing else. Connector entries
/// ("card0-DP-3") and render nodes ("renderD128") are not cards.
fn card_index(name: []const u8) ?u8 {
    if (!mem.startsWith(u8, name, "card")) return null;
    const digits = name["card".len..];
    if (digits.len == 0 or digits.len > 2) return null;
    var num: u8 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        num = num * 10 + (c - '0');
    }
    return num;
}

/// The getdents64 record walk from pkg.zig, kept local so the modules stay standalone.
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

/// `noinline` keeps the read buffers out of `collect`'s frame, where they would spread its
/// first-touched stack pages apart; only a probed card pays for them (see pkg.zig walk).
noinline fn probe(num: u8, texts: *SlotText, opts: out.Opts) Slot {
    var path_buf: [linux.PATH_MAX]u8 = undefined;
    var uevent_buf: [uevent_len]u8 = undefined;
    var read_buf: [info_len]u8 = undefined;
    var digits: out.Digits = undefined;
    const card = out.format_uint(num, &digits);

    var uevent: Uevent = .{};
    if (read_into(&path_buf, &.{ drm_path, "/card", card, "/device/uevent" }, &uevent_buf)) |content| {
        uevent = parse_uevent(content);
    }

    var name: []const u8 = "unknown";
    var vram: []const u8 = "unknown";
    var busy: []const u8 = "unknown";
    if (uevent.driver) |driver| {
        // nvidia names the marketing model in its proc file; every card without one falls back
        // to "<vendor> (<driver>)" from the PCI ids.
        const model = if (mem.eql(u8, driver, "nvidia"))
            nvidia_model_of(uevent.pci_slot, &path_buf, &read_buf)
        else
            null;
        name = if (model) |m|
            out.join_z(&texts.name, &.{m}) orelse fallback_name(uevent.pci_id, driver, &texts.name)
        else
            fallback_name(uevent.pci_id, driver, &texts.name);

        // Only amdgpu exposes these two in sysfs; every other driver reports "unknown".
        if (mem.eql(u8, driver, "amdgpu")) {
            const vram_path = .{ drm_path, "/card", card, "/device/mem_info_vram_total" };
            if (read_into(&path_buf, &vram_path, &read_buf)) |content| {
                if (parse_dec(content)) |bytes| {
                    if (bytes > 0) vram = out.format_size(bytes, opts, &texts.vram);
                }
            }
            const busy_path = .{ drm_path, "/card", card, "/device/gpu_busy_percent" };
            if (read_into(&path_buf, &busy_path, &read_buf)) |content| {
                if (parse_dec(content)) |percent| busy = out.format_percent(percent, 100, &texts.busy);
            }
        }
    }
    return .{ .name = name, .vram = vram, .busy = busy };
}

/// One attribute read; null when the file is missing or unreadable, which the caller reports as
/// "unknown".
fn read_into(path_buf: []u8, parts: []const []const u8, buf: []u8) ?[]const u8 {
    const path = out.join_z(path_buf, parts) orelse return null;
    return sys.read_file(path, buf) catch null;
}

/// The "Model:" value of /proc/driver/nvidia/gpus/<PCI_SLOT_NAME>/information; null when the card
/// has no proc entry or no model line.
fn nvidia_model_of(pci_slot: ?[]const u8, path_buf: []u8, read_buf: []u8) ?[]const u8 {
    const slot = pci_slot orelse return null;
    const parts = .{ nvidia_gpus_path, "/", slot, "/information" };
    const content = read_into(path_buf, &parts, read_buf) orelse return null;
    return nvidia_model(content);
}

/// `"<vendor> (<driver>)"`, e.g. "intel (i915)"; "unknown" only if it does not fit.
fn fallback_name(pci_id: ?[]const u8, driver: []const u8, buf: []u8) []const u8 {
    const parts = .{ vendor_word(pci_id), " (", driver, ")" };
    return out.join_z(buf, &parts) orelse "unknown";
}

const Uevent = struct {
    driver: ?[]const u8 = null,
    pci_id: ?[]const u8 = null,
    pci_slot: ?[]const u8 = null,
};

const driver_prefix = "DRIVER=";
const pci_id_prefix = "PCI_ID=";
const pci_slot_prefix = "PCI_SLOT_NAME=";

/// The KEY=VALUE lines of a device uevent; the first definition of each key wins and unknown keys
/// are skipped.
fn parse_uevent(text: []const u8) Uevent {
    var uevent: Uevent = .{};
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (uevent.driver == null and mem.startsWith(u8, line, driver_prefix)) {
            uevent.driver = line[driver_prefix.len..];
        } else if (uevent.pci_id == null and mem.startsWith(u8, line, pci_id_prefix)) {
            uevent.pci_id = line[pci_id_prefix.len..];
        } else if (uevent.pci_slot == null and mem.startsWith(u8, line, pci_slot_prefix)) {
            uevent.pci_slot = line[pci_slot_prefix.len..];
        }
    }
    return uevent;
}

const model_prefix = "Model:";

/// The value of the "Model:" line of an nvidia `information` file, with the padding the driver
/// puts around it removed.
fn nvidia_model(text: []const u8) ?[]const u8 {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!mem.startsWith(u8, line, model_prefix)) continue;
        const value = mem.trim(u8, line[model_prefix.len..], " \t");
        return if (value.len == 0) null else value;
    }
    return null;
}

/// PCI vendor ids worth naming; anything else is just "gpu".
const vendors = [_]struct { id: *const [4]u8, word: []const u8 }{
    .{ .id = "10DE", .word = "nvidia" },
    .{ .id = "1002", .word = "amd" },
    .{ .id = "8086", .word = "intel" },
    .{ .id = "1AF4", .word = "virtio" },
};

/// The vendor half of PCI_ID ("8086:7A60" -> "8086"), compared case-insensitively.
fn vendor_word(pci_id: ?[]const u8) []const u8 {
    const id = pci_id orelse return "gpu";
    if (id.len < 4) return "gpu";
    for (vendors) |vendor| {
        if (std.ascii.eqlIgnoreCase(id[0..4], vendor.id)) return vendor.word;
    }
    return "gpu";
}

/// A sysfs decimal attribute ("4294967296\n"); null on empty or anything non-decimal.
fn parse_dec(text: []const u8) ?u64 {
    const value = mem.trim(u8, text, " \t\n\r");
    if (value.len == 0) return null;
    var n: u64 = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        n = std.math.mul(u64, n, 10) catch return null;
        n = std.math.add(u64, n, c - '0') catch return null;
    }
    return n;
}

test "card_index: bare card numbers only" {
    try std.testing.expectEqual(@as(?u8, 0), card_index("card0"));
    try std.testing.expectEqual(@as(?u8, 12), card_index("card12"));
    try std.testing.expect(card_index("card0-DP-3") == null);
    try std.testing.expect(card_index("renderD128") == null);
    try std.testing.expect(card_index("version") == null);
    try std.testing.expect(card_index("cards") == null);
    try std.testing.expect(card_index("card10-eDP-1") == null);
    try std.testing.expect(card_index("card") == null);
    try std.testing.expect(card_index("card007") == null);
}

test "parse_uevent: DRIVER, PCI_ID and PCI_SLOT_NAME" {
    const uevent = parse_uevent(
        \\PCI_ID=8086:7A60
        \\PCI_SLOT_NAME=0000:00:02.0
        \\DRIVER=i915
        \\MODALIAS=pci:v00008086d00007A60
    );
    try std.testing.expectEqualStrings("i915", uevent.driver.?);
    try std.testing.expectEqualStrings("8086:7A60", uevent.pci_id.?);
    try std.testing.expectEqualStrings("0000:00:02.0", uevent.pci_slot.?);
    const empty = parse_uevent("");
    try std.testing.expect(empty.driver == null and empty.pci_id == null and empty.pci_slot == null);
}

test "nvidia_model: Model line with driver padding" {
    const text = "Model: \t\t NVIDIA GeForce RTX 4070 Laptop GPU\nIRQ:   143\n";
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 4070 Laptop GPU", nvidia_model(text).?);
    try std.testing.expect(nvidia_model("IRQ:   143\n") == null);
    try std.testing.expect(nvidia_model("Model: \t \n") == null); // an empty value is no model
}

test "vendor_word: table, case-insensitive and fallback" {
    try std.testing.expectEqualStrings("nvidia", vendor_word("10DE:2784"));
    try std.testing.expectEqualStrings("amd", vendor_word("1002:744C"));
    try std.testing.expectEqualStrings("intel", vendor_word("8086:7A60"));
    try std.testing.expectEqualStrings("virtio", vendor_word("1AF4:1050"));
    try std.testing.expectEqualStrings("virtio", vendor_word("1af4:1050"));
    try std.testing.expectEqualStrings("gpu", vendor_word("1234:5678"));
    try std.testing.expectEqualStrings("gpu", vendor_word(null));
}

// `collect` is syscalls around the pure parse fns; taking its address makes `zig test` compile
// the syscall layer without the tests ever touching sysfs.
test "collect: the syscall layer compiles without running" {
    std.testing.refAllDecls(@This());
}
