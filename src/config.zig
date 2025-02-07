const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const log = @import("log.zig");
const color = @import("color.zig");
const ComptimeStringMap = std.ComptimeStringMap;

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

const default_config =
    \\# Lifetch Configuration
    \\#
    \\# Format your output using these placeholders:
    \\# {user}     - Current username
    \\# {host}     - Hostname
    \\# {shell}    - Current shell
    \\# {term}     - Terminal name
    \\# {uptime}   - System uptime
    \\# {pkgs}     - Package count
    \\# {session}  - Wayland/X11
    \\#
    \\# Colors and Styles:
    \\# Basic colors: {red}text{/red}, {green}text{/green}, etc.
    \\# RGB colors: {rgb(255,0,0)}text{/rgb}
    \\# Styles: {bold}text{/bold}, {underline}text{/underline}, etc.
    \\#
    \\# Example formats:
    \\# format = "{bold}{red}{user}@{host}{/red}{/bold} on {green}{term}{/green}"
    \\# format = "{rgb(255,165,0)}os{/rgb}: {host} | {bold}shell{/bold}: {shell}"
    \\
    \\format = {bold}{cyan}{user}@{host}{/cyan}{/bold} since: {uptime}
    \\{green}{shell}{/green} on {yellow}{term}{/yellow}
    \\{magenta}{pkgs}{/magenta} pkgs on {blue}{session}{/blue}
    \\
;

pub const Placeholder = enum {
    user,
    host,
    shell,
    term,
    uptime,
    pkgs,
    session,

    pub fn symbol(self: Placeholder) []const u8 {
        return switch (self) {
            .user => "{user}",
            .host => "{host}",
            .shell => "{shell}",
            .term => "{term}",
            .uptime => "{uptime}",
            .pkgs => "{pkgs}",
            .session => "{session}",
        };
    }
};

fn parseColorTag(tag: []const u8) ?color.Color {
    return switch (tag[0]) {
        'b' => if (mem.eql(u8, tag, "black")) .black else if (mem.eql(u8, tag, "blue")) .blue else null,
        'r' => if (mem.eql(u8, tag, "red")) .red else null,
        'g' => if (mem.eql(u8, tag, "green")) .green else null,
        'y' => if (mem.eql(u8, tag, "yellow")) .yellow else null,
        'm' => if (mem.eql(u8, tag, "magenta")) .magenta else null,
        'c' => if (mem.eql(u8, tag, "cyan")) .cyan else null,
        'w' => if (mem.eql(u8, tag, "white")) .white else null,
        else => null,
    };
}

fn parseStyleTag(tag: []const u8) ?[]const u8 {
    return switch (tag[0]) {
        'b' => if (mem.eql(u8, tag, "bold")) color.Style.bold else if (mem.eql(u8, tag, "blink")) color.Style.blink else null,
        'd' => if (mem.eql(u8, tag, "dim")) color.Style.dim else null,
        'i' => if (mem.eql(u8, tag, "italic")) color.Style.italic else null,
        'u' => if (mem.eql(u8, tag, "underline")) color.Style.underline else null,
        'r' => if (mem.eql(u8, tag, "reverse")) color.Style.reverse else null,
        'h' => if (mem.eql(u8, tag, "hidden")) color.Style.hidden else null,
        's' => if (mem.eql(u8, tag, "strike")) color.Style.strike else null,
        else => null,
    };
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
    color_support: color.ColorSupport = undefined,

    var config_buf: [2048]u8 = undefined;
    var arena: std.heap.ArenaAllocator = undefined;
    var logger: log.ScopedLogger = undefined;

    pub fn getAllocator() mem.Allocator {
        return arena.allocator();
    }

    fn ensureConfigExists(home: []const u8, allocator: mem.Allocator) ![]const u8 {
        logger.debug("Ensuring config exists in home directory: {s}", .{home});

        const config_dir = try fs.path.join(allocator, &.{ home, ".config", "lifetch" });
        defer allocator.free(config_dir);

        fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                logger.debug("Config directory already exists", .{});
            },
            else => {
                logger.err("Failed to create config directory: {}", .{err});
                return ConfigError.ConfigDirCreationFailed;
            },
        };

        const config_path = try fs.path.join(allocator, &.{ config_dir, "config" });

        if (fs.openFileAbsolute(config_path, .{ .mode = .read_only })) |file| {
            logger.debug("Found existing config file", .{});
            file.close();
        } else |err| {
            logger.info("Config file not found, creating default: {}", .{err});
            const file = fs.createFileAbsolute(config_path, .{}) catch |create_err| {
                logger.err("Failed to create config file: {}", .{create_err});
                return ConfigError.ConfigFileCreationFailed;
            };
            defer file.close();

            file.writeAll(default_config) catch |write_err| {
                logger.err("Failed to write default config: {}", .{write_err});
                return ConfigError.ConfigFileCreationFailed;
            };
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
                } else if (parseColorTag(tag) == null and parseStyleTag(tag) == null) {
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

        var self = Config{
            .color_support = color.getColorSupport(),
        };

        const home = process.getEnvVarOwned(arena.allocator(), "HOME") catch {
            logger.err("HOME environment variable not found", .{});
            return ConfigError.HomeDirNotFound;
        };
        defer arena.allocator().free(home);

        const config_path = try ensureConfigExists(home, arena.allocator());
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

        var lines = mem.splitScalar(u8, config_buf[0..bytes_read], '\n');
        var format_lines = std.ArrayList(u8).init(arena.allocator());
        defer format_lines.deinit();

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
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') {
                const end_idx = mem.indexOfScalarPos(u8, text, i, '}') orelse break;
                const tag = text[i + 1 .. end_idx];

                if (mem.startsWith(u8, tag, "/")) {
                    try writer.writeAll("\x1b[0m");
                    i = end_idx;
                    continue;
                }

                if (mem.startsWith(u8, tag, "rgb(")) {
                    if (self.color_support.truecolor) {
                        const rgb = parseRgbTag(tag) catch continue;
                        try writer.print("\x1b[38;2;{};{};{}m", .{ rgb.r, rgb.g, rgb.b });
                    }
                } else if (parseColorTag(tag)) |c| {
                    if (self.color_support.basic) {
                        try writer.print("\x1b[{}m", .{@intFromEnum(c)});
                    }
                } else if (parseStyleTag(tag)) |s| {
                    try writer.writeAll(s);
                } else {
                    try writer.writeAll(text[i .. end_idx + 1]);
                }
                i = end_idx;
            } else {
                try writer.writeByte(text[i]);
            }
        }
    }
};
