const std = @import("std");
const builtin = @import("builtin");

const fmt = @import("fmt.zig");
const log = @import("log.zig");
const fetch = @import("fetch/root.zig");

pub fn init() void {
    if (builtin.mode == .Debug) {
        const logger = log.ScopedLogger.init("debug");
        logger.info("Debug mode initialized", .{});
    }
}

pub fn isEnabled() bool {
    return builtin.mode == .Debug;
}

pub fn debugLog(comptime format: []const u8, args: anytype) void {
    if (!isEnabled()) return;
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ "\n", args) catch {};
}

pub fn dumpStruct(name: []const u8, value: anytype) void {
    if (!isEnabled()) return;

    std.debug.print("\nDEBUG DUMP: {s}\n", .{name});

    if (@TypeOf(value) == fetch.Fetch) {
        dumpFetch(value);
    } else {
        fmt.printStruct(value, false, 0);
    }
}

fn dumpFetch(fetch_info: fetch.Fetch) void {
    std.debug.print("Fetch (\n", .{});
    std.debug.print("  Config Format: \"{s}\"\n", .{fetch_info.config.format});

    var fields_buf: [256]u8 = undefined;
    var fields_fbs = std.io.fixedBufferStream(&fields_buf);
    var fields_writer = fields_fbs.writer();

    var first = true;
    inline for (comptime std.meta.fields(fetch.config.Placeholder)) |field| {
        if (!@hasDecl(fetch.config.Placeholder, field.name)) continue;

        const placeholder = @field(fetch.config.Placeholder, field.name);
        if (fetch_info.config.needsField(placeholder)) {
            if (!first) {
                fields_writer.writeAll(", ") catch break;
            }
            fields_writer.print("{s}", .{field.name}) catch break;
            first = false;
        }
    }

    std.debug.print("  Needed Fields: {s}\n", .{fields_buf[0..fields_fbs.pos]});
    std.debug.print("  Components:\n", .{});

    inline for (std.meta.fields(@TypeOf(fetch_info))) |field| {
        if (comptime std.mem.eql(u8, field.name, "config")) continue;
        if (comptime std.mem.eql(u8, field.name, "allocator")) continue;

        if (@typeInfo(field.type) == .optional) {
            if (@field(fetch_info, field.name)) |value| {
                dumpComponent(field.name, value);
            } else {
                std.debug.print("    {s}: not loaded\n", .{field.name});
            }
        } else {
            dumpComponent(field.name, @field(fetch_info, field.name));
        }
    }

    std.debug.print(")\n", .{});
}

fn dumpComponent(name: []const u8, component: anytype) void {
    const T = @TypeOf(component);

    if (std.mem.eql(u8, name, "terminal_info") and @hasField(T, "name") and @hasField(T, "color_support")) {
        const terminal = component;
        std.debug.print("    {s}: {s} (color support: truecolor={}, 256={}, basic={})\n", .{ name, terminal.name, terminal.color_support.truecolor, terminal.color_support.color256, terminal.color_support.basic });
        return;
    }

    if (std.mem.eql(u8, name, "uptime_info") and @hasField(T, "formatted") and @hasField(T, "seconds")) {
        const uptime = component;
        std.debug.print("    {s}: {s} ({d} seconds)\n", .{ name, uptime.formatted, uptime.seconds });
        return;
    }

    if (std.mem.eql(u8, name, "session_info") and @hasField(T, "desktop") and @hasField(T, "display_server")) {
        const session = component;
        std.debug.print("    {s}: desktop={s}, display_server={s}\n", .{ name, session.desktop, session.display_server });
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => {
            if (std.mem.eql(u8, name, "host_info") and @hasField(T, "hostname")) {
                std.debug.print("    {s}: {s}\n", .{ name, component.hostname });
            } else if (std.mem.eql(u8, name, "user_info") and @hasField(T, "username") and @hasField(T, "shell")) {
                std.debug.print("    {s}: {s}@{s}\n", .{ name, component.username, component.shell });
            } else if (std.mem.eql(u8, name, "pkg_info") and @hasField(T, "pkg_count")) {
                std.debug.print("    {s}: {d} packages\n", .{ name, component.pkg_count });
            } else if (std.mem.eql(u8, name, "distro_info") and @hasField(T, "name") and @hasField(T, "id")) {
                std.debug.print("    {s}: {s} ({s})\n", .{ name, component.name, component.id });
            } else if (std.mem.eql(u8, name, "wm_info") and @hasField(T, "name")) {
                std.debug.print("    {s}: {s}\n", .{ name, component.name });
            } else {
                std.debug.print("    {s}: [struct]\n", .{name});
            }
        },
        else => std.debug.print("    {s}: {any}\n", .{ name, component }),
    }
}
