//! libc++, bound as a binding file would bind it: `std::` names written the
//! way C++ source writes them. The mangler puts them in `std::__1`, and the
//! members here that libc++ defines only in its headers are tagged
//! `[[gnu::abi_tag]]` there; the glue emits them untagged. Itanium targets
//! only: the MSVC build has a different standard library, and no runtime.
const cpp = @import("cpp_bindgen");

const Signature = cpp.Signature;

pub const String = extern struct {
    _storage: [3]usize,
    pub const cpp_template = cpp.Template{ .name = "std::basic_string", .kind = .class, .args = &.{
        .{ .type = u8 },
        .{ .template = .{ .name = "std::char_traits", .args = &.{.{ .type = u8 }} } },
        .{ .template = .{ .name = "std::allocator", .args = &.{.{ .type = u8 }}, .kind = .class } },
    } };
    pub const cpp_kind: cpp.Kind = .class;
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    // Explicitly instantiating all of `basic_string` would also instantiate
    // what the bindings never call.
    pub const cpp_no_instantiate = true;

    // Header-only and tagged in libc++.
    pub const ctor: Signature = .{ .name = "*", .args = &.{ [*]const u8, usize }, .this = *@This() };
    pub const size: Signature = .{ .name = "size", .ret = usize, .this = *const @This() };
    pub const c_str: Signature = .{ .name = "c_str", .ret = [*:0]const u8, .this = *const @This() };
    // Defined in the libc++ library, untagged.
    pub const dtor: Signature = .{ .name = "~", .this = *@This() };
};

/// A function in the libc++ library rather than its headers.
pub const stoi: Signature = .{ .name = "std::stoi", .args = &.{ cpp.Ref(*const String), ?*usize, c_int }, .ret = c_int };

/// Names libc++ keeps directly in `std`, which libc++abi defines.
pub const Exception = opaque {
    pub const cpp_name = "std::exception";
    pub const cpp_kind: cpp.Kind = .class;
    pub const what: Signature = .{ .name = "what", .ret = [*:0]const u8, .this = *const @This(), .virtual = true };
};
pub const terminate: Signature = .{ .name = "std::terminate" };
