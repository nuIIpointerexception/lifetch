const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const mem = std.mem;

const config_mod = @import("config.zig");
const Config = config_mod.Config;
const distro = @import("distro.zig");
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const format = @import("format.zig");
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
    @setEvalBranchQuota(100_000);
    var invalid: []const u8 = undefined;
    _ = format.scan(config_mod.default_format, &invalid) catch @compileError("config.ini: bad tag");
}

/// Every buffer of a run in one object, so first touches land on as few stack pages as possible.
const Scratch = struct {
    config: Config,
    stdout: Out,
    storage: Storage,
};

pub fn main(init: std.process.Init.Minimal) u8 {
    const env: Env = .init(init.environ.block);
    var scratch: Scratch = undefined;
    const suffix = config_mod.path_suffix;
    // Every report below follows a read of the config file, which needs HOME.
    const template = scratch.config.load(env.HOME) catch |err| {
        const reason = switch (err) {
            error.ConfigTooLarge => std.fmt.comptimePrint(
                " is larger than {d} bytes\n",
                .{config_mod.file_len_max - 1},
            ),
            error.ConfigUnreadable => " cannot be read\n",
        };
        report(&.{ "lifetch: ", env.HOME.?, suffix, reason });
        return 1;
    };
    if (scratch.config.create_failed) {
        report(&.{ "lifetch: cannot create ", env.HOME.?, suffix, "\n" });
    }

    var invalid: []const u8 = undefined;
    const fields = format.scan(template, &invalid) catch {
        report(&.{ "lifetch: invalid tag \"", invalid, "\" in ", env.HOME.?, suffix, "\n" });
        return 1;
    };

    const values = collect(fields, &env, &scratch.storage);
    const stdout = &scratch.stdout;
    stdout.init(1);
    format.render(template, &values, terminal.colors(&env), stdout);
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
};

fn collect(fields: format.Fields, env: *const Env, storage: *Storage) format.Values {
    var values: format.Values = .initFill("");
    if (fields.contains(.user)) values.set(.user, env.USER orelse "unknown");
    if (fields.contains(.shell)) values.set(.shell, env_mod.basename(env.SHELL orelse "unknown"));
    if (fields.contains(.host)) values.set(.host, hostname(storage));
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
    return values;
}

fn hostname(storage: *Storage) []const u8 {
    if (sys.uname(&storage.uts)) {
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
    @memcpy(buf[len..][0..text.len], text);
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
    _ = @import("distro.zig");
    _ = @import("env.zig");
    _ = @import("format.zig");
    _ = @import("out.zig");
    _ = @import("pkg.zig");
    _ = @import("terminal.zig");
    _ = @import("wm.zig");
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
