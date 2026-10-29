const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .debug;
    const strip = b.option(bool, "strip", "Strip symbols (default: on in release)") orelse release;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = strip,
        .unwind_tables = if (release) .none else null,
        .omit_frame_pointer = if (release) strip else null,
        .error_tracing = false,
    });
    mod.addAnonymousImport("config", .{ .root_source_file = b.path("config.ini") });

    const exe = b.addExecutable(.{ .name = "lifetch", .root_module = mod });
    if (release) {
        // A GNU_STACK size makes start code raise RLIMIT_STACK: two prlimit calls per run.
        exe.stack_size = 0;
        exe.link_z_relro = false;
        exe.link_gc_sections = true;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "fetch your system info").dependOn(&run_cmd.step);

    // The fuzzer runtime crashes in a single-threaded test binary.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("config", .{ .root_source_file = b.path("config.ini") });
    const filters = b.option([]const []const u8, "test-filter", "Run only tests matching");
    const tests = b.addTest(.{ .root_module = test_mod, .filters = filters orelse &.{} });
    b.step("test", "run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
