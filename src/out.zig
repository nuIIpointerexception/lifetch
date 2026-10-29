const std = @import("std");
const sys = @import("sys.zig");

pub const Out = struct {
    fd: sys.fd_t,
    len: usize,
    failed: bool,
    buf: [1024]u8,

    pub fn init(self: *Out, fd: sys.fd_t) void {
        self.fd = fd;
        self.len = 0;
        self.failed = false;
    }

    pub fn write(self: *Out, bytes: []const u8) void {
        if (bytes.len > self.buf.len - self.len) {
            self.flush();
            if (bytes.len > self.buf.len) {
                if (!sys.write_all(self.fd, bytes)) self.failed = true;
                return;
            }
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn write_uint(self: *Out, value: u64) void {
        var digits: Digits = undefined;
        self.write(format_uint(value, &digits));
    }

    pub fn flush(self: *Out) void {
        if (!sys.write_all(self.fd, self.buf[0..self.len])) self.failed = true;
        self.len = 0;
    }
};

/// Room for any u64 in decimal.
pub const Digits = [std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 1]u8;

pub fn format_uint(value: u64, digits: *Digits) []const u8 {
    var i: usize = digits.len;
    var rest = value;
    while (true) {
        i -= 1;
        digits[i] = @intCast('0' + rest % 10);
        rest /= 10;
        if (rest == 0) break;
    }
    return digits[i..];
}

/// Null when `parts` and the terminating NUL do not fit in `buf`.
pub fn join_z(buf: []u8, parts: []const []const u8) ?[:0]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        if (part.len >= buf.len - len) return null;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

test "format_uint: zero, typical and maximum" {
    var digits: Digits = undefined;
    try std.testing.expectEqualStrings("0", format_uint(0, &digits));
    try std.testing.expectEqualStrings("1162", format_uint(1162, &digits));
    const max = format_uint(std.math.maxInt(u64), &digits);
    try std.testing.expectEqualStrings("18446744073709551615", max);
}

test "join_z: fits, and rejects a result with no room for the NUL" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("/a/bc", join_z(&buf, &.{ "/a", "/bc" }).?);
    try std.testing.expectEqualStrings("1234567", join_z(&buf, &.{ "1234", "567" }).?);
    try std.testing.expect(join_z(&buf, &.{ "1234", "5678" }) == null);
}
