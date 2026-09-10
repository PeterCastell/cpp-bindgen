const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("cpp_bindgen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(addTests(b, target, optimize, "test"));

    // Also exercise the MSVC ABI on a Windows x86_64 host (needs MSVC + SDK).
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        const msvc_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc });
        const msvc_step = b.step("test-msvc", "Run tests against the MSVC ABI (Windows x86_64 host only)");
        msvc_step.dependOn(addTests(b, msvc_target, optimize, "test-msvc"));
    }
}

fn addTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8) *std.Build.Step {
    const is_msvc = target.result.abi == .msvc;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = !is_msvc,
    });
    mod.addCSourceFile(.{
        .file = b.path("test/fixture.cpp"),
        // The MSVC build links no C++ runtime: drop the libc++ autolink and RTTI.
        .flags = if (is_msvc) &.{ "-std=c++17", "-fno-autolink", "-fno-rtti" } else &.{"-std=c++17"},
    });
    const tests = b.addTest(.{ .name = name, .root_module = mod });
    return &b.addRunArtifact(tests).step;
}
