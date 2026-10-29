const std = @import("std");

pub const Env = struct {
    HOME: ?[:0]const u8 = null,
    USER: ?[:0]const u8 = null,
    SHELL: ?[:0]const u8 = null,
    TERM: ?[:0]const u8 = null,
    TERM_PROGRAM: ?[:0]const u8 = null,
    COLORTERM: ?[:0]const u8 = null,
    NO_COLOR: ?[:0]const u8 = null,
    XDG_CURRENT_DESKTOP: ?[:0]const u8 = null,
    XDG_RUNTIME_DIR: ?[:0]const u8 = null,
    WAYLAND_DISPLAY: ?[:0]const u8 = null,
    DISPLAY: ?[:0]const u8 = null,
    DESKTOP_SESSION: ?[:0]const u8 = null,
    HYPRLAND_INSTANCE_SIGNATURE: ?[:0]const u8 = null,

    const names = @typeInfo(Env).@"struct".field_names;

    const initials = blk: {
        var letters: []const u8 = "";
        for (names) |name| {
            if (std.mem.findScalar(u8, letters, name[0]) == null) letters = letters ++ name[0..1];
        }
        break :blk letters;
    };

    /// The first definition of a name wins, as with getenv.
    pub fn init(block: std.process.Environ.Block) Env {
        var env: Env = .{};
        for (block.slice) |entry_ptr| {
            const entry = entry_ptr orelse continue;
            inline for (initials) |initial| {
                if (entry[0] == initial) {
                    inline for (names) |name| {
                        if (name[0] != initial) continue;
                        if (@field(env, name) == null and has_prefix(entry, name ++ "=")) {
                            @field(env, name) = std.mem.span(entry + name.len + 1);
                        }
                    }
                }
            }
        }
        return env;
    }
};

// Byte by byte: stopping at the first mismatch never reads past the terminating NUL.
fn has_prefix(entry: [*:0]const u8, comptime prefix: []const u8) bool {
    inline for (prefix, 0..) |byte, i| {
        if (entry[i] != byte) return false;
    }
    return true;
}

pub fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.findScalarLast(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

test "basename: trailing slashes and bare names" {
    try std.testing.expectEqualStrings("fish", basename("/usr/bin/fish"));
    try std.testing.expectEqualStrings("fish", basename("/usr/bin/fish/"));
    try std.testing.expectEqualStrings("fish", basename("fish"));
    try std.testing.expectEqualStrings("", basename(""));
}

test "Env: first definition wins and unknown names are skipped" {
    var entries = [_:null]?[*:0]u8{
        @constCast("TERM=foot"),
        @constCast("NOPE=1"),
        @constCast("TERM=xterm"),
        @constCast("USER="),
    };
    const env: Env = .init(.{ .slice = &entries });
    try std.testing.expectEqualStrings("foot", env.TERM.?);
    try std.testing.expectEqualStrings("", env.USER.?);
    try std.testing.expect(env.HOME == null);
}
