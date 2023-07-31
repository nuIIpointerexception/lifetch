const std = @import("std");
const stdout = std.io.getStdOut();
const outWriter = stdout.writer();

fn writeLog(_: void, msg: []const u8) !usize {
    nosuspend outWriter.print("{s}", .{msg}) catch return msg.len;
    return msg.len;
}

pub fn border(str: []const u8, color: []const u8, allocator: std.mem.Allocator) void {
    var max_length: usize = 0;
    const verticalLeft = "│ ";
    const verticalRight = " │";
    var writer = std.io.Writer(void, error{}, writeLog){ .context = {} };
    try writer.print("{s}╭", .{color});
    var iter = std.mem.split(u8, str, "\n");
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    while (iter.next()) |l| {
        const line = stripColors(l, allocator) catch return;
        if (line.len > max_length) {
            max_length = line.len;
        }
        lines.append(line) catch return;
    }
    for (max_length + 2) |_| {
        try writer.print("─", .{});
    }
    try writer.print("╮\n", .{});

    for (lines.items) |i| {
        const padding = max_length - i.len;
        try writer.print("{s}{s}", .{ verticalLeft, i });
        for (padding) |_| {
            try writer.print(" ", .{});
        }
        try writer.print("{s}\n", .{verticalRight});
    }

    try writer.print("╰", .{});
    for (max_length + 2) |_| {
        try writer.print("─", .{});
    }
    try writer.print("╯\n", .{});
}

// TODO: rework this again, it's a complete mess
fn stripColors(str: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var colorless: []u8 = undefined;
    var colorlessLen: usize = 0;
    var i: usize = 0;

    while (i < str.len) {
        if (str[i] == 27 and i + 2 < str.len and str[i + 1] == 91) {
            i += 2;
            while (i < str.len and str[i] != 109) {
                i += 1;
            }
            i += 1;
        } else {
            colorlessLen += 1;
            i += 1;
        }
    }

    if (colorlessLen == str.len) {
        return str;
    }
    const colorlessPtr = try allocator.alloc(u8, colorlessLen);
    colorless = colorlessPtr[0..colorlessLen];
    var j: usize = 0;
    i = 0;
    while (i < str.len) {
        if (str[i] == 27 and i + 2 < str.len and str[i + 1] == 91) {
            i += 2;
            while (i < str.len and str[i] != 109) {
                i += 1;
            }
            i += 1;
        } else {
            colorless[j] = str[i];
            i += 1;
            j += 1;
        }
    }

    return colorless;
}
