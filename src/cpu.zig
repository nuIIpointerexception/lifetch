const std = @import("std");
const mem = std.mem;

const format = @import("format.zig");
const out = @import("out.zig");
const sys = @import("sys.zig");

/// What the processor is, how many of them there are, and how busy they have been. Slices point
/// into `Storage` or at string literals; on any read or parse failure the field is "unknown".
pub const Stats = struct {
    cpu: []const u8,
    cpu_cores: []const u8,
    cpu_threads: []const u8,
    cpu_percent: []const u8,
    load: []const u8,
};

/// Which parts of `Stats` a template asked for. Every source file is read only when one of its
/// fields is used: `{cpu}` costs one /proc/cpuinfo read, `{cpu_percent}` the /proc/stat read, and
/// a source no field needs is never opened.
pub const Need = struct {
    model: bool = false,
    cores: bool = false,
    threads: bool = false,
    percent: bool = false,
    load: bool = false,
};

/// Which sources the placeholders of a template ask for. Pure, so a field wired to the wrong
/// source shows up in a test instead of as an extra file read. `{cpu}` wants the model name and
/// the core count: both live in /proc/cpuinfo, which is one read either way.
pub fn need_of(fields: format.Fields) Need {
    return .{
        .model = fields.contains(.cpu),
        .cores = fields.contains(.cpu) or fields.contains(.cpu_cores),
        .threads = fields.contains(.cpu_threads),
        .percent = fields.contains(.cpu_percent),
        .load = fields.contains(.load),
    };
}

/// The first line whose key names the model is well inside the first block of /proc/cpuinfo;
/// reading only 1024 bytes keeps a many-socket machine from spilling the stack buffer.
const cpuinfo_len = 1024;
/// Longest real model name is under 100 bytes; cleaning only ever shrinks it.
const model_len = 256;
/// /sys/devices/system/cpu/online is a handful of ranges.
const online_len = 32;
/// The aggregate "cpu " line of /proc/stat, with slack for wide jiffy counters.
const stat_len = 256;
/// /proc/loadavg is one line of five tokens; the 1-minute token comes first.
const loadavg_len = 32;
const load_len = 32;

const cpuinfo_path = "/proc/cpuinfo";
const online_path = "/sys/devices/system/cpu/online";
const stat_path = "/proc/stat";
const loadavg_path = "/proc/loadavg";

/// Every buffer of a collection in one caller-owned object, so first touches land on as few stack
/// pages as possible and nothing is allocated.
pub const Storage = struct {
    cpuinfo: [cpuinfo_len]u8,
    model: [model_len]u8,
    cores: out.Digits,
    online: [online_len]u8,
    threads: out.Digits,
    stat: [stat_len]u8,
    percent: out.PercentBuf,
    loadavg: [loadavg_len]u8,
    load: [load_len]u8,
};
/// Reads only the sources `need` asks for; a read failure is empty text, which parses as
/// "unknown", and a source no field needs is never opened.
pub fn collect(storage: *Storage, need: Need) Stats {
    var stats: Stats = unknown();
    if (need.model or need.cores) {
        const cpuinfo: []const u8 = sys.read_file(cpuinfo_path, &storage.cpuinfo) catch "";
        if (need.model) stats.cpu = parse_model(cpuinfo, &storage.model);
        if (need.cores) stats.cpu_cores = parse_cores(cpuinfo, &storage.cores);
    }
    if (need.threads) {
        stats.cpu_threads = parse_online(
            sys.read_file(online_path, &storage.online) catch "",
            &storage.threads,
        );
    }
    if (need.percent) {
        stats.cpu_percent = parse_stat(
            sys.read_file(stat_path, &storage.stat) catch "",
            &storage.percent,
        );
    }
    if (need.load) {
        stats.load = parse_load(
            sys.read_file(loadavg_path, &storage.loadavg) catch "",
            &storage.load,
        );
    }
    return stats;
}

fn unknown() Stats {
    const u: []const u8 = "unknown";
    return .{ .cpu = u, .cpu_cores = u, .cpu_threads = u, .cpu_percent = u, .load = u };
}

/// The model name: the value of the first "model name" (x86), "cpu model" (arm), "Model" (device
/// tree) or "Hardware" (arm board) line, cleaned. The keys match case-sensitively on purpose:
/// x86's numeric "model" field sits right above "model name" and must not be read as a name.
/// Known limitation: old ARM kernels repeat "Hardware" in every processor block, so on a board
/// with long blocks the first named line can sit past the 1024-byte read and the model is missed.
pub fn parse_model(text: []const u8, buf: *[model_len]u8) []const u8 {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = mem.trim(u8, line[0..colon], " \t");
        const named = mem.eql(u8, key, "model name") or mem.eql(u8, key, "cpu model") or
            mem.eql(u8, key, "Model") or mem.eql(u8, key, "Hardware");
        if (!named) continue;
        const value = mem.trim(u8, line[colon + 1 ..], " \t\r");
        const len = @min(value.len, buf.len);
        out.copy(buf[0..len], value[0..len]);
        return clean_model(buf[0..len]);
    }
    return "unknown";
}

/// Strips the trademark decorations vendors leave in their names ("Intel(R) Core(TM) i9" becomes
/// "Intel Core i9") in place, because the value already lives in a Storage buffer and the result
/// is never longer than the input. Then collapses doubled spaces and trims the ends.
fn clean_model(buf: []u8) []const u8 {
    var len = delete_all(buf, "(R)");
    len = delete_all(buf[0..len], "(TM)");
    len = delete_all(buf[0..len], "(C)");
    const squeezed = squeeze_spaces(buf[0..len]);
    const name = mem.trim(u8, squeezed, " ");
    return if (name.len == 0) "unknown" else name;
}

/// Deletes every occurrence of `needle`, compacting forward in place; safe because the result can
/// only shrink. Returns the new length.
fn delete_all(text: []u8, needle: []const u8) usize {
    var len: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        if (mem.startsWith(u8, text[pos..], needle)) {
            pos += needle.len;
        } else {
            text[len] = text[pos];
            len += 1;
            pos += 1;
        }
    }
    return len;
}

/// Collapses runs of spaces to one, in place; the result can only shrink.
fn squeeze_spaces(text: []u8) []u8 {
    var len: usize = 0;
    for (text) |c| {
        if (c == ' ' and len > 0 and text[len - 1] == ' ') continue;
        text[len] = c;
        len += 1;
    }
    return text[0..len];
}

/// Physical cores per package, the first "cpu cores" (x86) value copied verbatim: it is already
/// decimal text, and reformatting it would only risk changing it.
pub fn parse_cores(text: []const u8, buf: *out.Digits) []const u8 {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = mem.trim(u8, line[0..colon], " \t");
        if (!mem.eql(u8, key, "cpu cores")) continue;
        const value = mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (value.len == 0 or value.len > buf.len) return "unknown";
        for (value) |c| {
            if (c < '0' or c > '9') return "unknown";
        }
        out.copy(buf[0..value.len], value);
        return buf[0..value.len];
    }
    return "unknown";
}

/// Logical CPUs, counted from the online-mask of /sys/devices/system/cpu: ranges of CPUs the
/// kernel has brought up ("0-31", "0-7,16-23") or a single CPU ("3"). The possible-mask is no
/// stand-in: VMware reserves hotplug slots there ("0-127" with 4 CPUs online).
pub fn parse_online(text: []const u8, buf: *out.Digits) []const u8 {
    const count = count_online(text) orelse return "unknown";
    return out.format_uint(count, buf);
}

/// The sum of the inclusive ranges of a cpu list mask; null on empty or malformed text.
fn count_online(text: []const u8) ?u64 {
    const mask = mem.trim(u8, text, " \t\r\n");
    if (mask.len == 0) return null;
    var total: u64 = 0;
    var it = mem.splitScalar(u8, mask, ',');
    while (it.next()) |part| {
        const dash = mem.indexOfScalar(u8, part, '-');
        const low = out.parse_uint(if (dash) |at| part[0..at] else part) orelse return null;
        if (dash) |at| {
            const high = out.parse_uint(part[at + 1 ..]) orelse return null;
            if (high < low) return null;
            total +|= high - low + 1;
        } else {
            total +|= 1;
        }
    }
    return total;
}

/// The since-boot busy share from the aggregate "cpu " line of /proc/stat: jiffies spent working
/// over all jiffies, which unlike a sampled snapshot needs no sleep between two readings.
pub fn parse_stat(text: []const u8, buf: *out.PercentBuf) []const u8 {
    var it = mem.tokenizeAny(u8, text, " \t\r\n");
    const label = it.next() orelse return "unknown";
    if (!mem.eql(u8, label, "cpu")) return "unknown";
    var times: [8]u64 = undefined; // user nice system idle iowait irq softirq steal
    for (&times) |*slot| {
        const token = it.next() orelse return "unknown";
        slot.* = out.parse_uint(token) orelse return "unknown";
    }
    const busy = times[0] +| times[1] +| times[2] +| times[5] +| times[6] +| times[7];
    const total = busy +| times[3] +| times[4];
    return out.format_percent(busy, total, buf);
}

/// The 1-minute load average: the first token of /proc/loadavg, verbatim.
pub fn parse_load(text: []const u8, buf: *[load_len]u8) []const u8 {
    var it = mem.tokenizeAny(u8, text, " \t\r\n");
    const token = it.next() orelse return "unknown";
    const len = @min(token.len, buf.len);
    out.copy(buf[0..len], token[0..len]);
    return buf[0..len];
}

const x86_cpuinfo =
    \\processor : 0
    \\vendor_id : GenuineIntel
    \\cpu family : 6
    \\model  : 183
    \\model name : Intel(R) Core(TM) i9-14900HX
    \\stepping : 1
    \\cpu MHz  : 2200.000
    \\cache size : 30720 KB
    \\physical id : 0
    \\siblings : 32
    \\core id  : 0
    \\cpu cores : 16
    \\apicid  : 0
;

test "parse_model: x86 cleaning, arm fallbacks, decorations and the numeric model key" {
    var buf: [model_len]u8 = undefined;
    // "model : 183" is x86's numeric model id; only "model name" names the CPU.
    try std.testing.expectEqualStrings("Intel Core i9-14900HX", parse_model(x86_cpuinfo, &buf));

    // Only the three trademark strings go: "(v8l)" is part of the name.
    const arm =
        \\processor : 0
        \\model name : ARMv8 Processor rev 1 (v8l)
    ;
    try std.testing.expectEqualStrings("ARMv8 Processor rev 1 (v8l)", parse_model(arm, &buf));

    // Old arm boards name the board, not the core.
    const hardware =
        \\processor : 0
        \\Hardware : NVIDIA Jetson AGX Orin Developer Kit
    ;
    try std.testing.expectEqualStrings(
        "NVIDIA Jetson AGX Orin Developer Kit",
        parse_model(hardware, &buf),
    );

    const board =
        \\processor : 0
        \\Model  : Raspberry Pi 4 Model B Rev 1.5
    ;
    try std.testing.expectEqualStrings("Raspberry Pi 4 Model B Rev 1.5", parse_model(board, &buf));

    // "(R)", "(TM)" and "(C)" go; the spaces they leave are collapsed and the ends trimmed.
    const decorated =
        \\model name : Foo(R)(TM)  Bar(C) Ltd
    ;
    try std.testing.expectEqualStrings("Foo Bar Ltd", parse_model(decorated, &buf));
    try std.testing.expectEqualStrings("unknown", parse_model("processor : 0\n", &buf));
}

test "parse_cores: first cpu cores value" {
    var digits: out.Digits = undefined;
    try std.testing.expectEqualStrings("16", parse_cores(x86_cpuinfo, &digits));
    try std.testing.expectEqualStrings("unknown", parse_cores("model name : x\n", &digits));
}

test "parse_online: ranges, a single CPU and empty text" {
    var digits: out.Digits = undefined;
    try std.testing.expectEqualStrings("32", parse_online("0-31\n", &digits));
    try std.testing.expectEqualStrings("16", parse_online("0-7,16-23\n", &digits));
    try std.testing.expectEqualStrings("1", parse_online("3\n", &digits));
    try std.testing.expectEqualStrings("1", parse_online("0-0\n", &digits));
    try std.testing.expectEqualStrings("unknown", parse_online("", &digits));
    try std.testing.expectEqualStrings("unknown", parse_online("0-7,\n", &digits));
}

test "need_of: {cpu} asks for the model name and the core count" {
    const need = need_of(.init(.{ .cpu = true }));
    try std.testing.expect(need.model);
    try std.testing.expect(need.cores);
    try std.testing.expect(!need.threads);
    try std.testing.expect(!need.percent);
    try std.testing.expect(!need.load);
}

test "need_of: {cpu_cores} asks for the core count only" {
    const need = need_of(.init(.{ .cpu_cores = true }));
    try std.testing.expect(!need.model);
    try std.testing.expect(need.cores);
    try std.testing.expect(!need.threads);
    try std.testing.expect(!need.percent);
    try std.testing.expect(!need.load);
}

test "need_of: {cpu_threads} asks for the thread count only" {
    const need = need_of(.init(.{ .cpu_threads = true }));
    try std.testing.expect(!need.model);
    try std.testing.expect(!need.cores);
    try std.testing.expect(need.threads);
    try std.testing.expect(!need.percent);
    try std.testing.expect(!need.load);
}

test "need_of: {cpu_percent} asks for the busy share only" {
    const need = need_of(.init(.{ .cpu_percent = true }));
    try std.testing.expect(!need.model);
    try std.testing.expect(!need.cores);
    try std.testing.expect(!need.threads);
    try std.testing.expect(need.percent);
    try std.testing.expect(!need.load);
}

test "need_of: {load} asks for the load average only" {
    const need = need_of(.init(.{ .load = true }));
    try std.testing.expect(!need.model);
    try std.testing.expect(!need.cores);
    try std.testing.expect(!need.threads);
    try std.testing.expect(!need.percent);
    try std.testing.expect(need.load);
}

test "need_of: an empty template asks for nothing" {
    const need = need_of(.init(.{}));
    try std.testing.expect(!need.model);
    try std.testing.expect(!need.cores);
    try std.testing.expect(!need.threads);
    try std.testing.expect(!need.percent);
    try std.testing.expect(!need.load);
}

test "collect: nothing needed opens no source" {
    var storage: Storage = undefined;
    // With no field asked for, `collect` reads no file and every field stays "unknown" — the
    // pure layering the per-source gating sits on (a source a field needs is read in its own
    // `if (need...)` branch only).
    const none = collect(&storage, .{});
    try std.testing.expectEqualStrings("unknown", none.cpu);
    try std.testing.expectEqualStrings("unknown", none.cpu_cores);
    try std.testing.expectEqualStrings("unknown", none.cpu_threads);
    try std.testing.expectEqualStrings("unknown", none.cpu_percent);
    try std.testing.expectEqualStrings("unknown", none.load);
}

test "parse_stat: since-boot busy share of the cpu line" {
    var buf: out.PercentBuf = undefined;
    // busy = 100+50+25+0+10+5 = 190, total = 190 + 800 idle + 25 iowait = 1015; 18.7% rounds up.
    const stat =
        \\cpu  100 50 25 800 25 0 10 5 0 0
        \\cpu0 50 25 12 400 12 0 5 2 0 0
    ;
    try std.testing.expectEqualStrings("19%", parse_stat(stat, &buf));
    try std.testing.expectEqualStrings("50%", parse_stat("cpu  200 0 0 200 0 0 0 0 0 0\n", &buf));
    try std.testing.expectEqualStrings("0%", parse_stat("cpu  0 0 0 0 0 0 0 0 0 0\n", &buf));
    try std.testing.expectEqualStrings("unknown", parse_stat("cpu  100 50 25 800 25 0 10\n", &buf));
    try std.testing.expectEqualStrings("unknown", parse_stat("", &buf));
}

test "parse_load: first token verbatim" {
    var buf: [load_len]u8 = undefined;
    const loadavg = "0.35 0.45 0.55 2/1234 56789\n";
    try std.testing.expectEqualStrings("0.35", parse_load(loadavg, &buf));
    try std.testing.expectEqualStrings("unknown", parse_load("  \n", &buf));
}
