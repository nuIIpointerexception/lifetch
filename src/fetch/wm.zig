const std = @import("std");
const process = std.process;
const mem = std.mem;

const log = @import("../log.zig");
const utils = @import("../utils.zig");

pub const WmError = error{
    WmDetectionFailed,
} || std.mem.Allocator.Error;

pub const WindowManager = struct {
    name: []const u8,
    allocator: std.mem.Allocator,
    logger: log.ScopedLogger,

    pub fn init(allocator: std.mem.Allocator, environ: process.Environ) WmError!WindowManager {
        const logger = log.ScopedLogger.init("wm");

        if (process.Environ.getPosix(environ, "HYPRLAND_INSTANCE_SIGNATURE")) |_| {
            return WindowManager{
                .name = try allocator.dupe(u8, "hyprland"),
                .allocator = allocator,
                .logger = logger,
            };
        }

        if (process.Environ.getPosix(environ, "WAYLAND_DISPLAY")) |_| {
            if (process.Environ.getPosix(environ, "DESKTOP_SESSION")) |name| {
                return WindowManager{
                    .name = try allocator.dupe(u8, name),
                    .allocator = allocator,
                    .logger = logger,
                };
            }
        }

        if (process.Environ.getPosix(environ, "XDG_CURRENT_DESKTOP")) |de| {
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
