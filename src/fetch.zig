const std = @import("std");
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const utils = @import("utils.zig");
const config = @import("config.zig");
const log = @import("log.zig");

pub const max_hostname_len = 64;
pub const max_environ_len = 2048;
pub const max_shell_len = 32;
pub const max_uptime_len = 16;
pub const max_term_len = 32;
pub const max_pkgs_len = 8;
pub const max_tty_len = 16;

pub const user_prefix = "USER=";
pub const shell_prefix = "SHELL=";
pub const term_prefix = "TERM=";
pub const term_program_prefix = "TERM_PROGRAM=";
pub const display_prefix = "DISPLAY=";
pub const desktop_prefix = "XDG_CURRENT_DESKTOP=";
pub const wayland_prefix = "WAYLAND_DISPLAY=";

pub const FetchError = error{
    UserNotFound,
    EnvironmentReadFailed,
    HostnameReadFailed,
    UptimeReadFailed,
    PackageCountFailed,
    ConfigInitFailed,
    InvalidEnvironment,
} || std.fs.File.OpenError || std.fs.File.ReadError;

pub const Fetch = struct {
    hostname: []const u8 = "",
    username: []const u8 = "",
    shell: []const u8 = "",
    terminal: []const u8 = "",
    uptime_str: []const u8 = "",
    pkg_count: usize = 0,
    is_wayland: bool = false,
    config: config.Config,
    hostname_buf: [max_hostname_len]u8 align(8) = undefined,
    environ_buf: [max_environ_len]u8 align(16) = undefined,
    shell_buf: [max_shell_len]u8 align(8) = undefined,
    uptime_buf: [max_uptime_len]u8 align(8) = undefined,
    term_buf: [max_term_len]u8 align(8) = undefined,
    tty_buf: [max_tty_len]u8 align(8) = undefined,
    format_buf: [1024]u8 align(16) = undefined,
    logger: log.ScopedLogger,

    comptime {
        if (max_hostname_len > 64) @compileError("Hostname buffer too large");
        if (max_environ_len > 4096) @compileError("Environment buffer too large");
        if (max_shell_len > 64) @compileError("Shell buffer too large");
        if (!std.math.isPowerOfTwo(max_hostname_len)) @compileError("Buffer size must be power of two for optimal alignment");
        if (!std.math.isPowerOfTwo(max_shell_len)) @compileError("Buffer size must be power of two for optimal alignment");
    }

    inline fn detectTerminal(self: *Fetch, content: []const u8) []const u8 {
        self.logger.debug("Detecting terminal...", .{});

        if (utils.getEnvValue(content, term_prefix)) |term| {
            self.logger.debug("Found TERM: {s}", .{term});
            return term;
        }

        self.logger.debug("No terminal detected, using tty", .{});
        return "tty";
    }

    inline fn initField(
        self: *Fetch,
        comptime field: config.Placeholder,
        environ_content: []const u8,
    ) void {
        self.logger.debug("Initializing field: {s}", .{@tagName(field)});
        switch (field) {
            .host => {
                const hostname_file = fs.cwd().openFile("/etc/hostname", .{ .mode = .read_only }) catch |err| {
                    self.logger.warn("Failed to read hostname: {}", .{err});
                    return;
                };
                defer hostname_file.close();
                const hostname_len = hostname_file.readAll(&self.hostname_buf) catch |err| {
                    self.logger.warn("Failed to read hostname content: {}", .{err});
                    return;
                };
                self.hostname = mem.trimRight(u8, self.hostname_buf[0..hostname_len], "\n");
                self.logger.debug("Got hostname: {s}", .{self.hostname});
            },
            .shell => {
                if (utils.getEnvValue(environ_content, shell_prefix)) |shell| {
                    const shell_name = fs.path.basename(shell);
                    if (shell_name.len < self.shell_buf.len) {
                        @memcpy(self.shell_buf[0..shell_name.len], shell_name);
                        self.shell = self.shell_buf[0..shell_name.len];
                        self.logger.debug("Got shell: {s}", .{self.shell});
                    }
                } else {
                    self.logger.warn("Shell not found in environment", .{});
                }
            },
            .term => {
                self.terminal = self.detectTerminal(environ_content);
                self.logger.debug("Got terminal: {s}", .{self.terminal});
            },
            .session => {
                self.is_wayland = utils.getEnvValue(environ_content, wayland_prefix) != null;
                self.logger.debug("Session type: {s}", .{if (self.is_wayland) "wayland" else "x11"});
            },
            .uptime => {
                const uptime_file = fs.openFileAbsolute("/proc/uptime", .{ .mode = .read_only }) catch |err| {
                    self.logger.warn("Failed to open uptime: {}", .{err});
                    return;
                };
                defer uptime_file.close();
                var uptime_reader = uptime_file.reader();
                var uptime_buf: [32]u8 = undefined;
                const uptime_str = uptime_reader.readUntilDelimiter(&uptime_buf, ' ') catch |err| {
                    self.logger.warn("Failed to read uptime: {}", .{err});
                    return;
                };
                const uptime_seconds = std.fmt.parseFloat(f64, uptime_str) catch 0;
                self.uptime_str = utils.formatUptime(@intFromFloat(uptime_seconds), &self.uptime_buf);
                self.logger.debug("Got uptime: {s}", .{self.uptime_str});
            },
            .pkgs => {
                self.logger.debug("Checking package paths", .{});
                const pkg_paths = [_][]const u8{
                    "/var/lib/pacman/local",
                    "/var/db/pkg",
                };

                for (pkg_paths) |pkg_path| {
                    self.logger.debug("Checking path: {s}", .{pkg_path});
                    if (fs.openDirAbsolute(pkg_path, .{ .iterate = true })) |dir| {
                        var mutable_dir = dir;
                        defer mutable_dir.close();

                        var count: usize = 0;
                        var it = mutable_dir.iterate();

                        while (it.next() catch break) |entry| {
                            if (entry.kind != .directory) continue;
                            const name = entry.name;
                            if (mem.eql(u8, name, ".") or
                                mem.eql(u8, name, "..")) continue;
                            count += 1;
                        }
                        self.pkg_count = count;
                        self.logger.debug("Found {d} packages in {s}", .{ count, pkg_path });
                        break;
                    } else |_| {
                        self.logger.debug("Failed to open {s}", .{pkg_path});
                        continue;
                    }
                }
            },
            .user => {},
        }
        self.logger.debug("Finished initializing field: {s}", .{@tagName(field)});
    }

    fn initAllFields(self: *Fetch, environ_content: []const u8) void {
        inline for (comptime std.meta.fields(config.Placeholder)) |field| {
            const placeholder = @field(config.Placeholder, field.name);
            if (self.config.needsField(placeholder)) {
                self.initField(placeholder, environ_content);
            }
        }
    }

    pub fn init() FetchError!Fetch {
        var logger = log.ScopedLogger.init("fetch");
        logger.setLevel(.debug);

        var cfg = config.Config.init() catch |err| {
            logger.err("Failed to initialize config: {}", .{err});
            return FetchError.ConfigInitFailed;
        };
        errdefer cfg.deinit();

        var self = Fetch{
            .config = cfg,
            .logger = logger,
            .hostname = "",
            .username = "",
            .shell = "",
            .terminal = "",
            .uptime_str = "",
            .pkg_count = 0,
            .is_wayland = false,
        };

        const environ_file = fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to open environ: {}", .{err});
            return FetchError.EnvironmentReadFailed;
        };
        defer environ_file.close();

        const bytes_read = environ_file.readAll(&self.environ_buf) catch |err| {
            logger.err("Failed to read environ: {}", .{err});
            return FetchError.EnvironmentReadFailed;
        };
        const environ_content = self.environ_buf[0..bytes_read];
        logger.debug("Read {} bytes from environ", .{bytes_read});

        if (utils.getEnvValue(environ_content, user_prefix)) |username| {
            if (username.len == 0) return FetchError.InvalidEnvironment;
            self.username = username;
            logger.debug("Got username: {s}", .{username});
        } else {
            logger.err("Username not found in environment", .{});
            return FetchError.UserNotFound;
        }

        self.initAllFields(environ_content);

        return self;
    }

    pub fn deinit(self: *Fetch) void {
        self.config.deinit();
    }

    pub fn format(
        self: Fetch,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        var result = self.config.format;
        inline for (std.meta.fields(config.Placeholder)) |field| {
            const placeholder = @field(config.Placeholder, field.name);
            if (self.config.needsField(placeholder)) {
                const symbol = placeholder.symbol();
                const value = switch (placeholder) {
                    .user => self.username,
                    .host => self.hostname,
                    .shell => self.shell,
                    .term => self.terminal,
                    .uptime => self.uptime_str,
                    .pkgs => blk: {
                        var buf: [20]u8 = undefined;
                        const slice = std.fmt.bufPrint(&buf, "{d}", .{self.pkg_count}) catch break :blk "0";
                        break :blk slice;
                    },
                    .session => if (self.is_wayland) "wayland" else "x11",
                };
                result = try utils.replaceAlloc(
                    config.Config.getAllocator(),
                    result,
                    symbol,
                    value,
                );
            }
        }

        try self.config.formatText(result, writer);
        try writer.writeByte('\n');
    }
};
