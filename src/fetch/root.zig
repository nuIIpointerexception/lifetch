const std = @import("std");

pub const config = @import("../config.zig");
pub const host = @import("host.zig");
pub const user = @import("user.zig");
pub const pkg = @import("pkg.zig");
pub const distro = @import("distro.zig");
pub const session = @import("session.zig");
pub const terminal = @import("terminal.zig");
pub const uptime = @import("uptime.zig");
pub const wm = @import("wm.zig");
pub const utils = @import("../utils.zig");
pub const log = @import("../log.zig");

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
    host_info: host.Host,
    user_info: user.User,
    pkg_info: pkg.PackageManager,
    distro_info: distro.Distro,
    session_info: session.Session,
    terminal_info: terminal.Terminal,
    uptime_info: uptime.Uptime,
    wm_info: wm.WindowManager,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator) FetchError!Fetch {
        var logger = log.ScopedLogger.init("fetch");
        logger.setLevel(.debug);

        var cfg = try config.Config.init();
        errdefer cfg.deinit();

        return Fetch{
            .allocator = allocator,
            .config = cfg,
            .logger = logger,
            .host_info = try host.Host.init(allocator),
            .user_info = try user.User.init(allocator),
            .pkg_info = try pkg.PackageManager.init(allocator),
            .distro_info = try distro.Distro.init(allocator),
            .session_info = try session.Session.init(allocator),
            .terminal_info = try terminal.Terminal.init(allocator),
            .uptime_info = try uptime.Uptime.init(allocator),
            .wm_info = try wm.WindowManager.init(allocator),
        };
    }

    pub fn deinit(self: *Fetch) void {
        self.config.deinit();
        self.host_info.deinit();
        self.user_info.deinit();
        self.pkg_info.deinit();
        self.distro_info.deinit();
        self.session_info.deinit();
        self.terminal_info.deinit();
        self.uptime_info.deinit();
        self.wm_info.deinit();
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

        result = try self.host_info.formatComponent(self.allocator, result);
        result = try self.user_info.formatComponent(self.allocator, result);
        result = try self.pkg_info.formatComponent(self.allocator, result);
        result = try self.distro_info.formatComponent(self.allocator, result);
        result = try self.session_info.formatComponent(self.allocator, result);
        result = try self.terminal_info.formatComponent(self.allocator, result);
        result = try self.uptime_info.formatComponent(self.allocator, result);
        result = try self.wm_info.formatComponent(self.allocator, result);

        try self.config.formatText(result, writer);
        try writer.writeByte('\n');
    }
};
