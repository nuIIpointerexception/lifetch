const std = @import("std");
const style = @import("../format/style.zig");
const color = @import("../format/color.zig");

pub const Entry = struct { key: []const u8, value: []const u8 };

pub const Section = struct {
    const Self = @This();

    name: []const u8,
    entries: std.ArrayList(*Entry),

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.destroy(entry);
        }
        self.entries.deinit();
    }
};

pub const Config = struct {
    const Self = @This();

    sections: std.ArrayList(*Section),
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8),

    pub const ErrorType = enum {
        MissingKey,
        MissingSection,
    };

    pub const ErrorLevel = enum {
        INFO,
        WARN,
        ERR,
        FATAL,
    };

    fn getColor(level: ErrorLevel) []const u8 {
        return switch (level) {
            ErrorLevel.INFO => color.LIGHT_GRAY,
            ErrorLevel.WARN => color.YELLOW,
            ErrorLevel.ERR => color.LIGHT_RED,
            ErrorLevel.FATAL => color.RED,
        };
    }

    fn getPrefix(level: ErrorLevel) []const u8 {
        return switch (level) {
            ErrorLevel.INFO => "info",
            ErrorLevel.WARN => "warn",
            ErrorLevel.ERR => "error",
            ErrorLevel.FATAL => "fatal",
        };
    }

    pub const Error = struct {
        msg: []const u8,
        level: ErrorLevel = ErrorLevel.WARN,
        line_text: ?[]const u8 = null,
        line_num: ?usize = null,
        position: ?usize = null,

        const ValueSelf = @This();

        pub fn throw(self: ValueSelf, alloc: std.mem.Allocator) !void {
            const errorColor = getColor(self.level);
            const prefix = getPrefix(self.level);
            if (self.line_text) |line_text| {
                if (self.position) |position| {
                    const error_line = try std.fmt.allocPrint(alloc, "{s}", .{line_text});
                    var underline = try alloc.alloc(u8, line_text.len);
                    @memset(underline[0..position], ' ');
                    underline[position] = '^';
                    @memset(underline[position + 1 ..], '~');

                    const formattedMessage = try std.fmt.allocPrint(alloc, "{s}{s} in \x1b[0mconfig.ini{s}: {s}\n{any}:      {s}\n        {s}{s}\x1b[0m", .{
                        errorColor,
                        prefix,
                        errorColor,
                        self.msg,
                        self.line_num orelse 0,
                        error_line,
                        errorColor,
                        underline,
                    });

                    try style.drawBorder(formattedMessage, getColor(self.level), alloc);
                    std.os.exit(0);

                    alloc.free(error_line);
                    alloc.free(underline);
                    return;
                }
            }

            try style.drawBorder(try std.fmt.allocPrint(alloc, "{s}{s} in \x1b[0mconfig.ini{s}: {s}", .{
                errorColor,
                prefix,
                errorColor,
                self.msg,
            }), getColor(self.level), alloc);
            std.os.exit(0);
        }
    };

    /// Parse the configuration file and return a Config instance.
    ///   - Arguments:
    ///   - file: The configuration file to parse.
    ///   - alloc: The memory allocator to use for allocations.
    ///   - Returns:
    ///   - A Config instance representing the parsed configuration.
    ///   - Possible Errors:
    ///   - Error from file reading or memory allocation.
    pub fn parse(file: std.fs.File, alloc: std.mem.Allocator) anyerror!Config {
        defer file.close();
        var reader = std.io.bufferedReader(file.reader());
        var in_stream = reader.reader();

        var current_section: *Section = undefined;
        var cfg: Config = .{ .sections = std.ArrayList(*Section).init(alloc), .allocator = alloc, .lines = std.ArrayList([]u8).init(alloc) };

        var buf: [1024]u8 = undefined;
        var line_num: usize = 0;
        while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |original| {
            line_num += 1;
            var line = alloc.alloc(u8, original.len) catch {
                return error.AllocationFailed;
            };
            std.mem.copy(u8, line, original);
            try cfg.lines.append(line);

            if (isEmptyLine(line)) {
                continue;
            }

            var first_char = line[0];
            if (first_char == '#' or first_char == ';') {
                continue;
            }

            if (first_char == '[') {
                var current_section_name = try readSection(alloc, line, line_num, cfg);
                current_section = try alloc.create(Section);
                current_section.* = .{ .name = current_section_name, .entries = std.ArrayList(*Entry).init(alloc) };
                try cfg.sections.append(current_section);
                continue;
            }

            var pos = try getEqualPos(line);
            var key = std.mem.trim(u8, line[0..pos], " \t\n\r");
            var value = std.mem.trim(u8, line[pos + 1 .. line.len], " \t\n\r");
            var entry: *Entry = try alloc.create(Entry);
            entry.* = .{ .key = key, .value = value };
            try current_section.entries.append(entry);
        }

        return cfg;
    }

    /// Initialize a Config instance from a file.
    ///   - Arguments:
    ///   - filename: The name of the configuration file to load.
    ///   - alloc: The memory allocator to use for allocations.
    ///   - Returns:
    ///   - A Config instance representing the parsed configuration.
    ///   - Possible Errors:
    ///   - Error when opening the file or parsing its contents.
    pub fn init(filename: []const u8, alloc: std.mem.Allocator) anyerror!Config {
        var file = std.fs.cwd().openFile(filename, .{}) catch {
            return error.FileNotFound;
        };
        return try parse(file, alloc);
    }

    /// Deinitialize the Config instance, freeing allocated memory. (Although we may not need it for this project, it's generally good practice...)
    pub fn deinit(self: Self) void {
        for (self.sections.items) |section| {
            section.deinit(self.allocator);
            self.allocator.destroy(section);
        }
        self.sections.deinit();

        for (self.lines.items) |line| {
            self.allocator.free(line);
        }

        self.lines.deinit();
    }

    pub fn get(self: Self, section_name: []const u8, key: []const u8) ![]const u8 {
        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.name, section_name)) {
                for (section.entries.items) |entry| {
                    if (std.mem.eql(u8, key, entry.key)) {
                        return entry.value;
                    }
                }
                const lvl = ErrorLevel.FATAL;
                const e = Error{
                    .level = lvl,
                    .msg = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}key \x1b[0m{s}{s} not found @ \x1b[0m{s}{s} section.",
                        .{
                            getColor(lvl),
                            key,
                            getColor(lvl),
                            section_name,
                            getColor(lvl),
                        },
                    ),
                };
                try e.throw(self.allocator);
            }
        }
        const e = Error{
            .msg = try std.fmt.allocPrint(
                self.allocator,
                "section {s} not found.",
                .{
                    section_name,
                },
            ),
        };
        try e.throw(self.allocator);
        return error.SectionNotFound;
    }

    /// Get a string value for a specific key in a section.
    ///   - Arguments:
    ///   - section_name: The name of the section to search in.
    ///   - key: The key to look for.
    ///   - Returns:
    ///   - The string associated with the key, or an error if not found.
    pub fn getString(self: Self, section_name: []const u8, key: []const u8) ![]const u8 {
        return get(self, section_name, key);
    }

    /// Get a boolean value for a specific key in a section.
    ///   - Arguments:
    ///   - section_name: The name of the section to search in.
    ///   - key: The key to look for.
    ///   - Returns:
    ///   - The boolean associated with the key, or an error if not found.
    pub fn getBool(self: Self, section_name: []const u8, key: []const u8) !bool {
        var value = try get(self, section_name, key);
        if (std.mem.eql(u8, value, "true")) {
            return true;
        } else if (std.mem.eql(u8, value, "false")) {
            return false;
        }

        return error.InvalidBoolean;
    }

    /// Get a integer value for a specific key in a section.
    ///   - Arguments:
    ///   - section_name: The name of the section to search in.
    ///   - key: The key to look for.
    ///   - Returns:
    ///   - The integer associated with the key, or an error if not found.
    pub fn getUnsigned(self: Self, section_name: []const u8, key: []const u8) !u8 {
        var value = std.fmt.parseUnsigned(u8, try get(self, section_name, key), 10) catch {
            return error.InvalidInteger;
        };
        return value;
    }

    /// Get a float value for a specific key in a section.
    ///   - Arguments:
    ///   - section_name: The name of the section to search in.
    ///   - key: The key to look for.
    ///   - Returns:
    ///   - The float associated with the key, or an error if not found.
    pub fn getFloat(self: Self, section_name: []const u8, key: []const u8) !f32 {
        var value = std.fmt.parseFloat(f32, try get(self, section_name, key)) catch {
            return error.InvalidFloat;
        };
        return value;
    }

    fn isEmptyLine(line: []const u8) bool {
        for (line) |c| {
            if (!std.ascii.isWhitespace(c)) {
                return false;
            }
        }
        return true;
    }

    fn getEqualPos(slice: []u8) !usize {
        for (slice, 0..) |c, i| {
            if (c == '=') {
                return i;
            }
        }

        return error.DelimiterError;
    }

    fn readSection(alloc: std.mem.Allocator, input: []u8, line_num: usize, config: Config) ![]const u8 {
        var trimmed_line = std.mem.trim(u8, input, " \t\n\r");

        const maybe_end_bracket_pos = std.mem.indexOfScalar(u8, trimmed_line, ']');

        if (maybe_end_bracket_pos == null) {
            const e = Error{
                .position = trimmed_line.len - 1,
                .msg = "missing ending ']' for section.",
                .line_text = config.lines.items[line_num - 1],
                .line_num = line_num,
            };
            try e.throw(alloc);
        }

        const end_bracket_pos = maybe_end_bracket_pos.?;

        if (end_bracket_pos != trimmed_line.len - 1) {
            const e = Error{
                .position = end_bracket_pos,
                .msg = "unexpected characters.",
                .line_text = config.lines.items[line_num - 1],
                .line_num = line_num,
            };
            try e.throw(alloc);
        }

        var section_name: []const u8 = trimmed_line[1..end_bracket_pos];
        section_name = std.mem.trim(u8, section_name, " \t\n\r");

        return section_name;
    }
};
