const std = @import("std");
const mem = std.mem;

const Opts = @import("out.zig").Opts;
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
    kernel,
    cpu,
    cpu_cores,
    cpu_threads,
    cpu_percent,
    load,
    mem,
    mem_used,
    mem_total,
    mem_percent,
    swap,
    swap_used,
    swap_total,
    swap_percent,
    disk,
    disk_used,
    disk_total,
    disk_percent,
    disks,
    gpu,
    gpu_vram,
    gpu_percent,
    gpus,
};

pub const Fields = std.EnumSet(Placeholder);

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Colors = struct { basic: bool, truecolor: bool };

/// A user color from `color.<name> =`: an escape sequence of a basic name, or an rgb triple
/// that only truecolor terminals get.
pub const ColorValue = union(enum) {
    basic: []const u8,
    rgb: Rgb,
};

/// Longest user variable name the config parser accepts.
pub const var_name_max = 32;
/// Longest user variable value or separator.
pub const var_value_max = 64;

/// A fixed-capacity string owned by its struct, so `Settings` is a plain value with no lifetimes
/// to track between the config file and rendering.
pub const Text = struct {
    len: u8 = 0,
    buf: [var_value_max]u8 = @splat(0),

    /// Comptime-checked: a constant longer than `var_value_max` fails the build.
    pub fn init(value: []const u8) Text {
        var self: Text = .{};
        const ok = self.set(value);
        std.debug.assert(ok);
        return self;
    }

    /// False when `value` does not fit.
    pub fn set(self: *Text, value: []const u8) bool {
        if (value.len > self.buf.len) return false;
        @memcpy(self.buf[0..value.len], value);
        self.len = @intCast(value.len);
        return true;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const palette_max = 8;

pub const TextVar = struct { name: Text = .{}, value: Text = .{} };
pub const ColorVar = struct { name: Text = .{}, value: ColorValue = .{ .basic = "" } };

/// What the config file defines for `{@name}` and `{color.name}`. User names live under sigils
/// built-in tags never use, so nothing here can collide with a placeholder added later. The
/// first definition of a name wins, as with getenv.
pub const Palette = struct {
    texts: [palette_max]TextVar = @splat(.{}),
    text_count: usize = 0,
    colors: [palette_max]ColorVar = @splat(.{}),
    color_count: usize = 0,

    pub const PutError = error{ TooLong, PaletteFull };

    pub fn put_text(self: *Palette, name: []const u8, value: []const u8) PutError!void {
        if (self.find_text(name) != null) return;
        if (self.text_count == palette_max) return error.PaletteFull;
        var entry: TextVar = .{};
        if (!entry.name.set(name) or !entry.value.set(value)) return error.TooLong;
        self.texts[self.text_count] = entry;
        self.text_count += 1;
    }

    pub fn put_color(self: *Palette, name: []const u8, value: ColorValue) PutError!void {
        if (self.find_color(name) != null) return;
        if (self.color_count == palette_max) return error.PaletteFull;
        var entry: ColorVar = .{ .value = value };
        if (!entry.name.set(name)) return error.TooLong;
        self.colors[self.color_count] = entry;
        self.color_count += 1;
    }

    pub fn text(self: *const Palette, name: []const u8) ?[]const u8 {
        const i = self.find_text(name) orelse return null;
        return self.texts[i].value.slice();
    }

    pub fn color(self: *const Palette, name: []const u8) ?ColorValue {
        const i = self.find_color(name) orelse return null;
        return self.colors[i].value;
    }

    fn find_text(self: *const Palette, name: []const u8) ?usize {
        for (0..self.text_count) |i| {
            if (mem.eql(u8, self.texts[i].name.slice(), name)) return i;
        }
        return null;
    }

    fn find_color(self: *const Palette, name: []const u8) ?usize {
        for (0..self.color_count) |i| {
            if (mem.eql(u8, self.colors[i].name.slice(), name)) return i;
        }
        return null;
    }
};

/// Everything the template language needs beyond the values themselves: size formatting, the
/// user's palette and the separators that join multi-entry placeholders.
pub const Settings = struct {
    opts: Opts = .{},
    palette: Palette = .{},
    sep_disk: Text = Text.init(" · "),
    sep_gpu: Text = Text.init(" · "),
};

pub const Tag = union(enum) {
    reset,
    placeholder: Placeholder,
    param: struct { id: Placeholder, arg: []const u8 },
    color: []const u8,
    style: []const u8,
    rgb: Rgb,
    user_text: []const u8,
    user_color: []const u8,
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

/// Placeholders whose word accepts an optional `word(arg)` argument.
fn takes_arg(id: Placeholder) bool {
    return switch (id) {
        .disk, .disk_used, .disk_total, .disk_percent, .gpu, .gpu_vram, .gpu_percent => true,
        else => false,
    };
}

/// `name` is the text between the braces. `{word(arg)}` becomes `.param` for the disk and gpu
/// families; `{@name}` and `{color.name}` are user palette tags that `scan` checks against the
/// palette.
pub fn parse_tag(name: []const u8) ?Tag {
    if (name.len == 0) return null;
    if (name[0] == '/') return .reset;
    if (mem.startsWith(u8, name, "rgb(")) return .{ .rgb = parse_rgb(name) orelse return null };
    if (name[0] == '@') return if (name.len > 1) .{ .user_text = name[1..] } else null;
    if (mem.startsWith(u8, name, "color.")) {
        return if (name.len > "color.".len) .{ .user_color = name["color.".len..] } else null;
    }
    if (mem.findScalar(u8, name, '(')) |open| {
        if (name[name.len - 1] != ')') return null;
        const tag = match_word(name[0..open]) orelse return null;
        if (tag != .placeholder or !takes_arg(tag.placeholder)) return null;
        const arg = name[open + 1 .. name.len - 1];
        return if (arg.len > 0) .{ .param = .{ .id = tag.placeholder, .arg = arg } } else null;
    }
    return match_word(name);
}

fn match_word(name: []const u8) ?Tag {
    if (name.len == 0 or name.len > word_len_max) return null;
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
    const value = parse_channels(name["rgb(".len .. name.len - 1]) orelse return null;
    return value.rgb;
}

/// Three decimal channels, the shared shape of `rgb(...)` and `color.<name> = r,g,b`.
fn parse_channels(text: []const u8) ?ColorValue {
    var parts = mem.splitScalar(u8, text, ',');
    var rgb: [3]u8 = undefined;
    for (&rgb) |*channel| {
        const part = mem.trim(u8, parts.next() orelse return null, &std.ascii.whitespace);
        channel.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return .{ .rgb = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } };
}

/// `color.<name> =` values: "r,g,b" decimals, "#rrggbb", or a basic color name. A basic name
/// yields the same sequence the built-in tag would.
pub fn parse_color_value(value: []const u8) ?ColorValue {
    const text = mem.trim(u8, value, &std.ascii.whitespace);
    if (text.len == 7 and text[0] == '#') {
        return .{ .rgb = .{
            .r = std.fmt.parseInt(u8, text[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, text[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, text[5..7], 16) catch return null,
        } };
    }
    if (mem.findScalar(u8, text, ',') != null) return parse_channels(text);
    for (colors) |named| {
        if (mem.eql(u8, named.name, text)) return .{ .basic = named.sequence };
    }
    return null;
}

/// Room for any value: one slot piece, or a joined `{disks}`/`{gpus}` list written straight to
/// the output. Placeholder pieces live in `plain` or the slot tables below.
pub const disk_slots_max = 8;
pub const gpu_slots_max = 4;

pub const DiskSlot = struct {
    mount: []const u8,
    dev: []const u8,
    used: []const u8,
    total: []const u8,
    percent: []const u8,
    composite: []const u8,
};

pub const GpuSlot = struct { name: []const u8, vram: []const u8, busy: []const u8 };

pub const Values = struct {
    plain: std.EnumArray(Placeholder, []const u8),
    disks: [disk_slots_max]DiskSlot = undefined,
    disk_count: usize = 0,
    gpus: [gpu_slots_max]GpuSlot = undefined,
    gpu_count: usize = 0,

    pub fn initFill(text: []const u8) Values {
        return .{ .plain = .initFill(text) };
    }

    pub fn set(self: *Values, id: Placeholder, text: []const u8) void {
        self.plain.set(id, text);
    }
};

/// Validates every tag and returns the placeholders `format` uses. `{@name}` and `{color.name}`
/// must exist in `settings.palette`. On error, `invalid` holds the offending `{...}`, or the
/// unclosed tail.
pub fn scan(format: []const u8, settings: *const Settings, invalid: *[]const u8) error{InvalidFormat}!Fields {
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
        switch (tag) {
            .placeholder => |id| fields.insert(id),
            .param => |param| fields.insert(param.id),
            .user_text => |name| if (settings.palette.text(name) == null) {
                invalid.* = rest[open .. close + 1];
                return error.InvalidFormat;
            },
            .user_color => |name| if (settings.palette.color(name) == null) {
                invalid.* = rest[open .. close + 1];
                return error.InvalidFormat;
            },
            else => {},
        }
        rest = rest[close + 1 ..];
    }
    return fields;
}

/// `format` must have passed `scan`. Values are written verbatim, colors the terminal lacks are
/// dropped, and styles and resets are always written.
pub fn render(format: []const u8, values: *const Values, settings: *const Settings, support: Colors, out: *Out) void {
    var rest = format;
    while (mem.findScalar(u8, rest, '{')) |open| {
        out.write(rest[0..open]);
        const close = mem.findScalarPos(u8, rest, open, '}').?;
        switch (parse_tag(rest[open + 1 .. close]).?) {
            .reset => out.write("\x1b[0m"),
            .placeholder => |id| write_value(out, values, settings, id, null),
            .param => |param| write_value(out, values, settings, param.id, param.arg),
            .style => |sequence| out.write(sequence),
            .color => |sequence| if (support.basic) out.write(sequence),
            .rgb => |rgb| if (support.truecolor) write_rgb(out, rgb),
            .user_text => |name| out.write(settings.palette.text(name) orelse "unknown"),
            .user_color => |name| if (settings.palette.color(name)) |value| switch (value) {
                .basic => |sequence| if (support.basic) out.write(sequence),
                .rgb => |rgb| if (support.truecolor) write_rgb(out, rgb),
            },
        }
        rest = rest[close + 1 ..];
    }
    out.write(rest);
}

fn write_rgb(out: *Out, rgb: Rgb) void {
    out.write("\x1b[38;2;");
    out.write_uint(rgb.r);
    out.write(";");
    out.write_uint(rgb.g);
    out.write(";");
    out.write_uint(rgb.b);
    out.write("m");
}

fn write_value(out: *Out, values: *const Values, settings: *const Settings, id: Placeholder, arg: ?[]const u8) void {
    switch (id) {
        .disks => write_join(out, values.disks[0..values.disk_count], settings.sep_disk.slice(), .composite),
        .gpus => write_join(out, values.gpus[0..values.gpu_count], settings.sep_gpu.slice(), .name),
        .disk, .disk_used, .disk_total, .disk_percent => out.write(disk_value(values, id, arg)),
        .gpu, .gpu_vram, .gpu_percent => out.write(gpu_value(values, id, arg)),
        else => out.write(values.plain.get(id)),
    }
}

/// The pieces a joined multi-entry placeholder shows.
fn write_join(out: *Out, slots: anytype, sep: []const u8, comptime piece: std.meta.FieldEnum(@TypeOf(slots[0]))) void {
    if (slots.len == 0) return out.write("unknown");
    for (slots, 0..) |*slot, i| {
        if (i > 0) out.write(sep);
        out.write(@field(slot, @tagName(piece)));
    }
}

/// The piece of one disk slot: no argument is slot 0, a decimal argument an index, and any
/// other argument a mount path or device string. A miss is "unknown".
fn disk_value(values: *const Values, id: Placeholder, arg: ?[]const u8) []const u8 {
    const slot = find_disk(values.disks[0..values.disk_count], arg) orelse return "unknown";
    return switch (id) {
        .disk => slot.composite,
        .disk_used => slot.used,
        .disk_total => slot.total,
        .disk_percent => slot.percent,
        else => unreachable,
    };
}

fn find_disk(slots: []const DiskSlot, arg: ?[]const u8) ?*const DiskSlot {
    const a = arg orelse "";
    if (a.len == 0) return if (slots.len > 0) &slots[0] else null;
    if (std.fmt.parseInt(usize, a, 10)) |index| {
        return if (index < slots.len) &slots[index] else null;
    } else |_| {}
    for (slots) |*slot| {
        if (mem.eql(u8, slot.mount, a) or mem.eql(u8, slot.dev, a)) return slot;
    }
    return null;
}

/// The piece of one gpu slot: no argument is slot 0, a decimal argument an index. A miss is
/// "unknown".
fn gpu_value(values: *const Values, id: Placeholder, arg: ?[]const u8) []const u8 {
    const slot = find_gpu(values.gpus[0..values.gpu_count], arg) orelse return "unknown";
    return switch (id) {
        .gpu => slot.name,
        .gpu_vram => slot.vram,
        .gpu_percent => slot.busy,
        else => unreachable,
    };
}

fn find_gpu(slots: []const GpuSlot, arg: ?[]const u8) ?*const GpuSlot {
    const a = arg orelse "";
    if (a.len == 0) return if (slots.len > 0) &slots[0] else null;
    const index = std.fmt.parseInt(usize, a, 10) catch return null;
    return if (index < slots.len) &slots[index] else null;
}

test "scan: collects placeholders and rejects malformed tags" {
    const settings: Settings = .{};
    var invalid: []const u8 = undefined;
    const fields = try scan("{bold}{user}@{host}{/bold} {rgb(1, 2,3)}{pkgs}{/rgb}", &settings, &invalid);
    try std.testing.expect(fields.contains(.user));
    try std.testing.expect(fields.contains(.host));
    try std.testing.expect(fields.contains(.pkgs));
    try std.testing.expect(!fields.contains(.wm));

    try std.testing.expectError(error.InvalidFormat, scan("{nope}", &settings, &invalid));
    try std.testing.expectEqualStrings("{nope}", invalid);
    try std.testing.expectError(error.InvalidFormat, scan("x {user", &settings, &invalid));
    try std.testing.expectEqualStrings("{user", invalid);
    try std.testing.expectError(error.InvalidFormat, scan("{rgb(1,2)}", &settings, &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("{rgb(1,2,3,4)}", &settings, &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("{rgb(1,2,256)}", &settings, &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("{}", &settings, &invalid));
    try std.testing.expectError(error.InvalidFormat, scan("", &settings, &invalid));
}

test "parse_tag: parameterized, user and rejected forms" {
    const param = parse_tag("disk(/home)").?;
    try std.testing.expect(param == .param);
    try std.testing.expectEqual(Placeholder.disk, param.param.id);
    try std.testing.expectEqualStrings("/home", param.param.arg);

    const gpu_indexed = parse_tag("gpu(1)").?;
    try std.testing.expect(gpu_indexed == .param);
    try std.testing.expectEqual(Placeholder.gpu, gpu_indexed.param.id);
    try std.testing.expectEqualStrings("1", gpu_indexed.param.arg);

    try std.testing.expect(parse_tag("disk_used(0)").? == .param);
    const plain = parse_tag("disk").?;
    try std.testing.expect(plain == .placeholder);
    try std.testing.expectEqual(Placeholder.disk, plain.placeholder);
    try std.testing.expect(parse_tag("disk()") == null);
    try std.testing.expect(parse_tag("mem(x)") == null);
    try std.testing.expect(parse_tag("disks(1)") == null);
    try std.testing.expect(parse_tag("(x)") == null);
    try std.testing.expect(parse_tag("disk(x") == null);
    try std.testing.expect(parse_tag("user(1)") == null);

    const text_var = parse_tag("@label").?;
    try std.testing.expect(text_var == .user_text);
    try std.testing.expectEqualStrings("label", text_var.user_text);
    try std.testing.expect(parse_tag("@") == null);

    const color_var = parse_tag("color.accent").?;
    try std.testing.expect(color_var == .user_color);
    try std.testing.expectEqualStrings("accent", color_var.user_color);
    try std.testing.expect(parse_tag("color.") == null);
}

test "scan: user tags validate against the palette" {
    var settings: Settings = .{};
    try settings.palette.put_text("label", "ram:");
    try settings.palette.put_color("accent", .{ .rgb = .{ .r = 180, .g = 142, .b = 173 } });
    var invalid: []const u8 = undefined;

    const fields = try scan("{@label}{color.accent}{disk(/)}{gpu(1)}", &settings, &invalid);
    try std.testing.expect(fields.contains(.disk));
    try std.testing.expect(fields.contains(.gpu));

    try std.testing.expectError(error.InvalidFormat, scan("{@missing}", &settings, &invalid));
    try std.testing.expectEqualStrings("{@missing}", invalid);
    try std.testing.expectError(error.InvalidFormat, scan("{color.missing}", &settings, &invalid));
    try std.testing.expectEqualStrings("{color.missing}", invalid);
}

test "palette: first definition wins, capacity and length limits" {
    var palette: Palette = .{};
    var long_name: [var_value_max + 1]u8 = @splat('x');
    try std.testing.expectError(error.TooLong, palette.put_text(&long_name, "1"));
    var long_value: [var_value_max + 1]u8 = @splat('y');
    try std.testing.expectError(error.TooLong, palette.put_text("y", &long_value));
    try std.testing.expectError(error.TooLong, palette.put_color(&long_name, .{ .basic = "" }));

    try palette.put_text("a", "1");
    try palette.put_text("a", "2");
    try std.testing.expectEqualStrings("1", palette.text("a").?);
    try std.testing.expect(palette.text("b") == null);

    var name: [2]u8 = undefined;
    for (0..palette_max - 1) |i| {
        name = .{ 'n', '0' + @as(u8, @intCast(i)) };
        try palette.put_text(&name, "x");
    }
    try std.testing.expectError(error.PaletteFull, palette.put_text("last", "1"));
}

test "render: values stay literal and unsupported colors drop" {
    const settings: Settings = .{};
    var invalid: []const u8 = undefined;
    const format = "{bold}{red}{user}{/red}{/bold} {rgb(1,2,3)}{term}";
    _ = try scan(format, &settings, &invalid);
    var values: Values = .initFill("?");
    values.set(.user, "{red}me");
    values.set(.term, "foot");

    var out: Out = undefined;
    out.init(-1);
    render(format, &values, &settings, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[31m{red}me\x1b[0m\x1b[0m \x1b[38;2;1;2;3mfoot",
        out.buf[0..out.len],
    );

    out.len = 0;
    render(format, &values, &settings, .{ .basic = false, .truecolor = false }, &out);
    try std.testing.expectEqualStrings("\x1b[1m{red}me\x1b[0m\x1b[0m foot", out.buf[0..out.len]);
}

test "render: disk and gpu slots resolve by index, mount and device" {
    const settings: Settings = .{};
    var values: Values = .initFill("plain");
    values.disk_count = 2;
    values.disks[0] = .{
        .mount = "/",
        .dev = "/dev/sda1",
        .used = "39G",
        .total = "50G",
        .percent = "79%",
        .composite = "39G / 50G (79%)",
    };
    values.disks[1] = .{
        .mount = "/home",
        .dev = "/dev/sda2",
        .used = "1.6T",
        .total = "1.9T",
        .percent = "84%",
        .composite = "1.6T / 1.9T (84%)",
    };
    values.gpu_count = 1;
    values.gpus[0] = .{ .name = "NVIDIA GeForce RTX 4070 Laptop GPU", .vram = "unknown", .busy = "12%" };

    var out: Out = undefined;
    out.init(-1);
    const disks = "{disk}|{disk(/home)}|{disk(1)}|{disk(/dev/sda2)}|{disk_used(/)}|{disk(nope)}|{disks}";
    render(disks, &values, &settings, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expectEqualStrings(
        "39G / 50G (79%)|1.6T / 1.9T (84%)|1.6T / 1.9T (84%)|1.6T / 1.9T (84%)" ++
            "|39G|unknown|39G / 50G (79%) · 1.6T / 1.9T (84%)",
        out.buf[0..out.len],
    );

    out.len = 0;
    render("{gpu}|{gpu_vram}|{gpu_percent}|{gpu(1)}|{gpus}", &values, &settings, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expectEqualStrings(
        "NVIDIA GeForce RTX 4070 Laptop GPU|unknown|12%|unknown|NVIDIA GeForce RTX 4070 Laptop GPU",
        out.buf[0..out.len],
    );

    out.len = 0;
    values.disk_count = 0;
    values.gpu_count = 0;
    render("{disk}|{disks}|{gpu}|{gpus}", &values, &settings, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expectEqualStrings("unknown|unknown|unknown|unknown", out.buf[0..out.len]);
}

test "render: user text verbatim, user colors by terminal support" {
    var settings: Settings = .{};
    try settings.palette.put_text("label", "ram:");
    try settings.palette.put_color("accent", .{ .rgb = .{ .r = 180, .g = 142, .b = 173 } });
    try settings.palette.put_color("warn", .{ .basic = "\x1b[31m" });
    var invalid: []const u8 = undefined;
    const format = "{@label} {color.accent}x{/} {color.warn}y{/}";
    _ = try scan(format, &settings, &invalid);

    var values: Values = .initFill("");
    var out: Out = undefined;
    out.init(-1);
    render(format, &values, &settings, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expectEqualStrings(
        "ram: \x1b[38;2;180;142;173mx\x1b[0m \x1b[31my\x1b[0m",
        out.buf[0..out.len],
    );

    out.len = 0;
    render(format, &values, &settings, .{ .basic = true, .truecolor = false }, &out);
    try std.testing.expectEqualStrings("ram: x\x1b[0m \x1b[31my\x1b[0m", out.buf[0..out.len]);

    out.len = 0;
    render(format, &values, &settings, .{ .basic = false, .truecolor = false }, &out);
    try std.testing.expectEqualStrings("ram: x\x1b[0m y\x1b[0m", out.buf[0..out.len]);
}

test "parse_color_value: rgb triples, hex and basic names" {
    const triple = parse_color_value("180, 142,173").?;
    try std.testing.expect(triple == .rgb);
    try std.testing.expectEqual(Rgb{ .r = 180, .g = 142, .b = 173 }, triple.rgb);

    const hex = parse_color_value("#ff8800").?;
    try std.testing.expect(hex == .rgb);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 136, .b = 0 }, hex.rgb);

    const named = parse_color_value("magenta").?;
    try std.testing.expect(named == .basic);
    try std.testing.expectEqualStrings("\x1b[35m", named.basic);

    try std.testing.expect(parse_color_value("nope") == null);
    try std.testing.expect(parse_color_value("300,1,1") == null);
    try std.testing.expect(parse_color_value("#ff88") == null);
    try std.testing.expect(parse_color_value("1,2") == null);
    try std.testing.expect(parse_color_value("1,2,3,4") == null);
    try std.testing.expect(parse_color_value("") == null);
}

test "scan: an accepted format renders with every tag consumed" {
    try std.testing.fuzz({}, fuzz_scan_render, .{ .corpus = &.{
        "{bold}{cyan}{user}@{host}{/cyan}{/bold} since: {uptime}",
        "{rgb(255, 0,0)}x{/rgb}{distro_pretty}",
        "{rgb(1,2)}",
        "a{",
        "}{}{/}",
        "{disk(/home)}{gpu(0)}",
        "{@a}{color.b}",
    } });
}

fn fuzz_scan_render(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var settings: Settings = .{};
    try settings.palette.put_text("a", "v");
    try settings.palette.put_color("b", .{ .basic = "\x1b[31m" });
    var invalid: []const u8 = undefined;
    _ = scan(input, &settings, &invalid) catch {
        const start = @intFromPtr(invalid.ptr) - @intFromPtr(input.ptr);
        try std.testing.expect(start + invalid.len <= input.len);
        return;
    };
    const values: Values = .initFill("v");
    var out: Out = undefined;
    out.init(-1);
    render(input, &values, &settings, .{ .basic = true, .truecolor = true }, &out);
    try std.testing.expect(!out.failed);
    try std.testing.expect(mem.findScalar(u8, out.buf[0..out.len], '{') == null);
}
