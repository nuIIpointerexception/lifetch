const std = @import("std");

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
    host_info: ?host.Host = null,
    user_info: ?user.User = null,
    pkg_info: ?pkg.PackageManager = null,
    distro_info: ?distro.Distro = null,
    session_info: ?session.Session = null,
    terminal_info: ?terminal.Terminal = null,
    uptime_info: ?uptime.Uptime = null,
    wm_info: ?wm.WindowManager = null,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator) FetchError!Fetch {
        var logger = log.ScopedLogger.init("fetch");
        logger.setLevel(.debug);

        var cfg = config.Config.init() catch |err| {
            return switch (err) {
                error.HomeDirNotFound => FetchError.ConfigInitFailed,
                error.ConfigDirCreationFailed => FetchError.ConfigInitFailed,
                error.ConfigFileCreationFailed => FetchError.ConfigInitFailed,
                error.ConfigFileReadFailed => FetchError.ConfigInitFailed,
                error.ConfigParseError => FetchError.ConfigInitFailed,
                error.InvalidColorFormat => FetchError.ConfigInitFailed,
                error.InvalidStyleFormat => FetchError.ConfigInitFailed,
                error.OutOfMemory => FetchError.InitializationFailed,
                else => FetchError.ConfigInitFailed,
            };
        };
        errdefer cfg.deinit();

        var fetch = Fetch{
            .allocator = allocator,
            .config = cfg,
            .logger = logger,
        };

        if (cfg.needsField(.host)) {
            fetch.host_info = try host.Host.init(allocator);
        }

        if (cfg.needsField(.user)) {
            fetch.user_info = try user.User.init(allocator);
        }

        if (cfg.needsField(.pkgs)) {
            fetch.pkg_info = try pkg.PackageManager.init(allocator);
        }

        if (cfg.needsField(.distro) or cfg.needsField(.distro_pretty)) {
            fetch.distro_info = try distro.Distro.init(allocator);
        }

        if (cfg.needsField(.session)) {
            fetch.session_info = try session.Session.init(allocator);
        }

        if (cfg.needsField(.term)) {
            fetch.terminal_info = try terminal.Terminal.init(allocator);
        }

        if (cfg.needsField(.uptime)) {
            fetch.uptime_info = try uptime.Uptime.init(allocator);
        }

        if (cfg.needsField(.wm)) {
            fetch.wm_info = try wm.WindowManager.init(allocator);
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
        self: Fetch,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        var count: usize = 0;
        if (self.host_info != null) count += 1;
        if (self.user_info != null) count += 2;
        if (self.pkg_info != null) count += 1;
        if (self.distro_info != null) count += 3;
        if (self.session_info != null) count += 2;
        if (self.uptime_info != null) count += 1;
        if (self.wm_info != null) count += 1;
        if (self.terminal_info != null) count += 1;

        var pkg_count_buf: [16]u8 = undefined;
        var pkg_count_fmt: []const u8 = "";

        var ctx = utils.FormatContext.init(self.allocator);
        defer ctx.deinit();

        if (self.host_info) |h| {
            try ctx.add("host", h.hostname);
        }

        if (self.user_info) |u| {
            try ctx.add("user", u.username);
            try ctx.add("shell", u.shell);
        }

        if (self.pkg_info) |p| {
            pkg_count_fmt = std.fmt.bufPrint(&pkg_count_buf, "{d}", .{p.pkg_count}) catch "0";
            try ctx.add("pkgs", pkg_count_fmt);
        }

        if (self.distro_info) |d| {
            try ctx.add("distro", d.id);
            try ctx.add("distro_version", d.version);
            try ctx.add("distro_pretty", d.name);
        }

        if (self.session_info) |s| {
            try ctx.add("de", s.desktop);
            try ctx.add("session", s.display_server);
        }

        if (self.uptime_info) |u| {
            try ctx.add("uptime", u.formatted);
        }

        if (self.wm_info) |w| {
            try ctx.add("wm", w.name);
        }

        if (self.terminal_info) |t| {
            try ctx.add("term", t.name);
        }

        const formatted = try ctx.format(self.config.format);
        defer self.allocator.free(formatted);

        if (self.terminal_info) |t| {
            try t.formatText(formatted, writer);
        } else {
            try self.config.formatText(formatted, writer);
        }

        try writer.writeByte('\n');
    }
};
