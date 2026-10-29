const std = @import("std");
const mem = std.mem;

const Out = @import("out.zig").Out;

pub const Placeholder = enum {
    user,
    host,
    shell,
    term,
    uptime,
    pkgs,
    session,
    distro,
    distro_pretty,
    wm,
};

pub const Fields = std.EnumSet(Placeholder);
pub const Values = std.EnumArray(Placeholder, []const u8);

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Colors = struct { basic: bool, truecolor: bool };

pub const Tag = union(enum) {
    reset,
    placeholder: Placeholder,
    color: []const u8,
    style: []const u8,
    rgb: Rgb,
};

const Named = struct { name: []const u8, sequence: []const u8 };

const colors = [_]Named{
    .{ .name = "black", .sequence = "\x1b[30m" },
    .{ .name = "red", .sequence = "\x1b[31m" },
    .{ .name = "green", .sequence = "\x1b[32m" },
    .{ .name = "yellow", .sequence = "\x1b[33m" },
    .{ .name = "blue", .sequence = "\x1b[34m" },
    .{ .name = "magenta", .sequence = "\x1b[35m" },
    .{ .name = "cyan", .sequence = "\x1b[36m" },
    .{ .name = "white", .sequence = "\x1b[37m" },
};

const styles = [_]Named{
    .{ .name = "bold", .sequence = "\x1b[1m" },
    .{ .name = "dim", .sequence = "\x1b[2m" },
    .{ .name = "italic", .sequence = "\x1b[3m" },
    .{ .name = "underline", .sequence = "\x1b[4m" },
    .{ .name = "blink", .sequence = "\x1b[5m" },
    .{ .name = "reverse", .sequence = "\x1b[7m" },
    .{ .name = "hidden", .sequence = "\x1b[8m" },
    .{ .name = "strike", .sequence = "\x1b[9m" },
};

const Word = struct { name: []const u8, tag: Tag };

const words = blk: {
    var list: []const Word = &.{};
    for (std.enums.values(Placeholder)) |placeholder| {
        const tag: Tag = .{ .placeholder = placeholder };
        list = list ++ [_]Word{.{ .name = @tagName(placeholder), .tag = tag }};
    }
    for (colors) |color| {
        list = list ++ [_]Word{.{ .name = color.name, .tag = .{ .color = color.sequence } }};
    }
    for (styles) |style| {
        list = list ++ [_]Word{.{ .name = style.name, .tag = .{ .style = style.sequence } }};
    }
    break :blk list;
};

const word_len_max = blk: {
    var max: usize = 0;
    for (words) |word| max = @max(max, word.name.len);
    break :blk max;
};

/// `name` is the text between the braces.
pub fn parse_tag(name: []const u8) ?Tag {
    if (name.len == 0) return null;
    if (name[0] == '/') return .reset;
    if (mem.startsWith(u8, name, "rgb(")) return .{ .rgb = parse_rgb(name) orelse return null };
    if (name.len > word_len_max) return null;
    switch (name.len) {
        inline 1...word_len_max => |len| {
            const Bits = @Int(.unsigned, len * 8);
            const text: Bits = @bitCast(name[0..len].*);
            inline for (words) |word| {
                if (word.name.len != len) continue;
                const expected: Bits = comptime @bitCast(word.name[0..len].*);
                if (text == expected) return word.tag;
            }
            return null;
        },
        else => unreachable,
    }
}

fn parse_rgb(name: []const u8) ?Rgb {
    if (!mem.endsWith(u8, name, ")")) return null;
    var parts = mem.splitScalar(u8, name["rgb(".len .. name.len - 1], ',');
    var rgb: [3]u8 = undefined;
    for (&rgb) |*channel| {
        const part = mem.trim(u8, parts.next() orelse return null, &std.ascii.whitespace);
        channel.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

/// Validates every tag and returns the placeholders `format` uses. On error, `invalid` holds the
/// offending `{...}`, or the unclosed tail.
pub fn scan(format: []const u8, invalid: *[]const u8) error{InvalidFormat}!Fields {
    var fields: Fields = .empty;
    invalid.* = format;
    if (format.len == 0) return error.InvalidFormat;
    var rest = format;
    while (mem.findScalar(u8, rest, '{')) |open| {
        const close = mem.findScalarPos(u8, rest, open, '}') orelse {
            invalid.* = rest[open..];
            return error.InvalidFormat;
        };
        const tag = parse_tag(rest[open + 1 .. close]) orelse {
            invalid.* = rest[open .. close + 1];
            return error.InvalidFormat;
        };
        if (tag == .placeholder) fields.insert(tag.placeholder);
        rest = rest[close + 1 ..];
    }
    return fields;
}

/// `format` must have passed `scan`. Values are written verbatim, colors the terminal lacks are
/// dropped, and styles and resets are always written.
pub fn render(format: []const u8, values: *const Values, support: Colors, out: *Out) void {
    var rest = format;
    while (mem.findScalar(u8, rest, '{')) |open| {
        out.write(rest[0..open]);
        const close = mem.findScalarPos(u8, rest, open, '}').?;
        switch (parse_tag(rest[open + 1 .. close]).?) {
            .reset => out.write("\x1b[0m"),
            .placeholder => |placeholder| out.write(values.get(placeholder)),
            .style => |sequence| out.write(sequence),
            .color => |sequence| if (support.basic) out.write(sequence),
            .rgb => |rgb| if (support.truecolor) {
                out.write("\x1b[38;2;");
                out.write_uint(rgb.r);
                out.write(";");
                out.write_uint(rgb.g);
                out.write(";");
                out.write_uint(rgb.b);
                out.write("m");
            },
        }
        rest = rest[close + 1 ..];
    }
    out.write(rest);
}

test "scan: collects placeholders and rejects malformed tags" {
    var invalid: []const u8 = undefined;
    const fields = try scan("{bold}{user}@{host}{/bold} {rgb(1, 2,3)}{pkgs}{/rgb}", &invalid);
    try std.testing.expect(fields.contains(.user));
    try std.testing.expect(fields.contains(.host));
    try std.testing.expect(fields.contains(.pkgs));
    try std.testing.expect(!fields.contains(.wm));

    try std.testing.expectError(error.InvalidFormat, scan("{nope}", &invalid));
    try std.testing.expectEqualStrings("{nope}", invalid);
    try std.testing.expectError(error.InvalidFormat, scan("x {user", &invalid));
    try std.testing.expectEqualStrings("{user", invalid);
    try std.testing.expectError(error.InvalidFormat, scan("{rgb(1,2)}", &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("{rgb(1,2,3,4)}", &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("{rgb(1,2,256)}", &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("{}", &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("", &invalid));
}

test "scan: an accepted format renders with every tag consumed" {
    try std.testing.fuzz({}, fuzz_scan_render, .{ .corpus = &.{
        "{bold}{cyan}{user}@{host}{/cyan}{/bold} since: {uptime}",
        "{rgb(255, 0,0)}x{/rgb}{distro_pretty}",
        "{rgb(1,2)}",
        "a{",
        "}{}{/}",
    } });
}

fn fuzz_scan_render(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var invalid: []const u8 = undefined;
    _ = scan(input, &invalid) catch {
        const start = @intFromPtr(invalid.ptr) - @intFromPtr(input.ptr);
        try std.testing.expect(start + invalid.len <= input.len);
        return;
    };
    const values: Values = .initFill("v");
    var out: Out = undefined;
    out.init(-1);
    render(input, &values, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expect(!out.failed);
    try std.testing.expect(mem.findScalar(u8, out.buf[0..out.len], '{') == null);
}

test "render: values stay literal and unsupported colors drop" {
    var invalid: []const u8 = undefined;
    const format = "{bold}{red}{user}{/red}{/bold} {rgb(1,2,3)}{term}";
    _ = try scan(format, &invalid);
    var values: Values = .initFill("?");
    values.set(.user, "{red}me");
    values.set(.term, "foot");

    var out: Out = undefined;
    out.init(-1);
    render(format, &values, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[31m{red}me\x1b[0m\x1b[0m \x1b[38;2;1;2;3mfoot",
        out.buf[0..out.len],
    );

    out.len = 0;
    render(format, &values, .{ .basic = false, .truecolor = false }, &out);
    try std.testing.expectEqualStrings("\x1b[1m{red}me\x1b[0m\x1b[0m foot", out.buf[0..out.len]);
}
