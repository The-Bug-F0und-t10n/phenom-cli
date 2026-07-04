const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "phenom",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run phenom");
    run_step.dependOn(&run_cmd.step);

    const real_backend = b.option([]const u8, "real-backend", "Real backend for smoke test: ollama or llamacpp") orelse "llamacpp";
    const real_host = b.option([]const u8, "real-host", "Real backend host:port for smoke test") orelse "127.0.0.1:11434";
    const real_model = b.option([]const u8, "real-model", "Real model name for smoke test") orelse "phenom:latest";
    const real_prompt = b.option([]const u8, "real-prompt", "Real prompt for smoke test") orelse "Complete: PHENOM_REAL_7319";
    const real_expect = b.option([]const u8, "real-expect", "Expected visible text for smoke test") orelse "PHENOM_REAL_7319";

    const real_smoke_cmd = b.addRunArtifact(exe);
    real_smoke_cmd.step.dependOn(b.getInstallStep());
    real_smoke_cmd.addArgs(&.{
        "chat",
        "--backend",
        real_backend,
        "--host",
        real_host,
        "--model",
        real_model,
        "--prompt",
        real_prompt,
        "--max-tokens",
        "96",
        "--thinking",
        "off",
        "--expect-contains",
        real_expect,
        "--show-expect-status",
        "--fail-on-model-error",
    });

    const real_smoke_step = b.step("real-smoke", "Opt-in real backend smoke test. Requires active HOST:PORT.");
    real_smoke_step.dependOn(&real_smoke_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;
    test_mod.linkSystemLibrary("sqlite3", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
