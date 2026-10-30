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
        copy(self.buf[self.len..][0..bytes.len], bytes);
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

/// Decimal text to a value; null on empty text, a non-digit or overflow.
pub fn parse_uint(text: []const u8) ?u64 {
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u64 = c - '0';
        if (value > (std.math.maxInt(u64) - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return if (text.len == 0) null else value;
}

pub const Unit = enum { auto, b, k, m, g, t };

/// "auto", "b", "k", "m", "g", "t" case-insensitive; "kb".."tb" and "kib".."tib" name the same
/// units. Null on anything else.
pub fn parse_unit(text: []const u8) ?Unit {
    var buf: [4]u8 = undefined; // room for "auto", the longest accepted spelling
    if (text.len == 0 or text.len > buf.len) return null;
    for (text, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const t = buf[0..text.len];
    if (std.mem.eql(u8, t, "auto")) return .auto;
    const unit: Unit = switch (t[0]) {
        'b' => .b,
        'k' => .k,
        'm' => .m,
        'g' => .g,
        't' => .t,
        else => return null,
    };
    const suffix = t[1..];
    if (unit == .b) return if (suffix.len == 0) unit else null;
    if (suffix.len == 0 or std.mem.eql(u8, suffix, "b") or std.mem.eql(u8, suffix, "ib")) return unit;
    return null;
}

/// `precision` is the maximum fraction digits, 0..=4; more reads as 4.
pub const Opts = struct { unit: Unit = .auto, precision: u8 = 1 };

const precision_max = 4;

/// Room for any `format_size` result: the 17 integer digits of maxInt(u64) in K, a point, 4
/// fraction digits and the unit letter. B takes 20 digits but never has a fraction.
pub const SizeBuf = [std.math.log10_int(@as(u64, std.math.maxInt(u64) / 1024)) + 1 + 1 + precision_max + 1]u8;

/// Divided by 1024 with suffixes B K M G T. `.auto` takes the largest unit whose value is at
/// least 1 (zero is "0B"); a fixed unit always divides. At most `opts.precision` fraction digits,
/// rounded half up, with trailing zeros and a bare point dropped; rounding that carries past the
/// unit moves into the integer part without promoting the unit.
pub fn format_size(bytes: u64, opts: Opts, buf: *SizeBuf) []const u8 {
    const shift: u8 = switch (opts.unit) {
        .auto => if (bytes >= 1024 * 1024 * 1024 * 1024)
            4
        else if (bytes >= 1024 * 1024 * 1024)
            3
        else if (bytes >= 1024 * 1024)
            2
        else if (bytes >= 1024)
            1
        else
            0,
        .b => 0,
        .k => 1,
        .m => 2,
        .g => 3,
        .t => 4,
    };
    const divisors = [_]u64{ 1, 1024, 1024 * 1024, 1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024 };
    const divisor = divisors[shift];
    const precision = @min(opts.precision, precision_max);
    var pow10: u64 = 1;
    for (0..precision) |_| pow10 *= 10;

    // The remainder path keeps every product under 2^54: rem < divisor <= 2^40, pow10 <= 10^4.
    var integer = bytes / divisor;
    const rem = bytes % divisor;
    var frac: u64 = @intCast((2 * @as(u128, rem) * pow10 + divisor) / (2 * @as(u128, divisor)));
    if (frac == pow10) {
        frac = 0;
        integer += 1; // cannot overflow: a fraction only exists when a remainder does
    }

    var digits: Digits = undefined;
    const whole = format_uint(integer, &digits);
    var len: usize = 0;
    copy(buf[len..][0..whole.len], whole);
    len += whole.len;
    if (frac != 0) {
        var frac_text: [precision_max]u8 = undefined;
        var f = frac;
        var i: usize = precision;
        while (i > 0) {
            i -= 1;
            frac_text[i] = '0' + @as(u8, @intCast(f % 10));
            f /= 10;
        }
        var keep: usize = precision;
        while (frac_text[keep - 1] == '0') keep -= 1;
        buf[len] = '.';
        copy(buf[len + 1 ..][0..keep], frac_text[0..keep]);
        len += 1 + keep;
    }
    buf[len] = "BKMGT"[shift];
    len += 1;
    return buf[0..len];
}

/// Room for "100%".
pub const PercentBuf = [4]u8;

/// Whole percent of `whole`, rounded half up and clamped to 100 (the htop convention: mem and
/// swap, cpu and gpu shares use this); "0%" when `whole` is zero.
pub fn format_percent(part: u64, whole: u64, buf: *PercentBuf) []const u8 {
    var percent: u64 = 0;
    if (whole > 0) {
        const scaled = (@as(u128, part) * 2 * 100 + whole) / (2 * @as(u128, whole));
        percent = @intCast(@min(scaled, 100));
    }
    return format_percent_text(percent, buf);
}

/// Whole percent of `whole`, rounded UP and clamped to 100 (the `Use%` of `df`, which never
/// understates a used share: 78.2% prints as 79%); the disk fields use this. "0%" when `whole`
/// is zero.
pub fn format_percent_ceil(part: u64, whole: u64, buf: *PercentBuf) []const u8 {
    var percent: u64 = 0;
    if (whole > 0) {
        const scaled = (@as(u128, part) * 100 +| @as(u128, whole) -| 1) / @as(u128, whole);
        percent = @intCast(@min(scaled, 100));
    }
    return format_percent_text(percent, buf);
}

fn format_percent_text(percent: u64, buf: *PercentBuf) []const u8 {
    var digits: Digits = undefined;
    const text = format_uint(percent, &digits);
    copy(buf[0..text.len], text);
    buf[text.len] = '%';
    return buf[0 .. text.len + 1];
}

/// Copies `src` into `dst`, always inline. A runtime-length `@memcpy` lowers to a call to
/// `memcpy`, whose compiler_rt copy sits on a cold page at the end of the image — a first-touch
/// page fault per run in a binary where the whole startup is a handful; the volatile load keeps
/// this loop from being turned back into such a call.
pub inline fn copy(dst: []u8, src: []const u8) void {
    const s: [*]const volatile u8 = @ptrCast(src.ptr);
    for (0..src.len) |i| dst[i] = s[i];
}

/// Null when `parts` and the terminating NUL do not fit in `buf`.
pub fn join_z(buf: []u8, parts: []const []const u8) ?[:0]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        if (part.len >= buf.len - len) return null;
        copy(buf[len..][0..part.len], part);
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

test "parse_unit: accepted spellings, case-insensitive" {
    try std.testing.expectEqual(Unit.auto, parse_unit("auto").?);
    try std.testing.expectEqual(Unit.auto, parse_unit("AUTO").?);
    try std.testing.expectEqual(Unit.b, parse_unit("b").?);
    try std.testing.expectEqual(Unit.b, parse_unit("B").?);
    try std.testing.expectEqual(Unit.k, parse_unit("k").?);
    try std.testing.expectEqual(Unit.m, parse_unit("m").?);
    try std.testing.expectEqual(Unit.g, parse_unit("G").?);
    try std.testing.expectEqual(Unit.t, parse_unit("t").?);
    try std.testing.expectEqual(Unit.k, parse_unit("kb").?);
    try std.testing.expectEqual(Unit.m, parse_unit("MB").?);
    try std.testing.expectEqual(Unit.g, parse_unit("gb").?);
    try std.testing.expectEqual(Unit.t, parse_unit("TB").?);
    try std.testing.expectEqual(Unit.k, parse_unit("kib").?);
    try std.testing.expectEqual(Unit.m, parse_unit("MIB").?);
    try std.testing.expectEqual(Unit.g, parse_unit("GiB").?);
    try std.testing.expectEqual(Unit.t, parse_unit("tIb").?);
}

test "parse_unit: rejects unknown spellings" {
    try std.testing.expect(parse_unit("") == null);
    try std.testing.expect(parse_unit("bb") == null);
    try std.testing.expect(parse_unit("xb") == null);
    try std.testing.expect(parse_unit("byte") == null);
    try std.testing.expect(parse_unit("kk") == null);
    try std.testing.expect(parse_unit("kibb") == null);
    try std.testing.expect(parse_unit("autoo") == null);
}

test "format_size: zero, bytes and the auto unit steps" {
    var buf: SizeBuf = undefined;
    try std.testing.expectEqualStrings("0B", format_size(0, .{}, &buf));
    try std.testing.expectEqualStrings("512B", format_size(512, .{}, &buf));
    try std.testing.expectEqualStrings("1023B", format_size(1023, .{}, &buf));
    try std.testing.expectEqualStrings("1K", format_size(1024, .{}, &buf));
    try std.testing.expectEqualStrings("1.5K", format_size(1536, .{}, &buf));
    try std.testing.expectEqualStrings("1M", format_size(1024 * 1024, .{}, &buf));
    try std.testing.expectEqualStrings("1G", format_size(1024 * 1024 * 1024, .{}, &buf));
    try std.testing.expectEqualStrings("1T", format_size(1024 * 1024 * 1024 * 1024, .{}, &buf));
    try std.testing.expectEqualStrings("63.8G", format_size(68451051520, .{}, &buf));
}

test "format_size: precision 0..=4, trailing zeros and rounding carry" {
    var buf: SizeBuf = undefined;
    try std.testing.expectEqualStrings("2K", format_size(1536, .{ .precision = 0 }, &buf));
    try std.testing.expectEqualStrings("1.5K", format_size(1536, .{ .precision = 2 }, &buf));
    try std.testing.expectEqualStrings("1.5K", format_size(1536, .{ .precision = 4 }, &buf));
    try std.testing.expectEqualStrings("1.1K", format_size(1152, .{ .precision = 1 }, &buf));
    try std.testing.expectEqualStrings("1.13K", format_size(1152, .{ .precision = 2 }, &buf)); // 1.125 rounds up
    try std.testing.expectEqualStrings("1.125K", format_size(1152, .{ .precision = 3 }, &buf));
    try std.testing.expectEqualStrings("1.125K", format_size(1152, .{ .precision = 4 }, &buf));
    // 39.0G after rounding prints "39G", and the carry does not promote the unit.
    try std.testing.expectEqualStrings("39G", format_size(41886416896, .{}, &buf));
    try std.testing.expectEqualStrings("1000K", format_size(1023949, .{ .unit = .k, .precision = 1 }, &buf));
    // A fixed unit is always that unit, even for zero.
    try std.testing.expectEqualStrings("0T", format_size(0, .{ .unit = .t, .precision = 4 }, &buf));
}

test "format_size: maxInt(u64) in every unit" {
    var buf: SizeBuf = undefined;
    const max = std.math.maxInt(u64);
    try std.testing.expectEqualStrings("18446744073709551615B", format_size(max, .{ .unit = .b }, &buf));
    try std.testing.expectEqualStrings("18014398509481983.999K", format_size(max, .{ .unit = .k, .precision = 4 }, &buf));
    // 2^64 - 1 is 16777215.9999...T: the fraction rounds up and carries into the integer part.
    try std.testing.expectEqualStrings("16777216T", format_size(max, .{ .unit = .t }, &buf));
    // The widest result fits SizeBuf exactly: 17 integer digits, point, 4 fraction digits, unit.
    const widest = format_size(10240000000000000096, .{ .unit = .k, .precision = 4 }, &buf);
    try std.testing.expectEqualStrings("10000000000000000.0938K", widest);
    try std.testing.expectEqual(@as(usize, @typeInfo(SizeBuf).array.len), widest.len);
}

test "format_percent: zero whole, clamp and rounding" {
    var buf: PercentBuf = undefined;
    try std.testing.expectEqualStrings("0%", format_percent(0, 0, &buf));
    try std.testing.expectEqualStrings("0%", format_percent(5, 0, &buf));
    try std.testing.expectEqualStrings("100%", format_percent(101, 100, &buf));
    try std.testing.expectEqualStrings("100%", format_percent(std.math.maxInt(u64), 1, &buf));
    try std.testing.expectEqualStrings("50%", format_percent(1, 2, &buf));
    try std.testing.expectEqualStrings("13%", format_percent(1, 8, &buf)); // 12.5 rounds up
    try std.testing.expectEqualStrings("33%", format_percent(1, 3, &buf));
    try std.testing.expectEqualStrings("67%", format_percent(2, 3, &buf));
    try std.testing.expectEqualStrings("25%", format_percent(250, 1000, &buf));
    try std.testing.expectEqualStrings("100%", format_percent(996, 1000, &buf)); // 99.6 rounds up
    try std.testing.expectEqualStrings("45%", format_percent(30523576320, 68451051520, &buf));
}

test "format_percent_ceil: ceiling rounding matches df" {
    var buf: PercentBuf = undefined;
    // 78.2% of the disk is used: half up would say 78, df says 79.
    try std.testing.expectEqualStrings("79%", format_percent_ceil(39_100_000_000, 50_000_000_000, &buf));
    // The same share still rounds half up in format_percent (htop convention).
    try std.testing.expectEqualStrings("78%", format_percent(39_100_000_000, 50_000_000_000, &buf));
    // An exact percent is not inflated by the ceiling.
    try std.testing.expectEqualStrings("78%", format_percent_ceil(39e9, 50e9, &buf));
    // One used block out of a million is still 1%, like df.
    try std.testing.expectEqualStrings("1%", format_percent_ceil(1, 1_000_000, &buf));
    try std.testing.expectEqualStrings("0%", format_percent_ceil(0, 1_000_000, &buf));
    try std.testing.expectEqualStrings("0%", format_percent_ceil(0, 0, &buf));
    try std.testing.expectEqualStrings("100%", format_percent_ceil(101, 100, &buf));
    try std.testing.expectEqualStrings("100%", format_percent_ceil(std.math.maxInt(u64), 1, &buf));
    // The ceiling of an exact 2/3 is 67%, same as half up here.
    try std.testing.expectEqualStrings("67%", format_percent_ceil(2, 3, &buf));
}

test "parse_uint: digits only, empty and overflow are null" {
    try std.testing.expectEqual(@as(?u64, 0), parse_uint("0"));
    try std.testing.expectEqual(@as(?u64, 1162), parse_uint("1162"));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), parse_uint("18446744073709551615"));
    try std.testing.expect(parse_uint("") == null);
    try std.testing.expect(parse_uint("18446744073709551616") == null);
    try std.testing.expect(parse_uint("12x") == null);
    try std.testing.expect(parse_uint("+12") == null);
    try std.testing.expect(parse_uint("1_0") == null);
}
