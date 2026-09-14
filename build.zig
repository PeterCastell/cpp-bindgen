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

/// How to generate the C++ glue for a bindings module. See `src/emit.zig` for
/// what ends up in it.
pub const GenerateGlueOptions = struct {
    /// Where the scan starts. Pass the same module object your own code
    /// imports the bindings from: a source file may belong to only one
    /// module. Files it publicly re-exports are scanned too, so
    /// `pub const string = @import("string.zig");` is all a second binding
    /// file needs.
    binding_module: *std.Build.Module,
    /// `#include` lines for the glue, verbatim and in order. A bare name is
    /// quoted; one already spelled `<vector>` or `"x.h"` is taken as written.
    headers: []const []const u8 = &.{},
    /// The target the glue is generated for. The generator runs on the build
    /// machine, so this has to be a target the build machine can execute; it
    /// is built for the target rather than for the host because the sizes and
    /// offsets it checks are the target's.
    target: std.Build.ResolvedTarget,
    /// Names the generator executable, its build step, and the file it writes
    /// (`<name>.cpp`). Give each glue in a build its own, or they are told
    /// apart only by a cache digest.
    name: []const u8 = "cpp-glue",
};

/// What to generate, and where to compile it. The generation half is spelled
/// exactly as `GenerateGlueOptions` spells it.
pub const AddGlueOptions = struct {
    /// The module the generated C++ is compiled into. It inherits that
    /// module's include paths, which is what lets the glue find the headers.
    attach_to: *std.Build.Module,
    /// The C++ language version to compile the glue at, or null to name none.
    /// It has to match the rest of your C++. A header that gates a member, an
    /// operator, or a layout on `__cplusplus` is a *different class* at a
    /// different version, and then the facts the glue checks and the
    /// definitions it emits are not the ones that will be linked.
    std: ?[]const u8 = "c++17",
    /// Extra flags for the glue, appended after `std`. Give it the same
    /// defines as the rest of your C++: the facts it checks are only the
    /// facts that will be linked if it sees the same declarations. Nothing
    /// here is mandatory -- the glue carries what it needs in its own source
    /// -- so a flag that appears later wins, `-std=` included.
    flags: []const []const u8 = &.{},

    binding_module: *std.Build.Module,
    headers: []const []const u8 = &.{},
    target: std.Build.ResolvedTarget,
    name: []const u8 = "cpp-glue",
};

/// Generates the C++ glue for a bindings module and compiles it into
/// `attach_to`. The bindings themselves hold nothing but types and
/// signatures; everything the glue needs is here.
///
/// ```zig
/// const cpp_bindgen = @import("cpp_bindgen");            // in build.zig
/// const dep = b.dependency("cpp_bindgen", .{ .target = target });
///
/// const bindings = b.createModule(.{ .root_source_file = b.path("src/bindings.zig"), .target = target });
/// bindings.addImport("cpp_bindgen", dep.module("cpp_bindgen"));
/// exe_mod.addImport("bindings", bindings);
///
/// cpp_bindgen.addCppGlue(b, dep, .{
///     .attach_to = exe_mod,
///     .binding_module = bindings,
///     .headers = &.{"ofMain.h"},
///     .target = target,
/// });
/// ```
pub fn addCppGlue(b: *std.Build, dep: *std.Build.Dependency, opts: AddGlueOptions) void {
    addGlue(b, dep.path("tools/emit.zig"), dep.module("cpp_bindgen"), opts);
}

/// Generates the C++ glue and hands back the path, compiling nothing. Use it
/// to place the glue yourself -- in a static library of its own, in one of
/// several modules, behind an `addInstallFile` so you can read what the
/// bindings actually asked the C++ compiler -- where `addCppGlue` would put
/// it in the one module you name.
///
/// The file it writes needs no particular flags to be correct, so the only
/// thing it asks of whoever compiles it is the thing `addCppGlue` cannot ask
/// for you: the same language version, defines, and include paths as the rest
/// of your C++.
///
/// ```zig
/// const glue = cpp_bindgen.generateCppGlue(b, dep, .{
///     .binding_module = bindings,
///     .headers = &.{"ofMain.h"},
///     .target = target,
/// });
/// lib_mod.addCSourceFile(.{ .file = glue, .flags = &.{ "-std=c++17", "-DNDEBUG" } });
/// b.getInstallStep().dependOn(&b.addInstallFile(glue, "glue/cpp-glue.cpp").step);
/// ```
pub fn generateCppGlue(b: *std.Build, dep: *std.Build.Dependency, opts: GenerateGlueOptions) std.Build.LazyPath {
    return generateGlue(b, dep.path("tools/emit.zig"), dep.module("cpp_bindgen"), opts);
}

fn addGlue(b: *std.Build, tool: std.Build.LazyPath, cpp_bindgen: *std.Build.Module, opts: AddGlueOptions) void {
    const glue = generateGlue(b, tool, cpp_bindgen, .{
        .binding_module = opts.binding_module,
        .headers = opts.headers,
        .target = opts.target,
        .name = opts.name,
    });
    const std_flag: []const []const u8 = if (opts.std) |v| &.{b.fmt("-std={s}", .{v})} else &.{};
    const flags = b.allocator.alloc([]const u8, std_flag.len + opts.flags.len) catch @panic("OOM");
    @memcpy(flags[0..std_flag.len], std_flag);
    @memcpy(flags[std_flag.len..], opts.flags);
    opts.attach_to.addCSourceFile(.{ .file = glue, .flags = flags });
}

fn generateGlue(b: *std.Build, tool: std.Build.LazyPath, cpp_bindgen: *std.Build.Module, opts: GenerateGlueOptions) std.Build.LazyPath {
    // The manifest is generated rather than written by hand, so a binding
    // file carries no build metadata at all.
    const manifest = b.createModule(.{ .root_source_file = writeManifest(b, opts.headers), .target = opts.target });
    manifest.addImport("cpp_bindgen", cpp_bindgen);
    manifest.addImport("bindings", opts.binding_module);

    const gen = b.createModule(.{ .root_source_file = tool, .target = opts.target });
    gen.addImport("cpp_bindgen", cpp_bindgen);
    gen.addImport("manifest", manifest);

    const run = b.addRunArtifact(b.addExecutable(.{ .name = opts.name, .root_module = gen }));
    // Named after the glue rather than fixed, so that two of them installed
    // side by side are two files.
    return run.addOutputFileArg(b.fmt("{s}.cpp", .{opts.name}));
}

fn writeManifest(b: *std.Build, headers: []const []const u8) std.Build.LazyPath {
    var text: []const u8 =
        \\// Generated by cpp-bindgen's build.zig. Do not edit.
        \\const cpp = @import("cpp_bindgen");
        \\
        \\pub const cpp_manifest: cpp.emit.Manifest = .{
        \\    .headers = &.{
        \\
    ;
    for (headers) |h| text = b.fmt("{s}        \"{f}\",\n", .{ text, std.zig.fmtString(h) });
    return b.addWriteFiles().add("cpp_manifest.zig", b.fmt(
        \\{s}    }},
        \\    .modules = &.{{@import("bindings")}},
        \\}};
        \\
    , .{text}));
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
        // `-fno-inline` because an optimized build drops a compiler-generated
        // helper nothing references out of line, and MSVC's vbase destructor
        // (`??_D`) is one. This fixture is written by hand, so it has nowhere
        // to say so in its own source the way the generated glue does.
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

    const mod = b.createModule(.{
        .root_source_file = b.path("test/inline_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = !is_msvc,
    });
    mod.addImport("cpp_bindgen", lib);
    mod.addImport("inline_fixture", bindings);
    mod.addIncludePath(b.path("test"));

    // This build links no C++ runtime, because the MSVC one is not on a
    // search path Zig sets up; `Shape`'s virtual destructor needs the
    // deleting form, which calls `operator delete`.
    if (is_msvc) mod.addCSourceFile(.{
        .file = b.path("test/msvc_support.cpp"),
        .flags = &.{ "-std=c++17", "-fno-autolink", "-fno-rtti" },
    });

    addGlue(b, b.path("tools/emit.zig"), lib, .{
        .attach_to = mod,
        .binding_module = bindings,
        .headers = &.{"inline_fixture.hpp"},
        .flags = if (is_msvc) &.{ "-fno-autolink", "-fno-rtti" } else &.{},
        .target = target,
        .name = b.fmt("{s}-glue", .{name}),
    });

    const tests = b.addTest(.{ .name = name, .root_module = mod });
    return &b.addRunArtifact(tests).step;
}
