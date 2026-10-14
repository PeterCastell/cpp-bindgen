//! What the target's C++ ABI does differently, in one place. The manglers
//! and the call planner ask here rather than testing the architecture or OS
//! themselves, so a new target is mostly new rows in these switches.
const std = @import("std");
const builtin = @import("builtin");
const Mangling = @import("root.zig").Mangling;

/// Where a call passes the pointer a class result is constructed into, for
/// a class returned through a hidden pointer.
pub const HiddenReturn = enum {
    /// An extra argument ahead of `this` and the rest: Itanium, `windows-gnu`
    /// included, everywhere but AArch64.
    first,
    /// An extra argument right after `this` (MSVC on x86_64).
    after_this,
    /// x8, which is not an argument register (AAPCS64, Apple's arm64 too).
    /// No calling convention Zig can declare puts a pointer there, so the
    /// call goes through an assembly trampoline.
    x8,
};

/// The target's `HiddenReturn` under `mangling`, or null where it is not
/// known: MSVC on ARM64 places the pointer by its own rules, which nothing
/// here implements yet.
pub fn hiddenReturn(comptime mangling: Mangling) ?HiddenReturn {
    if (builtin.cpu.arch.isAARCH64()) return if (mangling == .itanium) .x8 else null;
    return if (mangling == .itanium) .first else .after_this;
}

/// Whether base and complete constructors and destructors return `this`.
/// Clang's `AppleARM64CXXABI` says so for Apple's arm64 (in
/// `constructorsAndDestructorsReturnThis`, ItaniumCXXABI.cpp); the deleting
/// destructor still returns nothing. A caller may ignore the value, so it
/// matters only to a definition C++ calls, which `Subclass` writes.
pub const structors_return_this = builtin.cpu.arch.isAARCH64() and builtin.os.tag.isDarwin();

/// libc++, the standard library Zig compiles C++ against for every Itanium
/// target. Its names live in the inline namespace `std::__1`, which C++
/// source never needs to spell but every mangled name carries.
pub const libcxx = struct {
    /// `_LIBCPP_ABI_NAMESPACE`: `__1` for ABI version 1, the one Zig builds.
    pub const abi_namespace = "__1";

    /// The names libc++ declares directly in `std`, outside `abi_namespace`,
    /// so that they stay the names libc++abi and libsupc++ define: whatever
    /// `_LIBCPP_BEGIN_UNVERSIONED_NAMESPACE_STD` encloses in libc++'s headers.
    /// The glue checks each name it is given against the real headers, so a
    /// name missing here is a compile error in the glue, not a link error.
    ///
    /// A name is looked up here alone, so two overload sets come out wrong:
    /// the `swap` for `exception_ptr` and the operators on `std::byte` are
    /// unversioned, but share their names with versioned overloads, and are
    /// mangled as versioned. Bind those few through a C++ wrapper.
    pub const unversioned = [_][]const u8{
        // <exception>
        "exception",           "bad_exception",       "exception_ptr",
        "nested_exception",    "terminate",           "terminate_handler",
        "set_terminate",       "get_terminate",       "unexpected",
        "unexpected_handler",  "set_unexpected",      "get_unexpected",
        "uncaught_exception",  "uncaught_exceptions", "current_exception",
        "rethrow_exception",   "make_exception_ptr",  "throw_with_nested",
        "rethrow_if_nested",
        // <new>
          "bad_alloc",           "bad_array_new_length",
        "nothrow_t",           "nothrow",             "align_val_t",
        "destroying_delete_t", "destroying_delete",   "new_handler",
        "set_new_handler",     "get_new_handler",
        // <typeinfo>
            "type_info",
        "bad_cast",            "bad_typeid",
        // <any>, <variant>
                 "bad_any_cast",
        "bad_variant_access",
        // <cstddef>
         "byte",                "to_integer",
        // `_LIBCPP_BEGIN_NAMESPACE_EXPERIMENTAL`
        "experimental",
    };

    /// Whether `name`, the component right after `std`, is in `std::__1`.
    pub fn isVersioned(comptime name: []const u8) bool {
        for (unversioned) |u| if (std.mem.eql(u8, u, name)) return false;
        return true;
    }
};
