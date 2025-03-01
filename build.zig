const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addAnonymousImport("config", .{
        .root_source_file = b.path("config.ini"),
    });

    const exe = b.addExecutable(.{
        .name = "lifetch",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "fetch your system info");
    run_step.dependOn(&run_cmd.step);
}
