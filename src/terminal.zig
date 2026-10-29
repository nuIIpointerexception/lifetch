const std = @import("std");
const mem = std.mem;

const Colors = @import("format.zig").Colors;
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const out = @import("out.zig");
const sys = @import("sys.zig");

const color_terms = [_][]const u8{
    "linux", "xterm",   "rxvt",  "screen", "tmux",      "vt100", "vt220", "ansi",    "cygwin",
    "putty", "konsole", "gnome", "foot",   "alacritty", "kitty", "st",    "wezterm", "urxvt",
};

const terminals = [_][]const u8{
    "foot",       "footclient",     "alacritty",       "kitty",      "wezterm",
    "konsole",    "gnome-terminal", "xfce4-terminal",  "terminator", "tilix",
    "st",         "urxvt",          "rxvt",            "xterm",      "mate-terminal",
    "lxterminal", "qterminal",      "terminology",     "sakura",     "guake",
    "tilda",      "yakuake",        "cool-retro-term", "ghostty",    "wezterm-gui",
};

const Alias = struct { term: []const u8, name: []const u8 };

/// TERM values only one emulator sets.
const term_owners = [_]Alias{
    .{ .term = "foot", .name = "foot" },
    .{ .term = "foot-extra", .name = "foot" },
    .{ .term = "alacritty", .name = "alacritty" },
    .{ .term = "xterm-kitty", .name = "kitty" },
    .{ .term = "xterm-ghostty", .name = "ghostty" },
    .{ .term = "wezterm", .name = "wezterm" },
};

const shells = [_][]const u8{ "sh", "bash", "zsh", "fish", "dash" };

const ancestors_max = 4;
const comm_len_max = 15;

pub fn colors(env: *const Env) Colors {
    var support: Colors = .{ .basic = false, .truecolor = false };
    if (env.NO_COLOR) |value| {
        if (value.len > 0) return support;
    }
    if (env.COLORTERM) |value| {
        if (mem.eql(u8, value, "truecolor") or mem.eql(u8, value, "24bit")) {
            support = .{ .basic = true, .truecolor = true };
        }
    }
    const term = env.TERM orelse return support;
    if (support.basic) return support;
    for (color_terms) |known| {
        if (mem.startsWith(u8, term, known)) return .{ .basic = true, .truecolor = false };
    }
    if (mem.find(u8, term, "256color") != null) return .{ .basic = true, .truecolor = false };
    support.basic = has_terminfo(term) orelse (mem.find(u8, term, "color") != null);
    return support;
}

fn has_terminfo(term: []const u8) ?bool {
    if (term.len == 0) return false;
    var path_buf: ["/usr/share/terminfo/x/".len + std.os.linux.NAME_MAX + 1]u8 = undefined;
    const path = out.join_z(&path_buf, &.{ "/usr/share/terminfo/", term[0..1], "/", term }) orelse
        return false;
    return switch (sys.access(path)) {
        .SUCCESS => true,
        .NOENT => false,
        else => null,
    };
}

/// TERM_PROGRAM; a TERM only one emulator sets; the nearest emulator among the parent and the
/// shells above it; then TERM.
pub fn name(env: *const Env) []const u8 {
    if (env.TERM_PROGRAM) |program| {
        return if (mem.eql(u8, program, "WarpTerminal")) "warp" else program;
    }
    if (env.TERM) |term| {
        for (term_owners) |owner| {
            if (mem.eql(u8, term, owner.term)) return owner.name;
        }
    }
    if (ancestor_terminal(env)) |terminal| return terminal;
    const term = env.TERM orelse return "unknown";
    for ([_][]const u8{ "xterm", "rxvt", "screen", "tmux" }) |family| {
        if (mem.startsWith(u8, term, family)) return family;
    }
    return term;
}

fn ancestor_terminal(env: *const Env) ?[]const u8 {
    const login_shell = env_mod.basename(env.SHELL orelse "");
    var pid: std.os.linux.pid_t = std.os.linux.getppid();
    for (0..ancestors_max) |_| {
        if (pid <= 1) return null;
        var stat_buf: [128]u8 = undefined;
        const stat = read_stat(pid, &stat_buf) orelse return null;
        for (terminals) |terminal| {
            if (mem.eql(u8, stat.comm, terminal)) return terminal;
        }
        if (!is_shell(stat.comm, login_shell)) return null;
        pid = stat.ppid;
    }
    return null;
}

fn is_shell(comm: []const u8, login_shell: []const u8) bool {
    if (comm.len == 0) return false;
    if (mem.eql(u8, comm, login_shell)) return true;
    if (comm.len == comm_len_max and mem.startsWith(u8, login_shell, comm)) return true;
    for (shells) |shell| {
        if (mem.eql(u8, comm, shell)) return true;
    }
    return false;
}

const Stat = struct { comm: []const u8, ppid: std.os.linux.pid_t };

fn read_stat(pid: std.os.linux.pid_t, buf: *[128]u8) ?Stat {
    var digits: out.Digits = undefined;
    var path_buf: ["/proc//stat".len + digits.len + 1]u8 = undefined;
    const pid_text = out.format_uint(@intCast(pid), &digits);
    const path = out.join_z(&path_buf, &.{ "/proc/", pid_text, "/stat" }).?;
    return parse_stat(sys.read_file(path, buf) catch return null);
}

/// `pid (comm) state ppid ...`; comm may itself hold spaces and parentheses.
fn parse_stat(stat: []const u8) ?Stat {
    const open = mem.findScalar(u8, stat, '(') orelse return null;
    const close = mem.findScalarLast(u8, stat, ')') orelse return null;
    if (close < open or close + 3 > stat.len) return null;
    var fields = mem.tokenizeScalar(u8, stat[close + 2 ..], ' ');
    _ = fields.next() orelse return null;
    const ppid = std.fmt.parseInt(std.os.linux.pid_t, fields.next() orelse return null, 10) catch
        return null;
    return .{ .comm = stat[open + 1 .. close], .ppid = ppid };
}

test "parse_stat: comm with spaces and parentheses" {
    const stat = parse_stat("4242 (a) b (c)) S 17 4242 4242 0 -1").?;
    try std.testing.expectEqualStrings("a) b (c)", stat.comm);
    try std.testing.expectEqual(@as(std.os.linux.pid_t, 17), stat.ppid);
    try std.testing.expect(parse_stat("4242 (foot") == null);
    try std.testing.expect(parse_stat("4242 (foot) S") == null);
}

test "is_shell: known shells and the login shell, cut to the 15-byte comm" {
    try std.testing.expect(is_shell("bash", ""));
    try std.testing.expect(is_shell("hash-shell", "hash-shell"));
    try std.testing.expect(is_shell("a-very-long-she", "a-very-long-shell-name"));
    try std.testing.expect(!is_shell("hyperfine", "hash-shell"));
    try std.testing.expect(!is_shell("", ""));
}

test "colors: NO_COLOR, COLORTERM and TERM" {
    try std.testing.expectEqual(Colors{ .basic = false, .truecolor = false }, colors(&.{
        .NO_COLOR = "1",
        .COLORTERM = "truecolor",
    }));
    try std.testing.expectEqual(Colors{ .basic = true, .truecolor = true }, colors(&.{
        .COLORTERM = "24bit",
    }));
    try std.testing.expectEqual(Colors{ .basic = true, .truecolor = false }, colors(&.{
        .TERM = "foot",
    }));
    try std.testing.expectEqual(Colors{ .basic = true, .truecolor = false }, colors(&.{
        .TERM = "weird-256color",
    }));
}

test "name: TERM_PROGRAM, then a TERM one emulator owns" {
    try std.testing.expectEqualStrings("warp", name(&.{ .TERM_PROGRAM = "WarpTerminal" }));
    const vscode = name(&.{ .TERM_PROGRAM = "vscode", .TERM = "foot" });
    try std.testing.expectEqualStrings("vscode", vscode);
    try std.testing.expectEqualStrings("foot", name(&.{ .TERM = "foot-extra" }));
    try std.testing.expectEqualStrings("kitty", name(&.{ .TERM = "xterm-kitty" }));
}
