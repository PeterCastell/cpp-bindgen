//! A second binding file, reached only because `inline_fixture.zig` publicly
//! re-exports it. Nothing here is named in `build.zig`.
const cpp = @import("cpp_bindgen");

pub const Pair = extern struct {
    a: c_int,
    b: c_int,
    pub const cpp_name = "inl::Pair";

    pub const sum: cpp.Signature = .{ .name = "sum", .ret = c_int, .this = *const @This() };
};

pub const pair_make: cpp.Signature = .{ .name = "inl::pair_make", .args = &.{ c_int, c_int }, .ret = Pair };
