const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;

const color = @import("color.zig");
const log = @import("log.zig");

const default_config = @embedFile("config");

pub const ConfigError = error{
    HomeDirNotFound,
    ConfigDirCreationFailed,
    ConfigFileCreationFailed,
    ConfigFileReadFailed,
    ConfigParseError,
    OutOfMemory,
    InvalidColorFormat,
    InvalidStyleFormat,
};

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

    pub fn symbol(self: Placeholder) []const u8 {
        return switch (self) {
            .user => "{user}",
            .host => "{host}",
            .shell => "{shell}",
            .term => "{term}",
            .uptime => "{uptime}",
            .pkgs => "{pkgs}",
            .session => "{session}",
            .distro => "{distro}",
            .distro_pretty => "{distro_pretty}",
            .wm => "{wm}",
        };
    }
};

fn getColorForTag(tag: []const u8) ?color.Color {
    if (mem.eql(u8, tag, "black")) return .black;
    if (mem.eql(u8, tag, "red")) return .red;
    if (mem.eql(u8, tag, "green")) return .green;
    if (mem.eql(u8, tag, "yellow")) return .yellow;
    if (mem.eql(u8, tag, "blue")) return .blue;
    if (mem.eql(u8, tag, "magenta")) return .magenta;
    if (mem.eql(u8, tag, "cyan")) return .cyan;
    if (mem.eql(u8, tag, "white")) return .white;
    return null;
}

fn getStyleForTag(tag: []const u8) ?[]const u8 {
    if (mem.eql(u8, tag, "bold")) return color.Style.bold;
    if (mem.eql(u8, tag, "dim")) return color.Style.dim;
    if (mem.eql(u8, tag, "italic")) return color.Style.italic;
    if (mem.eql(u8, tag, "underline")) return color.Style.underline;
    if (mem.eql(u8, tag, "blink")) return color.Style.blink;
    if (mem.eql(u8, tag, "reverse")) return color.Style.reverse;
    if (mem.eql(u8, tag, "hidden")) return color.Style.hidden;
    if (mem.eql(u8, tag, "strike")) return color.Style.strike;
    return null;
}

fn parseRgbTag(tag: []const u8) !color.Rgb {
    if (!mem.startsWith(u8, tag, "rgb(") or !mem.endsWith(u8, tag, ")")) {
        return ConfigError.InvalidColorFormat;
    }

    const rgb_content = tag[4 .. tag.len - 1];
    var values: [3]u8 = undefined;
    var value_idx: usize = 0;
    var num_start: usize = 0;

    for (rgb_content, 0..) |c, i| {
        if (c == ',' or i == rgb_content.len - 1) {
            const num_end = if (i == rgb_content.len - 1) i + 1 else i;
            const num_str = mem.trim(u8, rgb_content[num_start..num_end], &std.ascii.whitespace);
            values[value_idx] = std.fmt.parseInt(u8, num_str, 10) catch return ConfigError.InvalidColorFormat;
            value_idx += 1;
            if (value_idx > 2) break;
            num_start = i + 1;
        }
    }

    if (value_idx != 3) return ConfigError.InvalidColorFormat;
    return color.Rgb.init(values[0], values[1], values[2]);
}

pub const Config = struct {
    format: []const u8 = default_config,
    needed_fields: std.EnumSet(Placeholder) = .{},

    var config_buf: [2048]u8 = undefined;
    var arena: std.heap.ArenaAllocator = undefined;
    var logger: log.ScopedLogger = undefined;

    pub fn getAllocator() mem.Allocator {
        return arena.allocator();
    }

    fn getOrCreateConfigFile(allocator: mem.Allocator) ![]const u8 {
        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
            logger.err("HOME environment variable not found", .{});
            return ConfigError.HomeDirNotFound;
        };
        defer allocator.free(home_dir);

        const config_dir = try fs.path.join(allocator, &.{ home_dir, ".config", "lifetch" });
        defer allocator.free(config_dir);

        fs.makeDirAbsolute(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                logger.err("Failed to create config directory: {}", .{err});
                return ConfigError.ConfigDirCreationFailed;
            }
        };

        const config_path = try fs.path.join(allocator, &.{ config_dir, "config" });

        if (fs.openFileAbsolute(config_path, .{ .mode = .read_only })) |file| {
            file.close();
        } else |_| {
            logger.info("Creating default config file", .{});
            const file = try fs.createFileAbsolute(config_path, .{});
            defer file.close();
            try file.writeAll(default_config);
        }

        return config_path;
    }

    fn validateFormat(format: []const u8) !void {
        if (format.len == 0) {
            logger.err("Empty format string", .{});
            return ConfigError.ConfigParseError;
        }

        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] == '{') {
                const end_idx = mem.indexOfScalarPos(u8, format, i, '}') orelse {
                    logger.err("Unclosed tag at position {}", .{i});
                    return ConfigError.ConfigParseError;
                };
                const tag = format[i + 1 .. end_idx];

                if (mem.startsWith(u8, tag, "/")) {
                    i = end_idx;
                    continue;
                }

                if (mem.startsWith(u8, tag, "rgb(")) {
                    _ = parseRgbTag(tag) catch {
                        logger.err("Invalid RGB format: {s}", .{tag});
                        return ConfigError.InvalidColorFormat;
                    };
                } else if (getColorForTag(tag) == null and getStyleForTag(tag) == null) {
                    var valid = false;
                    inline for (std.meta.fields(Placeholder)) |field| {
                        const ph = @field(Placeholder, field.name);
                        if (mem.eql(u8, format[i .. end_idx + 1], ph.symbol())) {
                            valid = true;
                            break;
                        }
                    }
                    if (!valid) {
                        logger.err("Invalid tag: {s}", .{tag});
                        return ConfigError.ConfigParseError;
                    }
                }

                i = end_idx;
            }
        }
    }

    fn detectNeededFields(format: []const u8) std.EnumSet(Placeholder) {
        var fields = std.EnumSet(Placeholder){};
        inline for (std.meta.fields(Placeholder)) |field| {
            const placeholder = @field(Placeholder, field.name);
            if (mem.indexOf(u8, format, placeholder.symbol()) != null) {
                fields.insert(placeholder);
                logger.debug("Detected needed field: {s}", .{field.name});
            }
        }
        return fields;
    }

    pub fn init() !Config {
        logger = log.ScopedLogger.init("config");
        logger.info("Initializing config", .{});

        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        var self = Config{};

        const config_path = try getOrCreateConfigFile(arena.allocator());
        defer arena.allocator().free(config_path);

        const file = fs.openFileAbsolute(config_path, .{ .mode = .read_only }) catch {
            logger.err("Failed to open config file: {s}", .{config_path});
            return ConfigError.ConfigFileReadFailed;
        };
        defer file.close();

        const bytes_read = file.readAll(&config_buf) catch {
            logger.err("Failed to read config file", .{});
            return ConfigError.ConfigFileReadFailed;
        };

        var format_lines = std.ArrayList(u8).init(arena.allocator());
        defer format_lines.deinit();

        var lines = mem.splitScalar(u8, config_buf[0..bytes_read], '\n');
        var found_format = false;

        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (!found_format) {
                if (mem.startsWith(u8, trimmed, "format = ")) {
                    found_format = true;
                    try format_lines.appendSlice(trimmed["format = ".len..]);
                }
            } else {
                try format_lines.append('\n');
                try format_lines.appendSlice(trimmed);
            }
        }

        if (format_lines.items.len > 0) {
            self.format = try arena.allocator().dupe(u8, format_lines.items);
            try validateFormat(self.format);
            self.needed_fields = detectNeededFields(self.format);
            logger.info("Successfully loaded config with format length: {}", .{self.format.len});
        } else {
            logger.warn("No format found in config, using default", .{});
        }

        return self;
    }

    pub fn deinit(self: *Config) void {
        logger.debug("Cleaning up config resources", .{});
        _ = self;
        arena.deinit();
    }

    pub fn needsField(self: *const Config, field: Placeholder) bool {
        return self.needed_fields.contains(field);
    }

    pub fn formatText(self: *const Config, text: []const u8, writer: anytype) !void {
        _ = self;
        const color_support = @import("fetch/terminal.zig").getColorSupport();
        try color_support.formatText(text, writer);
    }
};
