const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

const env_mod = @import("env.zig");
const Env = env_mod.Env;
const out = @import("out.zig");
const sys = @import("sys.zig");

const Alias = struct { from: []const u8, to: []const u8 };

const compositor_names = [_]Alias{
    .{ .from = "Hyprland", .to = "hyprland" },
    .{ .from = "kwin_wayland", .to = "kwin" },
    .{ .from = "gnome-shell", .to = "mutter" },
    .{ .from = ".sway-wrapped", .to = "sway" },
};

const desktop_names = [_]Alias{
    .{ .from = "GNOME", .to = "mutter" },
    .{ .from = "KDE", .to = "kwin" },
    .{ .from = "XFCE", .to = "xfwm4" },
    .{ .from = "Hyprland", .to = "hyprland" },
};

const comm_len_max = 64;
const key_len_max = 10 + 1 + 10 + 1 + 20 + 1 + 20 + 1 + 9 + 1;
const socket_path_len_max = @typeInfo(@FieldType(linux.sockaddr.un, "path")).array.len;
const cache_prefix = "/lifetch-wm.";

pub const buf_len = key_len_max + comm_len_max + 2;

/// The process serving WAYLAND_DISPLAY, which stays right when a nested or second session
/// inherits another compositor's variables; else the environment's claim. May point into `buf`.
pub fn name(env: *const Env, buf: *[buf_len]u8) []const u8 {
    if (compositor(env, buf)) |comm| {
        for (compositor_names) |alias| {
            if (mem.eql(u8, comm, alias.from)) return alias.to;
        }
        return comm;
    }
    if (env.HYPRLAND_INSTANCE_SIGNATURE != null) return "hyprland";
    if (env.WAYLAND_DISPLAY != null) {
        if (env.DESKTOP_SESSION) |session| return session;
    }
    const desktop = env.XDG_CURRENT_DESKTOP orelse return "unknown";
    for (desktop_names) |alias| {
        if (mem.eql(u8, desktop, alias.from)) return alias.to;
    }
    return desktop;
}

/// Asking the socket costs a connect that wakes the compositor, so the answer is cached in
/// XDG_RUNTIME_DIR under the socket's device, inode and ctime; a restarted compositor binds a
/// new socket and misses. A crashed compositor leaves its socket behind, and a hit still names it.
fn compositor(env: *const Env, buf: *[buf_len]u8) ?[]const u8 {
    const display = env.WAYLAND_DISPLAY orelse return null;
    const absolute = mem.startsWith(u8, display, "/");
    if (!absolute and env.XDG_RUNTIME_DIR == null) return null;
    const runtime_dir = env.XDG_RUNTIME_DIR orelse "";
    var socket_buf: [socket_path_len_max]u8 = undefined;
    const socket = if (absolute)
        display
    else
        out.join_z(&socket_buf, &.{ runtime_dir, "/", display }) orelse return null;

    var stx: linux.Statx = undefined;
    if (sys.statx(socket, .{ .INO = true, .CTIME = true }, &stx) != .SUCCESS) return null;
    var key_buf: [key_len_max + 1]u8 = undefined;
    const key = cache_key(&stx, &key_buf);

    var cache_buf: [linux.PATH_MAX]u8 = undefined;
    const cache_parts = .{ runtime_dir, cache_prefix, env_mod.basename(display) };
    const cache = if (runtime_dir.len > 0) out.join_z(&cache_buf, &cache_parts) else null;
    if (cache) |path| {
        if (sys.read_file(path, buf)) |content| {
            if (cached_comm(content, key)) |comm| return comm;
        } else |_| {}
    }

    const comm = peer_comm(socket, buf[0..comm_len_max]) orelse return null;
    if (cache) |path| store(path, key, comm);
    return comm;
}

fn peer_comm(socket: []const u8, buf: []u8) ?[]const u8 {
    const pid = sys.socket_peer_pid(socket) orelse return null;
    var digits: out.Digits = undefined;
    var path_buf: ["/proc//comm".len + digits.len + 1]u8 = undefined;
    const pid_text = out.format_uint(@intCast(pid), &digits);
    const path = out.join_z(&path_buf, &.{ "/proc/", pid_text, "/comm" }).?;
    const comm = mem.trimEnd(u8, sys.read_file(path, buf) catch return null, "\n");
    return if (comm.len == 0) null else comm;
}

/// `<dev major>:<dev minor>:<inode>:<ctime sec>.<ctime nsec> `.
fn cache_key(stx: *const linux.Statx, buf: *[key_len_max + 1]u8) []const u8 {
    var digits: [5]out.Digits = undefined;
    const sec: u64 = @bitCast(stx.ctime.sec);
    const key = out.join_z(buf, &.{
        out.format_uint(stx.dev_major, &digits[0]),  ":",
        out.format_uint(stx.dev_minor, &digits[1]),  ":",
        out.format_uint(stx.ino, &digits[2]),        ":",
        out.format_uint(sec, &digits[3]),            ".",
        out.format_uint(stx.ctime.nsec, &digits[4]), " ",
    }).?;
    return key;
}

/// A torn or foreign file fails the key or the trailing newline and counts as a miss.
fn cached_comm(content: []const u8, key: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, content, key) or !mem.endsWith(u8, content, "\n")) return null;
    const comm = content[key.len .. content.len - 1];
    if (comm.len == 0 or mem.findScalar(u8, comm, '\n') != null) return null;
    return comm;
}

fn store(path: [:0]const u8, key: []const u8, comm: []const u8) void {
    var record_buf: [buf_len]u8 = undefined;
    const record = out.join_z(&record_buf, &.{ key, comm, "\n" }) orelse return;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = sys.open(path, flags, 0o600) catch return;
    defer sys.close(fd);
    _ = sys.write_all(fd, record);
}

test "name: environment fallback order" {
    var buf: [buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("hyprland", name(&.{
        .HYPRLAND_INSTANCE_SIGNATURE = "x",
        .XDG_CURRENT_DESKTOP = "neuwm",
    }, &buf));
    try std.testing.expectEqualStrings("neuwm", name(&.{ .XDG_CURRENT_DESKTOP = "neuwm" }, &buf));
    try std.testing.expectEqualStrings("kwin", name(&.{ .XDG_CURRENT_DESKTOP = "KDE" }, &buf));
    try std.testing.expectEqualStrings("unknown", name(&.{}, &buf));
}

test "cached_comm: hit, other key, torn record" {
    const key = "0:61:14379:5.7 ";
    try std.testing.expectEqualStrings("neuwm", cached_comm("0:61:14379:5.7 neuwm\n", key).?);
    try std.testing.expect(cached_comm("0:61:14380:5.7 neuwm\n", key) == null);
    try std.testing.expect(cached_comm("0:61:14379:5.7 neu", key) == null);
    try std.testing.expect(cached_comm("", key) == null);
    try std.testing.expect(cached_comm("0:61:14379:5.7 \n", key) == null);
}

test "cache_key: changes with the inode and the ctime" {
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    stx.dev_major = 0;
    stx.dev_minor = 61;
    stx.ino = 14379;
    stx.ctime.sec = 1793212151;
    stx.ctime.nsec = 5;
    var a: [key_len_max + 1]u8 = undefined;
    var b: [key_len_max + 1]u8 = undefined;
    try std.testing.expectEqualStrings("0:61:14379:1793212151.5 ", cache_key(&stx, &a));
    stx.ino += 1;
    try std.testing.expect(!mem.eql(u8, cache_key(&stx, &a), "0:61:14379:1793212151.5 "));
    stx.ino -= 1;
    stx.ctime.nsec = 6;
    try std.testing.expectEqualStrings("0:61:14379:1793212151.6 ", cache_key(&stx, &b));
}
