const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};

    const run_step = b.step("run", "Run moo");
    const mcp_step = b.step("mcp", "Build the bundled MCP server");
    const test_step = b.step("test", "Run unit tests");
    const integration_step = b.step("test-integration", "Run PTY integration tests");
    const test_all_step = b.step("test-all", "Run all tests");

    // Main executable module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("packages/moo-cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // libghostty-vt provides the terminal emulation core.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        // moo only consumes the ghostty-vt module, never ghostty's macOS
        // XCFramework. Building that artifact runs LibCInstallation.findNative,
        // which requires an Xcode/SDK setup that isn't always present (and
        // defaults on for a native macOS build). Skip it.
        .@"emit-xcframework" = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "moo",
        .root_module = exe_mod,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const mcp_out = b.getInstallPath(.bin, "moo-mcp-server");
    const mcp_build = b.addSystemCommand(&.{
        "bun",
        "build",
        "--compile",
        "apps/mcp-server/src/main.ts",
        "--outfile",
        mcp_out,
    });
    if (bunCompileTarget(target)) |bun_target| {
        mcp_build.addArgs(&.{ "--target", bun_target });
    }
    mcp_build.step.dependOn(&install_exe.step);
    const mcp_done = if (@import("builtin").os.tag == .macos and target.result.os.tag == .macos) blk: {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", mcp_out });
        sign.step.dependOn(&mcp_build.step);
        break :blk &sign.step;
    } else &mcp_build.step;
    mcp_step.dependOn(mcp_done);
    b.getInstallStep().dependOn(mcp_done);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Unit tests (in-process, no TTY required).
    const unit_tests = b.addTest(.{ .root_module = exe_mod, .filters = test_filters });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests: drive the real binary through a real PTY.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("exe_path", exe.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("packages/moo-cli/test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addOptions("build_options", test_opts);
    // The tests render captured client output through a terminal
    // emulator to assert what a user would actually see.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        // moo only consumes the ghostty-vt module, never ghostty's macOS
        // XCFramework. Building that artifact runs LibCInstallation.findNative,
        // which requires an Xcode/SDK setup that isn't always present (and
        // defaults on for a native macOS build). Skip it.
        .@"emit-xcframework" = false,
    })) |dep| {
        integration_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const integration_tests = b.addTest(.{ .root_module = integration_mod, .filters = test_filters });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    test_all_step.dependOn(test_step);
    test_all_step.dependOn(integration_step);

    // Benchmark: the viewport render hot path (no TTY required).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("packages/moo-cli/bench/render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        // moo only consumes the ghostty-vt module, never ghostty's macOS
        // XCFramework. Building that artifact runs LibCInstallation.findNative,
        // which requires an Xcode/SDK setup that isn't always present (and
        // defaults on for a native macOS build). Skip it.
        .@"emit-xcframework" = false,
    })) |dep| {
        bench_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    const bench_exe = b.addExecutable(.{
        .name = "moo-bench",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the render microbenchmark");
    bench_step.dependOn(&bench_run.step);
}

fn bunCompileTarget(target: std.Build.ResolvedTarget) ?[]const u8 {
    const result = target.result;
    return switch (result.os.tag) {
        .linux => switch (result.cpu.arch) {
            .x86_64 => "bun-linux-x64",
            .aarch64 => "bun-linux-arm64",
            else => null,
        },
        .macos => switch (result.cpu.arch) {
            .x86_64 => "bun-darwin-x64",
            .aarch64 => "bun-darwin-arm64",
            else => null,
        },
        else => null,
    };
}
