//! Writes the C++ glue for a bindings module. `build.zig`'s `addCppGlue`
//! builds this for the target being compiled, so `@sizeOf` here is the size
//! the target's Zig compilation will use, and runs it with the output path as
//! its only argument.
const std = @import("std");
const cpp = @import("cpp_bindgen");
const bindings = @import("bindings");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) std.process.fatal("usage: {s} <output.cpp>", .{args[0]});
    const text = comptime cpp.emit.render(bindings.cpp_manifest);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = text });
}
