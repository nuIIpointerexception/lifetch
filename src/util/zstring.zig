const std = @import("std");
const assert = std.debug.assert;

pub const zstr = struct {
    buffer: ?[]u8,
    allocator: std.mem.Allocator,
    size: usize,

    pub const Error = error{
        OutOfMemory,
        InvalidRange,
    };

    pub fn init(allocator: std.mem.Allocator) zstr {
        return .{
            .buffer = null,
            .allocator = allocator,
            .size = 0,
        };
    }

    pub fn deinit(self: *zstr) void {
        if (self.buffer) |buffer| self.allocator.free(buffer);
    }

    pub fn capacity(self: zstr) usize {
        if (self.buffer) |buffer| return buffer.len;
        return 0;
    }

    pub fn allocate(self: *zstr, bytes: usize) Error!void {
        if (self.buffer) |buffer| {
            if (bytes < self.size) self.size = bytes;
            self.buffer = self.allocator.realloc(buffer, bytes) catch {
                return Error.OutOfMemory;
            };
        } else {
            self.buffer = self.allocator.alloc(u8, bytes) catch {
                return Error.OutOfMemory;
            };
        }
    }

    pub fn truncate(self: *zstr) Error!void {
        try self.allocate(self.size);
    }

    pub fn concat(self: *zstr, char: []const u8) Error!void {
        try self.insert(char, self.len());
    }

    pub fn insert(self: *zstr, literal: []const u8, index: usize) Error!void {
        if (self.buffer) |buffer| {
            if (self.size + literal.len > buffer.len) {
                try self.allocate((self.size + literal.len) * 2);
            }
        } else {
            try self.allocate((literal.len) * 2);
        }

        const buffer = self.buffer.?;

        if (index == self.len()) {
            var i: usize = 0;
            while (i < literal.len) : (i += 1) {
                buffer[self.size + i] = literal[i];
            }
        } else {
            if (zstr.getIndex(buffer, index, true)) |k| {
                var i: usize = buffer.len - 1;
                while (i >= k) : (i -= 1) {
                    if (i + literal.len < buffer.len) {
                        buffer[i + literal.len] = buffer[i];
                    }

                    if (i == 0) break;
                }

                i = 0;
                while (i < literal.len) : (i += 1) {
                    buffer[index + i] = literal[i];
                }
            }
        }

        self.size += literal.len;
    }

    pub fn toSlice(self: zstr) []const u8 {
        if (self.buffer) |buffer| return buffer[0..self.size];
        return "";
    }

    pub fn toOwned(self: zstr) Error!?[]u8 {
        if (self.buffer != null) {
            const string = self.toSlice();
            if (self.allocator.alloc(u8, string.len)) |newStr| {
                std.mem.copy(u8, newStr, string);
                return newStr;
            } else |_| {
                return Error.OutOfMemory;
            }
        }

        return null;
    }

    pub fn len(self: zstr) usize {
        if (self.buffer) |buffer| {
            var length: usize = 0;
            var i: usize = 0;

            while (i < self.size) {
                i += zstr.getUTF8Size(buffer[i]);
                length += 1;
            }

            return length;
        } else {
            return 0;
        }
    }

    pub fn clone(self: zstr) Error!zstr {
        var newString = zstr.init(self.allocator);
        try newString.concat(self.toSlice());
        return newString;
    }

    pub inline fn isEmpty(self: zstr) bool {
        return self.size == 0;
    }

    pub fn split(self: *const zstr, delimiters: []const u8, index: usize) ?[]const u8 {
        if (self.buffer) |buffer| {
            var i: usize = 0;
            var block: usize = 0;
            var start: usize = 0;

            while (i < self.size) {
                const size = zstr.getUTF8Size(buffer[i]);
                if (size == delimiters.len) {
                    if (std.mem.eql(u8, delimiters, buffer[i..(i + size)])) {
                        if (block == index) return buffer[start..i];
                        start = i + size;
                        block += 1;
                    }
                }

                i += size;
            }

            if (i >= self.size - 1 and block == index) {
                return buffer[start..self.size];
            }
        }

        return null;
    }

    pub fn splitString(self: *const zstr, delimiters: []const u8, index: usize) Error!?zstr {
        if (self.split(delimiters, index)) |block| {
            var string = zstr.init(self.allocator);
            try string.concat(block);
            return string;
        }

        return null;
    }

    pub fn clear(self: *zstr) void {
        if (self.buffer) |buffer| {
            for (buffer) |*ch| ch.* = 0;
            self.size = 0;
        }
    }

    pub usingnamespace struct {
        pub const Writer = std.io.Writer(*zstr, Error, appendWrite);

        pub fn writer(self: *zstr) Writer {
            return .{ .context = self };
        }

        fn appendWrite(self: *zstr, m: []const u8) !usize {
            try self.concat(m);
            return m.len;
        }
    };

    fn getIndex(unicode: []const u8, index: usize, real: bool) ?usize {
        var i: usize = 0;
        var j: usize = 0;
        while (i < unicode.len) {
            if (real) {
                if (j == index) return i;
            } else {
                if (i == index) return j;
            }
            i += zstr.getUTF8Size(unicode[i]);
            j += 1;
        }

        return null;
    }

    inline fn getUTF8Size(char: u8) u3 {
        return std.unicode.utf8ByteSequenceLength(char) catch {
            return 1;
        };
    }
};
