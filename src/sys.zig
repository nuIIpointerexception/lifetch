const std = @import("std");
const linux = std.os.linux;

const errno = linux.errno;

pub const fd_t = linux.fd_t;

pub const OpenError = error{ FileNotFound, OpenFailed };
pub const ReadError = error{ReadFailed};

const interrupts_max = 64;

fn restarting(comptime syscall: anytype, args: anytype) usize {
    var rc: usize = undefined;
    for (0..interrupts_max) |_| {
        rc = @call(.auto, syscall, args);
        if (errno(rc) != .INTR) break;
    }
    return rc;
}

pub fn open(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) OpenError!fd_t {
    const rc = restarting(linux.open, .{ path, flags, mode });
    return switch (errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT, .NOTDIR => error.FileNotFound,
        else => error.OpenFailed,
    };
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// One read: a short count from a regular or procfs file is end of file, and a file longer than
/// `buf` is cut to `buf.len`.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    const rc = restarting(linux.read, .{ fd, buf.ptr, buf.len });
    if (errno(rc) != .SUCCESS) return error.ReadFailed;
    return rc;
}

pub fn read_file(path: [*:0]const u8, buf: []u8) (OpenError || ReadError)![]u8 {
    const fd = try open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer close(fd);
    return buf[0..try read(fd, buf)];
}

pub fn write_all(fd: fd_t, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = restarting(linux.write, .{ fd, rest.ptr, rest.len });
        if (errno(rc) != .SUCCESS or rc == 0) return false;
        rest = rest[rc..];
    }
    return true;
}

pub fn access(path: [*:0]const u8) linux.E {
    return errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0));
}

pub fn mkdir(path: [*:0]const u8) linux.E {
    return errno(linux.mkdir(path, 0o755));
}

pub fn statx(path: [*:0]const u8, mask: linux.STATX, out: *linux.Statx) linux.E {
    return errno(linux.statx(linux.AT.FDCWD, path, 0, mask, out));
}

comptime {
    std.debug.assert(@sizeOf(usize) == 8);
}

/// The fields lifetch needs from `struct statfs`, in record order except for `f_frsize` (the 10th
/// u64, index 9, of the x86-64 record); the rest of the record is skipped.
pub const Statfs = struct {
    f_type: u64,
    f_bsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    /// Fragment size, the 10th u64 (index 9) of the record: the unit the block counts are in.
    /// 0 when the filesystem does not report one, in which case `f_bsize` is the unit.
    f_frsize: u64,
};

pub fn statfs(path: [*:0]const u8, out: *Statfs) linux.E {
    var buf: [16]u64 = undefined;
    const status = errno(linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&buf)));
    if (status == .SUCCESS) out.* = .{
        .f_type = buf[0],
        .f_bsize = buf[1],
        .f_blocks = buf[2],
        .f_bfree = buf[3],
        .f_bavail = buf[4],
        .f_frsize = buf[9],
    };
    return status;
}

/// `f_type` of `struct statfs`, its first field.
pub fn fs_type(path: [*:0]const u8, out: *u64) linux.E {
    var st: Statfs = undefined;
    const status = statfs(path, &st);
    if (status == .SUCCESS) out.* = st.f_type;
    return status;
}

/// Zero at the end of the directory.
pub fn getdents(fd: fd_t, buf: []u8) ReadError!usize {
    const rc = restarting(linux.getdents64, .{ fd, buf.ptr, @as(c_uint, @intCast(buf.len)) });
    if (errno(rc) != .SUCCESS) return error.ReadFailed;
    return rc;
}

pub fn socket_peer_pid(path: []const u8) ?linux.pid_t {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (errno(rc) != .SUCCESS) return null;
    const fd: fd_t = @intCast(rc);
    defer close(fd);

    if (errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) return null;
    const Ucred = extern struct { pid: linux.pid_t, uid: linux.uid_t, gid: linux.gid_t };
    var cred: Ucred = undefined;
    var cred_len: linux.socklen_t = @sizeOf(Ucred);
    const opt = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        @ptrCast(&cred),
        &cred_len,
    );
    if (errno(opt) != .SUCCESS) return null;
    return cred.pid;
}

pub fn uname(out: *linux.utsname) bool {
    return errno(linux.uname(out)) == .SUCCESS;
}

/// CLOCK_BOOTTIME, the clock behind /proc/uptime. A direct syscall: one call does not repay the
/// vDSO symbol lookup.
pub fn boot_seconds() ?u64 {
    var ts: linux.timespec = undefined;
    const rc = linux.syscall2(.clock_gettime, @backingInt(linux.CLOCK.BOOTTIME), @intFromPtr(&ts));
    if (errno(rc) != .SUCCESS) return null;
    return @intCast(ts.sec);
}
