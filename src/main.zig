const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const mem = std.mem;

const config_mod = @import("config.zig");
const Config = config_mod.Config;
const cpu = @import("cpu.zig");
const disk = @import("disk.zig");
const distro = @import("distro.zig");
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const format = @import("format.zig");
const gpu = @import("gpu.zig");
const meminfo = @import("mem.zig");
const Out = @import("out.zig").Out;
const out = @import("out.zig");
const pkg = @import("pkg.zig");
const sys = @import("sys.zig");
const terminal = @import("terminal.zig");
const wm = @import("wm.zig");

pub const std_options: std.Options = .{ .signal_stack_size = null };

const safety = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (safety)
    std.Io.Threaded.global_single_threaded
else
    null;

pub const panic = if (safety) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.no_panic;

comptime {
    @setEvalBranchQuota(300_000);
    std.debug.assert(disk.max_disks <= format.disk_slots_max);
    std.debug.assert(gpu.max_gpus <= format.gpu_slots_max);
    var bad: []const u8 = undefined;
    _ = format.scan(config_mod.default_format, &config_mod.default_settings, &bad) catch @compileError("config.ini: bad tag");
}

/// Every buffer of a run in one object. The hot half — what every template writes — comes first
/// so it sits at the stack bottom, where the call pushes share its pages instead of faulting
/// pages of their own; `Storage` is last and largest, and only a family's `collect` writes it.
const Scratch = struct {
    env: Env,
    values: format.Values,
    stdout: Out,
    config: Config,
    storage: Storage,
};


pub fn main(init: std.process.Init.Minimal) u8 {
    var scratch: Scratch = undefined;
    scratch.env = init_env(init.environ.block);
    const env = &scratch.env;
    const suffix = config_mod.path_suffix;
    // Every report below follows a read of the config file, which needs HOME.
    const parsed = scratch.config.load(env.HOME, config_mod.Stderr{ .home = env.HOME orelse "" }) catch |err| {
        switch (err) {
            error.ConfigTooLarge => report(&.{
                "lifetch: ",
                env.HOME.?,
                suffix,
                std.fmt.comptimePrint(" is larger than {d} bytes\n", .{config_mod.file_len_max - 1}),
            }),
            error.ConfigUnreadable => report(&.{ "lifetch: ", env.HOME.?, suffix, " cannot be read\n" }),
        }
        return 1;
    };
    if (scratch.config.create_failed) {
        report(&.{ "lifetch: cannot create ", env.HOME.?, suffix, "\n" });
    }

    var invalid: []const u8 = undefined;
    const fields = format.scan(parsed.format, parsed.settings, &invalid) catch {
        report(&.{ "lifetch: invalid tag \"", invalid, "\" in ", env.HOME.?, suffix, "\n" });
        return 1;
    };

    collect(fields, env, parsed.settings.opts, &scratch.storage, &scratch.values);
    const stdout = &scratch.stdout;
    stdout.init(1);
    format.render(parsed.format, &scratch.values, parsed.settings, terminal.colors(env), stdout);
    stdout.write("\n");
    stdout.flush();
    return @intFromBool(stdout.failed);
}

const Storage = struct {
    uts: linux.utsname,
    hostname: [64]u8,
    uptime: Uptime,
    pkgs: out.Digits,
    release: [distro.release_buf_len]u8,
    wm: [wm.buf_len]u8,
    meminfo: meminfo.Storage,
    cpu: cpu.Storage,
    disk: disk.Storage,
    gpu: gpu.Storage,
};

/// Every family is fetched only when the template asks for it, so an unused placeholder costs
/// nothing at startup. Results land in caller-owned `values`; nothing is copied out.
fn collect(fields: format.Fields, env: *const Env, opts: out.Opts, storage: *Storage, values: *format.Values) void {
    values.* = .initFill("");
    if (fields.contains(.user)) values.set(.user, env.USER orelse "unknown");
    if (fields.contains(.shell)) values.set(.shell, env_mod.basename(env.SHELL orelse "unknown"));
    if (fields.contains(.host) or fields.contains(.kernel)) {
        const uts_read = sys.uname(&storage.uts);
        if (fields.contains(.host)) values.set(.host, hostname(storage, uts_read));
        if (fields.contains(.kernel)) {
            const release = if (uts_read) mem.sliceTo(&storage.uts.release, 0) else "";
            values.set(.kernel, if (release.len > 0) release else "unknown");
        }
    }
    if (fields.contains(.uptime)) {
        const seconds = sys.boot_seconds();
        values.set(.uptime, if (seconds) |s| format_uptime(s, &storage.uptime) else "unknown");
    }
    if (fields.contains(.pkgs)) {
        const count = pkg.count();
        values.set(.pkgs, if (count) |n| out.format_uint(n, &storage.pkgs) else "unknown");
    }
    if (fields.contains(.session)) values.set(.session, session(env));
    if (fields.contains(.term)) values.set(.term, terminal.name(env));
    if (fields.contains(.wm)) values.set(.wm, wm.name(env, &storage.wm));
    if (fields.contains(.distro) or fields.contains(.distro_pretty)) {
        const found = distro.detect(&storage.release);
        values.set(.distro, found.id);
        values.set(.distro_pretty, found.name);
    }
    if (any(fields, .{ .cpu, .cpu_cores, .cpu_threads, .cpu_percent, .load })) {
        // Each cpu source is read only for the fields that need it (cpu.Need).
        const stats = cpu.collect(&storage.cpu, .{
            .model = fields.contains(.cpu),
            .cores = fields.contains(.cpu_cores),
            .threads = fields.contains(.cpu_threads),
            .percent = fields.contains(.cpu_percent),
            .load = fields.contains(.load),
        });
        values.set(.cpu, stats.cpu);
        values.set(.cpu_cores, stats.cpu_cores);
        values.set(.cpu_threads, stats.cpu_threads);
        values.set(.cpu_percent, stats.cpu_percent);
        values.set(.load, stats.load);
    }
    if (any(fields, .{ .mem, .mem_used, .mem_total, .mem_percent, .swap, .swap_used, .swap_total, .swap_percent })) {
        const stats = meminfo.collect(&storage.meminfo, opts);
        values.set(.mem, stats.mem);
        values.set(.mem_used, stats.mem_used);
        values.set(.mem_total, stats.mem_total);
        values.set(.mem_percent, stats.mem_percent);
        values.set(.swap, stats.swap);
        values.set(.swap_used, stats.swap_used);
        values.set(.swap_total, stats.swap_total);
        values.set(.swap_percent, stats.swap_percent);
    }
    if (any(fields, .{ .disk, .disk_used, .disk_total, .disk_percent, .disks })) {
        const slots = disk.collect(&storage.disk, opts);
        values.disk_count = slots.len;
        for (slots.items[0..slots.len], 0..) |*slot, i| {
            values.disks[i] = .{
                .mount = slot.mount,
                .dev = slot.dev,
                .used = slot.used,
                .total = slot.total,
                .percent = slot.percent,
                .composite = slot.composite,
            };
        }
    }
    if (any(fields, .{ .gpu, .gpu_vram, .gpu_percent, .gpus })) {
        const slots = gpu.collect(&storage.gpu, opts);
        values.gpu_count = slots.len;
        for (slots.items[0..slots.len], 0..) |*slot, i| {
            values.gpus[i] = .{ .name = slot.name, .vram = slot.vram, .busy = slot.busy };
        }
    }
}

fn any(fields: format.Fields, ids: anytype) bool {
    inline for (ids) |id| if (fields.contains(id)) return true;
    return false;
}

/// The walk `Env.init` does, but the value length is scanned here with a bounded loop instead of
/// `std.mem.span`: LLVM turns span's NUL search into a call to `strlen`, and compiler_rt's copy
/// sits on a cold page at the end of the image — one first-touch page fault per run in a binary
/// whose whole startup is a handful. Same rule as `Env.init`: the first definition of a name wins.
fn init_env(block: std.process.Environ.Block) Env {
    var env: Env = .{};
    for (block.slice) |entry_ptr| {
        const entry = entry_ptr orelse continue;
        inline for (@typeInfo(Env).@"struct".field_names) |name| {
            const prefix = name ++ "=";
            if (@field(env, name) == null and entry_has_prefix(entry, prefix)) {
                const value = value_len(entry + prefix.len);
                @field(env, name) = entry[prefix.len .. prefix.len + value :0];
            }
        }
    }
    return env;
}

/// Byte by byte: stopping at the first mismatch never reads past the terminating NUL.
fn entry_has_prefix(entry: [*:0]const u8, comptime prefix: []const u8) bool {
    inline for (prefix, 0..) |byte, i| {
        if (entry[i] != byte) return false;
    }
    return true;
}

/// A bounded NUL scan, inline. The volatile load is the whole point: without it LLVM rewrites even
/// the bounded shape into `min(strlen(s), bound)` — back to the cold-page call (see `init_env`).
inline fn value_len(s: [*:0]const u8) usize {
    const bytes: [*]const volatile u8 = @ptrCast(s);
    var i: usize = 0;
    while (i < std.math.maxInt(u16)) : (i += 1) {
        if (bytes[i] == 0) return i;
    }
    return std.math.maxInt(u16);
}

fn hostname(storage: *Storage, uts_read: bool) []const u8 {
    if (uts_read) {
        const node = mem.sliceTo(&storage.uts.nodename, 0);
        if (node.len > 0 and !mem.eql(u8, node, "(none)")) return node;
    }
    const file = sys.read_file("/etc/hostname", &storage.hostname) catch return "unknown";
    const name = mem.trimEnd(u8, file, "\n");
    return if (name.len == 0) "unknown" else name;
}

/// Three `<digits><unit> ` groups.
const Uptime = [3 * (@typeInfo(out.Digits).array.len + 2)]u8;

fn format_uptime(seconds: u64, buf: *Uptime) []const u8 {
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;
    var len: usize = 0;
    if (days > 0) len = append_unit(buf, len, days, 'd');
    if (hours > 0) len = append_unit(buf, len, hours % 24, 'h');
    len = append_unit(buf, len, minutes % 60, 'm');
    return buf[0 .. len - 1];
}

fn append_unit(buf: *Uptime, len: usize, value: u64, unit: u8) usize {
    var digits: out.Digits = undefined;
    const text = out.format_uint(value, &digits);
    out.copy(buf[len..][0..text.len], text);
    buf[len + text.len] = unit;
    buf[len + text.len + 1] = ' ';
    return len + text.len + 2;
}

fn session(env: *const Env) []const u8 {
    if (env.WAYLAND_DISPLAY != null) return "wayland";
    if (env.DISPLAY != null) return "x11";
    return "tty";
}

fn report(parts: []const []const u8) void {
    for (parts) |part| _ = sys.write_all(2, part);
}

test {
    _ = @import("config.zig");
    _ = @import("cpu.zig");
    _ = @import("disk.zig");
    _ = @import("distro.zig");
    _ = @import("env.zig");
    _ = @import("format.zig");
    _ = @import("gpu.zig");
    _ = @import("mem.zig");
    _ = @import("out.zig");
    _ = @import("pkg.zig");
    _ = @import("terminal.zig");
    _ = @import("wm.zig");
}

test "init_env: first definition wins, unknown names are skipped" {
    var entries = [_:null]?[*:0]u8{
        @constCast("TERM=foot"),
        @constCast("NOPE=1"),
        @constCast("TERM=xterm"),
        @constCast("USER="),
    };
    const env = init_env(.{ .slice = &entries });
    try std.testing.expectEqualStrings("foot", env.TERM.?);
    try std.testing.expectEqualStrings("", env.USER.?);
    try std.testing.expect(env.HOME == null);
}

test "format_uptime: minute, hour and day forms" {
    var buf: Uptime = undefined;
    try std.testing.expectEqualStrings("0m", format_uptime(59, &buf));
    try std.testing.expectEqualStrings("59m", format_uptime(59 * 60, &buf));
    try std.testing.expectEqualStrings("1h 0m", format_uptime(3600, &buf));
    try std.testing.expectEqualStrings("1d 0h 0m", format_uptime(86400, &buf));
    try std.testing.expectEqualStrings("1d 1h 1m", format_uptime(90061, &buf));
    const max = format_uptime(std.math.maxInt(u64), &buf);
    try std.testing.expectEqualStrings("213503982334601d 7h 0m", max);
}
