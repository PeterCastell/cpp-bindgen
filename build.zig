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
    test_step.dependOn(addGlueTests(b, target, optimize, "test-inline"));

    // Also exercise the MSVC ABI on a Windows x86_64 host (needs MSVC + SDK).
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        const msvc_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc });
        const msvc_step = b.step("test-msvc", "Run tests against the MSVC ABI (Windows x86_64 host only)");
        msvc_step.dependOn(addTests(b, msvc_target, optimize, "test-msvc"));
        msvc_step.dependOn(addGlueTests(b, msvc_target, optimize, "test-inline-msvc"));
    }
}

/// How to generate a C++ glue translation unit for a bindings module. See
/// `src/emit.zig` for what ends up in it.
pub const GlueOptions = struct {
    /// The module whose root source file declares `pub const cpp_manifest`.
    /// Pass the same module object the bindings are imported from: a source
    /// file may belong to only one module.
    bindings: *std.Build.Module,
    /// The target the glue is generated for. The generator runs on the build
    /// machine, so this has to be a target the build machine can execute; it
    /// is built for the target rather than for the host because the sizes and
    /// offsets it checks are the target's.
    target: std.Build.ResolvedTarget,
    name: []const u8 = "cpp-glue",
};

/// Generates the glue for a bindings module and returns its path, ready for
/// `Module.addCSourceFile`. Compile it with `glue_flags`.
///
/// ```zig
/// const cpp_bindgen = @import("cpp_bindgen");            // in build.zig
/// const dep = b.dependency("cpp_bindgen", .{ .target = target });
///
/// const bindings = b.createModule(.{ .root_source_file = b.path("src/bindings.zig"), .target = target });
/// bindings.addImport("cpp_bindgen", dep.module("cpp_bindgen"));
/// exe_mod.addImport("bindings", bindings);
///
/// const glue = cpp_bindgen.addCppGlue(b, dep, .{ .bindings = bindings, .target = target });
/// exe_mod.addCSourceFile(.{ .file = glue, .flags = cpp_bindgen.glue_flags });
/// ```
pub fn addCppGlue(b: *std.Build, dep: *std.Build.Dependency, opts: GlueOptions) std.Build.LazyPath {
    return generateGlue(b, dep.path("tools/emit.zig"), dep.module("cpp_bindgen"), opts);
}

/// `-fno-inline` is load-bearing: a constructor has no address to take, so the
/// glue can only name one by constructing an object, and an optimizer that
/// inlines that call drops the out-of-line copy the linker needs.
pub const glue_flags: []const []const u8 = &.{ "-std=c++17", "-fno-inline", "-Wno-invalid-offsetof" };

fn generateGlue(b: *std.Build, tool: std.Build.LazyPath, cpp_bindgen: *std.Build.Module, opts: GlueOptions) std.Build.LazyPath {
    const gen = b.createModule(.{ .root_source_file = tool, .target = opts.target });
    gen.addImport("cpp_bindgen", cpp_bindgen);
    gen.addImport("bindings", opts.bindings);

    const run = b.addRunArtifact(b.addExecutable(.{ .name = opts.name, .root_module = gen }));
    return run.addOutputFileArg("cpp_glue.cpp");
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
        // `-fno-inline` for the same reason the glue needs it: an optimized
        // build drops a compiler-generated helper nothing references
        // out of line, and MSVC's vbase destructor (`??_D`) is one.
        // The MSVC build also links no C++ runtime: drop the libc++ autolink
        // and RTTI.
        .flags = if (is_msvc)
            &.{ "-std=c++17", "-fno-inline", "-fno-autolink", "-fno-rtti" }
        else
            &.{ "-std=c++17", "-fno-inline" },
    });
    const tests = b.addTest(.{ .name = name, .root_module = mod });
    return &b.addRunArtifact(tests).step;
}

/// End to end: generate the glue for `test/inline_fixture.zig`, compile it
/// into a test binary, and call the header-only C++ it binds. A missing
/// definition fails at link time, and a wrong layout fails in the C++
/// compiler before that.
fn addGlueTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8) *std.Build.Step {
    const is_msvc = target.result.abi == .msvc;
    const lib = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target });
    const bindings = b.createModule(.{ .root_source_file = b.path("test/inline_fixture.zig"), .target = target });
    bindings.addImport("cpp_bindgen", lib);

    const glue = generateGlue(b, b.path("tools/emit.zig"), lib, .{
        .bindings = bindings,
        .target = target,
        .name = b.fmt("{s}-glue", .{name}),
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("test/inline_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = !is_msvc,
    });
    mod.addImport("cpp_bindgen", lib);
    mod.addImport("inline_fixture", bindings);
    mod.addIncludePath(b.path("test"));
    const msvc_flags: []const []const u8 = glue_flags ++ &[_][]const u8{ "-fno-autolink", "-fno-rtti" };
    mod.addCSourceFile(.{ .file = glue, .flags = if (is_msvc) msvc_flags else glue_flags });

    const tests = b.addTest(.{ .name = name, .root_module = mod });
    return &b.addRunArtifact(tests).step;
}
