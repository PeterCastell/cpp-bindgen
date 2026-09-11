//! Bindings for `test/inline_fixture.hpp`, which defines everything inline.
//! Nothing here links unless the generated glue emitted a definition for it,
//! so this file is the end-to-end test of `emit.zig`.
//!
//! It is also the shape a real binding file takes: types, `Signature`
//! constants for whatever is header-only, and a `cpp_manifest` naming the
//! headers and the modules to scan.
const builtin = @import("builtin");
const cpp = @import("cpp_bindgen");

const Signature = cpp.Signature;

// A class's methods can be declared on the class: the glue scans a type's
// public declarations the same way it scans a module's.
pub const Counter = extern struct {
    n: c_int,
    pub const cpp_name = "inl::Counter";

    pub const get: Signature = .{ .name = "get", .ret = c_int, .this = *const @This() };
    pub const set: Signature = .{ .name = "set", .args = &.{c_int}, .this = *@This() };
    pub const magic: Signature = .{ .name = "magic", .ret = c_int, .class = @This() };
};

pub const Box = extern struct {
    v: c_int,
    pub const cpp_name = "inl::Box";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;

    pub const ctor: Signature = .{ .name = "*", .args = &.{c_int}, .this = *@This() };
    pub const dtor: Signature = .{ .name = "~", .this = *@This() };
    pub const get: Signature = .{ .name = "get", .ret = c_int, .this = *const @This() };
};

/// One vtable pointer, then the members. A field named with a leading `_` is
/// not a C++ member, so the glue checks the size and the alignment but asks
/// no question `offsetof` could not answer.
pub const Shape = extern struct {
    _vptr: *const anyopaque,
    k: c_int,
    _tail: [4]u8,
    pub const cpp_name = "inl::Shape";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const cpp_no_offsets = true;
};

pub const Array3 = extern struct {
    v: [3]c_int,
    pub const cpp_template = cpp.Template{ .name = "inl::Array", .args = &.{ .{ .type = c_int }, .{ .int = 3 } } };
};

pub const Rgb = extern struct {
    r: u8,
    g: u8,
    b: u8,
    pub const cpp_name = "inl::Rgb";
    pub const cpp_abi: cpp.ClassAbi = .trivial_copy;
};

// Free functions, and the methods of classes that keep theirs at module
// scope. A `Signature` constant is what the scan picks up, and `cpp.bind`
// takes the same value, so the glue and the call can never describe
// different functions.
pub const add: Signature = .{ .name = "inl::add", .args = &.{ c_int, c_int }, .ret = c_int };
pub const shape_ctor: Signature = .{ .name = "*", .args = &.{c_int}, .this = *Shape };
pub const shape_dtor: Signature = .{ .name = "~", .this = *Shape };
pub const shape_area: Signature = .{ .name = "area", .ret = c_int, .this = *const Shape, .virtual = true };
pub const tpl_sum: Signature = .{ .name = "inl::tpl_sum", .template_args = &.{.{ .type = c_int }}, .args = &.{ cpp.Ref(*const cpp.TParam(0)), cpp.Ref(*const cpp.TParam(0)) }, .ret = c_int };
pub const rgb_make: Signature = .{ .name = "inl::rgb_make", .args = &.{ c_int, c_int, c_int }, .ret = Rgb };
pub const rgb_total: Signature = .{ .name = "inl::rgb_total", .args = &.{Rgb}, .ret = c_int };

// `Array3`'s members come from the explicit instantiation the glue emits, not
// from a `Signature`, which is the whole point of instantiating a template.
pub const array_sum: Signature = .{ .name = "sum", .ret = c_int, .this = *const Array3 };
pub const array_size: Signature = .{ .name = "size", .ret = c_int, .class = Array3 };

pub const cpp_manifest: cpp.emit.Manifest = .{
    .headers = &.{"inline_fixture.hpp"},
    .modules = &.{@This()},
    // This build links no C++ runtime, and `Shape`'s virtual destructor pulls
    // in the deleting form, which calls `operator delete`.
    .prelude = if (builtin.target.abi == .msvc) "void operator delete(void*, size_t) noexcept {}" else "",
};
