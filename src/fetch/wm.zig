const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const WmError = error{
    WmDetectionFailed,
    EnvironReadFailed,
} || std.mem.Allocator.Error;

pub const WindowManager = struct {
    name: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    const wm_prefix = "XDG_CURRENT_DESKTOP=";
    const wayland_prefix = "WAYLAND_DISPLAY=";
    const wm_name_prefix = "DESKTOP_SESSION=";
    const hypr_prefix = "HYPRLAND_INSTANCE_SIGNATURE=";

    pub fn init(allocator: std.mem.Allocator) WmError!WindowManager {
        var logger = log.ScopedLogger.init("wm");

        const environ_file = fs.cwd().openFile("/proc/self/environ", .{ .mode = .read_only }) catch |err| {
            logger.err("Failed to open environ: {}", .{err});
            return WmError.EnvironReadFailed;
        };
        defer environ_file.close();

        var environ_buf: [2048]u8 = undefined;
        const bytes_read = environ_file.readAll(&environ_buf) catch |err| {
            logger.err("Failed to read environ: {}", .{err});
            return WmError.EnvironReadFailed;
        };
        const environ_content = environ_buf[0..bytes_read];

        if (utils.getEnvValue(environ_content, hypr_prefix)) |_| {
            return WindowManager{
                .name = try allocator.dupe(u8, "hyprland"),
                .allocator = allocator,
                .logger = logger,
            };
        }

        if (utils.getEnvValue(environ_content, wayland_prefix)) |_| {
            if (utils.getEnvValue(environ_content, wm_name_prefix)) |name| {
                return WindowManager{
                    .name = try allocator.dupe(u8, name),
                    .allocator = allocator,
                    .logger = logger,
                };
            }
        }

        if (utils.getEnvValue(environ_content, wm_prefix)) |de| {
            const wm_name = if (mem.eql(u8, de, "GNOME"))
                "mutter"
            else if (mem.eql(u8, de, "KDE"))
                "kwin"
            else if (mem.eql(u8, de, "XFCE"))
                "xfwm4"
            else if (mem.eql(u8, de, "i3"))
                "i3"
            else if (mem.eql(u8, de, "sway"))
                "sway"
            else if (mem.eql(u8, de, "bspwm"))
                "bspwm"
            else if (mem.eql(u8, de, "awesome"))
                "awesome"
            else
                de;

            return WindowManager{
                .name = try allocator.dupe(u8, wm_name),
                .allocator = allocator,
                .logger = logger,
            };
        }

        return WindowManager{
            .name = try allocator.dupe(u8, "unknown"),
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *WindowManager) void {
        self.allocator.free(self.name);
    }

    pub fn formatComponent(self: WindowManager, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        return utils.formatReplace(allocator, input, "wm", self.name);
    }
};
