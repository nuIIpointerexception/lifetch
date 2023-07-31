const std = @import("std");

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
        while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |original| {
            var line = try alloc.alloc(u8, original.len);
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
                var current_section_name = try readSection(line);
                current_section = try alloc.create(Section);
                current_section.* = .{ .name = current_section_name, .entries = std.ArrayList(*Entry).init(alloc) };
                try cfg.sections.append(current_section);
                continue;
            }

            var pos = try getEqualPos(line);
            var key = trimWSpace(line[0..pos]);
            var value = trimWSpace(line[pos + 1 .. line.len]);
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
        var file = try std.fs.cwd().openFile(filename, .{});
        return try parse(file, alloc);
    }

    /// Deinitialize the Config instance, freeing allocated memory.
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

    /// Get the value for a specific key in a section.
    ///   - Arguments:
    ///   - section_name: The name of the section to search in.
    ///   - key: The key to look for in the section.
    ///   - Returns:
    ///   - The value associated with the key in the given section, or undefined if not found.
    pub fn get(self: Self, section_name: []const u8, key: []const u8) ?[]const u8 {
        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.name, section_name)) {
                for (section.entries.items) |entry| {
                    if (std.mem.eql(u8, key, entry.key)) {
                        return entry.value;
                    }
                }
            }
        }
        return undefined;
    }

    fn isEmptyLine(line: []const u8) bool {
        for (line) |c| {
            if (!isWSpace(c)) {
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

    fn readSection(input: []u8) ![]const u8 {
        var trimmed_line = trimWSpace(input);
        if (trimmed_line[0] != '[' or trimmed_line[trimmed_line.len - 1] != ']') {
            return error.SyntaxError;
        }

        var section_name: []const u8 = trimmed_line[1 .. trimmed_line.len - 1];
        section_name = trimWSpace(section_name);

        return section_name;
    }

    fn trimWSpace(slice: []const u8) []const u8 {
        var start: usize = 0;
        while (isWSpace(slice[start])) : (start += 1) {}

        var end: usize = slice.len;
        while (isWSpace(slice[end - 1])) : (end -= 1) {}

        return slice[start..end];
    }

    fn isWSpace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == 13;
    }
};
