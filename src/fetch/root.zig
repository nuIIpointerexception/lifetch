const std = @import("std");
const process = std.process;
const Io = std.Io;

pub const config = @import("../config.zig");
pub const debug = @import("../debug.zig");
pub const distro = @import("distro.zig");
pub const host = @import("host.zig");
pub const log = @import("../log.zig");
pub const pkg = @import("pkg.zig");
pub const session = @import("session.zig");
pub const terminal = @import("terminal.zig");
pub const uptime = @import("uptime.zig");
pub const user = @import("user.zig");
pub const utils = @import("../utils.zig");
pub const wm = @import("wm.zig");

pub const FetchError = error{
    InitializationFailed,
    ConfigInitFailed,
} || host.HostError ||
    user.UserError ||
    pkg.PackageError ||
    distro.DistroError ||
    session.SessionError ||
    terminal.TerminalError ||
    uptime.UptimeError ||
    wm.WmError ||
    config.ConfigError;

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    config: config.Config,
    color_support: terminal.ColorSupport,
    host_info: ?host.Host = null,
    user_info: ?user.User = null,
    pkg_info: ?pkg.PackageManager = null,
    distro_info: ?distro.Distro = null,
    session_info: ?session.Session = null,
    terminal_info: ?terminal.Terminal = null,
    uptime_info: ?uptime.Uptime = null,
    wm_info: ?wm.WindowManager = null,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator, io: Io, environ: process.Environ) FetchError!Fetch {
        var logger = log.ScopedLogger.init("fetch");
        logger.setLevel(.debug);

        var cfg = config.Config.init(io, environ) catch |err| {
            return switch (err) {
                error.HomeDirNotFound,
                error.ConfigDirCreationFailed,
                error.ConfigFileCreationFailed,
                error.ConfigFileReadFailed,
                error.ConfigParseError,
                error.InvalidColorFormat,
                error.InvalidStyleFormat,
                => FetchError.ConfigInitFailed,
                error.OutOfMemory => FetchError.InitializationFailed,
            };
        };
        errdefer cfg.deinit();

        var fetch = Fetch{
            .allocator = allocator,
            .config = cfg,
            .color_support = terminal.ColorSupport.init(io, environ),
            .logger = logger,
        };

        if (cfg.needsField(.host)) {
            fetch.host_info = try host.Host.init(allocator, io);
        }

        if (cfg.needsField(.user)) {
            fetch.user_info = try user.User.init(allocator, environ);
        }

        if (cfg.needsField(.pkgs)) {
            fetch.pkg_info = try pkg.PackageManager.init(allocator, io);
        }

        if (cfg.needsField(.distro) or cfg.needsField(.distro_pretty)) {
            fetch.distro_info = try distro.Distro.init(allocator, io);
        }

        if (cfg.needsField(.session)) {
            fetch.session_info = try session.Session.init(allocator, environ);
        }

        if (cfg.needsField(.term)) {
            fetch.terminal_info = try terminal.Terminal.init(allocator, io, environ);
        }

        if (cfg.needsField(.uptime)) {
            fetch.uptime_info = try uptime.Uptime.init(allocator, io);
        }

        if (cfg.needsField(.wm)) {
            fetch.wm_info = try wm.WindowManager.init(allocator, environ);
        }

        if (@import("builtin").mode == .Debug) {
            debug.dumpStruct("Fetch information", fetch);
        }

        return fetch;
    }

    pub fn deinit(self: *Fetch) void {
        self.config.deinit();

        if (self.host_info) |*h| h.deinit();
        if (self.user_info) |*u| u.deinit();
        if (self.pkg_info) |*p| p.deinit();
        if (self.distro_info) |*d| d.deinit();
        if (self.session_info) |*s| s.deinit();
        if (self.terminal_info) |*t| t.deinit();
        if (self.uptime_info) |*u| u.deinit();
        if (self.wm_info) |*w| w.deinit();
    }

    pub fn format(
        self: *const Fetch,
        writer: *Io.Writer,
    ) Io.Writer.Error!void {
        var pkg_count_buf: [16]u8 = undefined;
        var ctx = utils.FormatContext.init(self.allocator);
        defer ctx.deinit();

        const add_or_oom = struct {
            fn call(
                context: *utils.FormatContext,
                w: *Io.Writer,
                key: []const u8,
                value: []const u8,
            ) Io.Writer.Error!bool {
                context.add(key, value) catch {
                    try w.writeAll("[format error: out of memory]\n");
                    return true;
                };
                return false;
            }
        }.call;

        if (self.host_info) |h| {
            if (try add_or_oom(&ctx, writer, "host", h.hostname)) return;
        }

        if (self.user_info) |u| {
            if (try add_or_oom(&ctx, writer, "user", u.username)) return;
            if (try add_or_oom(&ctx, writer, "shell", u.shell)) return;
        }

        if (self.pkg_info) |p| {
            const pkg_count_fmt = std.fmt.bufPrint(&pkg_count_buf, "{d}", .{p.pkg_count}) catch "0";
            if (try add_or_oom(&ctx, writer, "pkgs", pkg_count_fmt)) return;
        }

        if (self.distro_info) |d| {
            if (try add_or_oom(&ctx, writer, "distro", d.id)) return;
            if (try add_or_oom(&ctx, writer, "distro_version", d.version)) return;
            if (try add_or_oom(&ctx, writer, "distro_pretty", d.name)) return;
        }

        if (self.session_info) |s| {
            if (try add_or_oom(&ctx, writer, "de", s.desktop)) return;
            if (try add_or_oom(&ctx, writer, "session", s.display_server)) return;
        }

        if (self.uptime_info) |u| {
            if (try add_or_oom(&ctx, writer, "uptime", u.formatted)) return;
        }

        if (self.wm_info) |w| {
            if (try add_or_oom(&ctx, writer, "wm", w.name)) return;
        }

        if (self.terminal_info) |t| {
            if (try add_or_oom(&ctx, writer, "term", t.name)) return;
        }

        const formatted = ctx.format(self.config.format) catch {
            return try writer.writeAll("[format error: out of memory]\n");
        };
        defer self.allocator.free(formatted);

        self.color_support.formatText(formatted, writer) catch {
            return try writer.writeAll("[format error]\n");
        };

        try writer.writeByte('\n');
    }
};
