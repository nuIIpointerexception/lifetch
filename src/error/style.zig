const std = @import("std");

fn writeLog(_: void, msg: []const u8) !usize {
    const stdout = std.io.getStdOut().writer();
    nosuspend stdout.print("{s}", .{msg}) catch return msg.len;
    return msg.len;
}

pub fn drawBorder(str: []const u8, color: []const u8, allocator: std.mem.Allocator) void {
    var max_length: usize = 0;
    const verticalLeft = "│ ";
    const verticalRight = " │";
    var writer = std.io.Writer(void, error{}, writeLog){ .context = {} };
    try writer.print("{s}╭", .{color});
    var iter = std.mem.split(u8, str, "\n");
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    while (iter.next()) |l| {
        const line = stripColors(l, &allocator) catch return;
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

pub fn stripColors(str: []const u8, allocator: *const std.mem.Allocator) ![]u8 {
    var bufSize = str.len / 2;
    if (bufSize < 16) {
        bufSize = 16;
    }

    var buf = try allocator.alloc(u8, bufSize);
    var j: usize = 0;

    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == 27 and i + 2 < str.len and str[i + 1] == 91) {
            i += 2;
            while (i < str.len and str[i] != 109) {
                i += 1;
            }
            i += 1;
        } else {
            if (j >= buf.len) {
                const newSize = buf.len * 2;
                const newBuf = try allocator.realloc(buf, newSize);
                buf = newBuf;
            }

            buf[j] = str[i];
            i += 1;
            j += 1;
        }
    }

    buf = try allocator.realloc(buf, j);
    return buf;
}
