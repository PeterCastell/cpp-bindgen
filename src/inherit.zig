//! Base classes. A derived class declares its bases (`cpp_bases`, in C++
//! source order) and whether it has virtual functions (`cpp_polymorphic`),
//! and spells the space they take as its first field:
//!
//! ```zig
//! pub const Camera = extern struct {
//!     _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
//!     lens: f64,          // the class's own members follow, named or opaque
//!     pub const cpp_name = "ofCamera";
//!     pub const cpp_bases: []const type = &.{Node};
//! };
//! ```
//!
//! Everything else is computed here: where each base sits, whether a vtable
//! pointer comes first, how far `this` moves to reach a base's method, and the
//! whole chain composes because `BaseSpan` reads the bases' own layouts. The
//! rules are the ABI's, measured against clang on both:
//!
//! - A base subobject is placed at the next offset aligned for it. The next
//!   offset is where the previous one *ends*, and the two ABIs disagree on
//!   where that is: MSVC after its whole `sizeof`, Itanium after only its data
//!   (`nvsize`), so that a derived class packs into a non-POD base's tail
//!   padding. `extent` is that difference.
//! - The first polymorphic base is the primary base: it goes to offset 0 and
//!   the derived class shares its vtable pointer, whatever the declaration
//!   order put first. Every other base follows in declaration order.
//! - A class with virtual functions and no polymorphic base gets a vtable
//!   pointer of its own, at 0, ahead of every base.
//! - Virtual bases have no fixed offset and are refused.
const std = @import("std");
const builtin = @import("builtin");
const ctype = @import("ctype.zig");

/// The layout rule follows the target's C++ ABI, as the mangling does.
const msvc = builtin.target.abi == .msvc;

/// A direct base and where it sits in the derived class.
pub const BaseRef = struct { type: type, offset: comptime_int };

/// The type of a derived class's first field, `_bases`: one byte per byte of
/// base subobjects (and of the class's own vtable pointer, if it has one).
/// Written as a bare array with `align(baseAlign(@This()))` on the field:
/// wrapping it in a struct would round its size up to its alignment, and
/// Itanium needs the unpadded length so the next field can follow at once.
pub fn BaseSpan(comptime T: type) type {
    return [place(T).end]u8;
}

/// The alignment of `_bases`: the strictest of the bases' (and the vtable
/// pointer's, if the class introduces one). The class's own alignment is
/// not consulted -- it cannot be, from inside its own field list -- and
/// need not be: it is the maximum over all fields, and each own field
/// carries its own.
pub fn baseAlign(comptime T: type) comptime_int {
    return place(T).alignment;
}

/// The offset of `Base` inside `Derived`, through any number of levels, or
/// null when `Base` is not a base of `Derived` at all. `Derived` itself is at
/// 0.
pub fn baseOffset(comptime Derived: type, comptime Base: type) ?comptime_int {
    if (Derived == Base) return 0;
    @setEvalBranchQuota(1 << 16);
    inline for (comptime directBases(Derived)) |b| {
        if (baseOffset(b.type, Base)) |inner| return b.offset + inner;
    }
    return null;
}

/// Upcasts a `*Derived` (or `*const Derived`) to the `Base` subobject inside
/// it. A compile error if `Base` is not a base of the pointee.
pub fn basePtr(comptime Base: type, ptr: anytype) BasePtr(Base, @TypeOf(ptr)) {
    const off = comptime baseOffset(pointee(@TypeOf(ptr)), Base) orelse
        @compileError(@typeName(Base) ++ " is not a base of " ++ @typeName(pointee(@TypeOf(ptr))) ++ "; list it in cpp_bases");
    return @ptrFromInt(@intFromPtr(ptr) + off);
}

fn BasePtr(comptime Base: type, comptime P: type) type {
    return if (@typeInfo(P).pointer.attrs.@"const") *const Base else *Base;
}

fn pointee(comptime P: type) type {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one) @compileError("basePtr takes a single-item pointer, got " ++ @typeName(P));
    return info.pointer.child;
}

/// The direct bases of `T` with their offsets. Empty for a class that
/// declares none.
pub fn directBases(comptime T: type) []const BaseRef {
    return place(T).refs;
}

/// Whether the C++ class has virtual functions: declared (`cpp_polymorphic`,
/// or `cpp_virtual_dtor`, which implies it) or inherited from a base.
pub fn isPolymorphic(comptime T: type) bool {
    if (declaresPolymorphic(T)) return true;
    inline for (comptime bases(T)) |Base| if (isPolymorphic(Base)) return true;
    return false;
}

/// Checks that a class which needs a base span spells it: `_bases` first,
/// of the computed type, at least as aligned as the bases need. Called from
/// wherever the layout is consumed rather than from `BaseSpan`, which runs
/// inside the field list it would have to inspect.
pub fn checkSpan(comptime T: type) void {
    // A root class may spell its own vtable pointer as `_bases` or as a
    // pointer field; only a class with bases has to use the computed span.
    if (bases(T).len == 0) return;
    const p = place(T);
    const s = @typeInfo(T).@"struct";
    const first = "_bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This()))";
    if (s.field_names.len == 0 or !std.mem.eql(u8, s.field_names[0], "_bases"))
        @compileError(@typeName(T) ++ ": a class with bases (or its own vtable pointer) starts with `" ++ first ++ "`");
    if (s.field_types[0] != BaseSpan(T))
        @compileError(@typeName(T) ++ ": `_bases` is " ++ @typeName(s.field_types[0]) ++ ", not " ++ @typeName(BaseSpan(T)) ++ "; spell it `" ++ first ++ "`");
    const a = s.field_attrs[0].@"align" orelse 1;
    if (a < p.alignment)
        @compileError(@typeName(T) ++ ": `_bases` is aligned to " ++ ctype.decimal(a) ++ " but its bases need " ++ ctype.decimal(p.alignment) ++ "; spell it `" ++ first ++ "`");
}

fn bases(comptime T: type) []const type {
    if (!@hasDecl(T, "cpp_bases")) return &.{};
    return T.cpp_bases;
}

fn declaresPolymorphic(comptime T: type) bool {
    const vdtor = @hasDecl(T, "cpp_virtual_dtor") and T.cpp_virtual_dtor;
    if (@hasDecl(T, "cpp_polymorphic")) {
        if (vdtor and !T.cpp_polymorphic) @compileError(@typeName(T) ++ ": cpp_virtual_dtor makes the class polymorphic, so cpp_polymorphic cannot be false");
        return T.cpp_polymorphic;
    }
    return vdtor;
}

/// The derived class needs a vtable pointer of its own only when it has
/// virtual functions and no polymorphic base to share one with.
fn introducesVfptr(comptime T: type) bool {
    if (!declaresPolymorphic(T)) return false;
    inline for (comptime bases(T)) |Base| if (isPolymorphic(Base)) return false;
    return true;
}

/// How much of a base the next thing in the derived class must stay clear
/// of. MSVC: all of it. Itanium: only its data, except for a POD base, which
/// keeps its padding on every ABI. Itanium's POD is C++03's -- a class with a
/// base is never one -- and `.c_struct` (trivial and standard-layout, checked
/// by the glue) is the same thing once bases are ruled out.
pub fn extent(comptime T: type) comptime_int {
    if (msvc) return @sizeOf(T);
    const abi: ctype.ClassAbi = if (@hasDecl(T, "cpp_abi")) T.cpp_abi else .c_struct;
    if (abi == .c_struct and bases(T).len == 0) return @sizeOf(T);
    return dataEnd(T);
}

/// Where the last field ends. A member of class type occupies its whole
/// `sizeof`, so only the outermost class is unpadded; a class whose last field
/// is `_bases` ends where its last base's data does.
fn dataEnd(comptime T: type) comptime_int {
    if (@typeInfo(T) != .@"struct") return @sizeOf(T);
    const names = @typeInfo(T).@"struct".field_names;
    if (names.len == 0) return 0;
    const last = names[names.len - 1];
    return @offsetOf(T, last) + @sizeOf(@FieldType(T, last));
}

const Placement = struct { refs: []const BaseRef, end: comptime_int, alignment: comptime_int };

fn place(comptime T: type) Placement {
    if (@hasDecl(T, "cpp_virtual_bases") and T.cpp_virtual_bases)
        @compileError(@typeName(T) ++ ": a virtual base has no fixed offset in its derived class, so its bases cannot be placed; spell the layout by hand and reach the base through a C++ thunk");
    @setEvalBranchQuota(1 << 16);
    const list = bases(T);
    comptime var refs: []const BaseRef = &.{};
    comptime var cursor: comptime_int = 0;
    comptime var alignment: comptime_int = 1;
    if (introducesVfptr(T)) {
        cursor = @sizeOf(*const anyopaque);
        alignment = @alignOf(*const anyopaque);
    }
    inline for (comptime order(T, list)) |Base| {
        const a = @alignOf(Base);
        const off = roundUp(cursor, a);
        refs = refs ++ &[_]BaseRef{.{ .type = Base, .offset = off }};
        cursor = off + extent(Base);
        if (a > alignment) alignment = a;
    }
    return .{ .refs = refs, .end = cursor, .alignment = alignment };
}

/// Layout order: the primary base first, the rest as declared.
fn order(comptime T: type, comptime list: []const type) []const type {
    inline for (list, 0..) |Base, i| {
        check(T, Base, list[0..i]);
        if (isPolymorphic(Base)) return &[_]type{Base} ++ list[0..i] ++ list[i + 1 ..];
    }
    return list;
}

fn check(comptime T: type, comptime Base: type, comptime before: []const type) void {
    if (Base == T) @compileError(@typeName(T) ++ ": a class cannot be its own base");
    if (@typeInfo(Base) != .@"struct" or @typeInfo(Base).@"struct".layout != .@"extern")
        @compileError(@typeName(T) ++ ": base " ++ @typeName(Base) ++ " must be an extern struct with the base's layout; an opaque type has no size to place");
    inline for (before) |Seen| if (Seen == Base) @compileError(@typeName(T) ++ ": " ++ @typeName(Base) ++ " is listed twice in cpp_bases");
}

fn roundUp(comptime n: comptime_int, comptime a: comptime_int) comptime_int {
    return @divFloor(n + a - 1, a) * a;
}

// Every number below was read off `clang -fdump-record-layouts` for the same
// C++ on both targets. Own members are spelled as named fields so that a
// wrong extent moves them and the assertion sees it.

// struct N { virtual ~N(); int a; char c; };   sizeof 16, data ends at 13
// struct C : N { double x; char z; };          sizeof 32, data ends at 25
// struct E : C { char y; };                    MSVC y@32 sizeof 40; Itanium y@25 sizeof 32
const N = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    a: c_int,
    c: u8,
    pub const cpp_name = "N";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
};
const C = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    x: f64,
    z: u8,
    pub const cpp_name = "C";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{N};
};
const E = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    y: u8,
    pub const cpp_name = "E";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{C};
};

test "a chain packs into tail padding on Itanium and not on MSVC" {
    try std.testing.expectEqual(8, @offsetOf(N, "a"));
    try std.testing.expectEqual(16, @sizeOf(N));
    try std.testing.expectEqual(16, @offsetOf(C, "x"));
    try std.testing.expectEqual(24, @offsetOf(C, "z"));
    try std.testing.expectEqual(32, @sizeOf(C));
    try std.testing.expectEqual(if (msvc) 32 else 25, @offsetOf(E, "y"));
    try std.testing.expectEqual(if (msvc) 40 else 32, @sizeOf(E));
    try std.testing.expectEqual(8, @alignOf(E));
    try std.testing.expectEqual(0, comptime baseOffset(E, C));
    try std.testing.expectEqual(0, comptime baseOffset(E, N));
    try std.testing.expectEqual(null, comptime baseOffset(N, E));
    try std.testing.expect(comptime isPolymorphic(E));
    comptime checkSpan(E);
}

// struct Pod { int a; char c; };                          sizeof 8, and POD: no packing into it
// struct P1 : Pod { virtual ~P1(); char d; };             vfptr@0, Pod@8, d@16, sizeof 24 on both
const Pod = extern struct {
    a: c_int,
    c: u8,
    pub const cpp_name = "Pod";
};
const P1 = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    d: u8,
    pub const cpp_name = "P1";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Pod};
    pub const cpp_virtual_dtor = true;
};

test "a polymorphic class over a POD base puts its vtable pointer first" {
    try std.testing.expectEqual(8, comptime baseOffset(P1, Pod));
    try std.testing.expectEqual(16, @offsetOf(P1, "d"));
    try std.testing.expectEqual(24, @sizeOf(P1));
    try std.testing.expectEqual(8, @alignOf(P1));
}

// The same class, polymorphic by declaration rather than by a virtual destructor.
const P1v = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    d: u8,
    pub const cpp_name = "P1v";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Pod};
    pub const cpp_polymorphic = true;
};

test "cpp_polymorphic stands in for a virtual destructor" {
    try std.testing.expect(comptime isPolymorphic(P1v));
    try std.testing.expect(!comptime isPolymorphic(Pod));
    try std.testing.expectEqual(8, comptime baseOffset(P1v, Pod));
    try std.testing.expectEqual(24, @sizeOf(P1v));
    const refs = comptime directBases(P1v);
    try std.testing.expectEqual(1, refs.len);
    try std.testing.expectEqual(Pod, refs[0].type);
    try std.testing.expectEqual(8, refs[0].offset);
}

// struct A { virtual ~A(); int a; };  struct B { virtual ~B(); int b; };
// struct AB : A, B { char d; };        A@0, B@16; MSVC d@32 sizeof 40; Itanium d@28 sizeof 32
// struct BA : B, A { char d; };        B@0, A@16
const A = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    a: c_int,
    pub const cpp_name = "A";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
};
const B = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    b: c_int,
    pub const cpp_name = "B";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
};
const AB = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    d: u8,
    pub const cpp_name = "AB";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ A, B };
};
const BA = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    d: u8,
    pub const cpp_name = "BA";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ B, A };
};

test "two polymorphic bases: the first declared is primary, the second keeps its vtable pointer" {
    try std.testing.expectEqual(0, comptime baseOffset(AB, A));
    try std.testing.expectEqual(16, comptime baseOffset(AB, B));
    try std.testing.expectEqual(if (msvc) 32 else 28, @offsetOf(AB, "d"));
    try std.testing.expectEqual(if (msvc) 40 else 32, @sizeOf(AB));
    try std.testing.expectEqual(0, comptime baseOffset(BA, B));
    try std.testing.expectEqual(16, comptime baseOffset(BA, A));
    var ab: AB = undefined;
    try std.testing.expectEqual(@intFromPtr(&ab) + 16, @intFromPtr(basePtr(B, &ab)));
    const cab: *const AB = &ab;
    try std.testing.expectEqual(*const B, @TypeOf(basePtr(B, cab)));
}

// struct P3 : Pod, A { };   the polymorphic base is primary though declared second: A@0;
//                            Pod after it -- MSVC @16, Itanium @12, packed into A's tail padding
const P3 = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    pub const cpp_name = "P3";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ Pod, A };
};

test "a polymorphic base is primary whatever the declaration order" {
    try std.testing.expectEqual(0, comptime baseOffset(P3, A));
    try std.testing.expectEqual(if (msvc) 16 else 12, comptime baseOffset(P3, Pod));
    try std.testing.expectEqual(24, @sizeOf(P3));
}

// struct A16 { virtual ~A16(); alignas(16) char x; char y[7]; };   sizeof 32, data ends at 24
// struct A16B : A16, B { char d; };   Itanium B@24 d@36 sizeof 48; MSVC B@32 d@48 sizeof 64
const A16 = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    x: u8 align(16),
    y: [7]u8,
    pub const cpp_name = "A16";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
};
const A16B = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    d: u8,
    pub const cpp_name = "A16B";
    pub const cpp_abi: ctype.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ A16, B };
};

test "a second base packs into the first one's tail padding on Itanium" {
    try std.testing.expectEqual(32, @sizeOf(A16));
    try std.testing.expectEqual(if (msvc) 32 else 24, comptime baseOffset(A16B, B));
    try std.testing.expectEqual(if (msvc) 48 else 36, @offsetOf(A16B, "d"));
    try std.testing.expectEqual(if (msvc) 64 else 48, @sizeOf(A16B));
    try std.testing.expectEqual(16, @alignOf(A16B));
}

// struct Empty {};  struct OverEmpty : Empty { int q; };   q@0, sizeof 4
const Empty = extern struct {
    pub const cpp_name = "Empty";
};
const OverEmpty = extern struct {
    _bases: BaseSpan(@This()) align(baseAlign(@This())),
    q: c_int,
    pub const cpp_name = "OverEmpty";
    pub const cpp_abi: ctype.ClassAbi = .trivial_copy;
    pub const cpp_bases: []const type = &.{Empty};
};

test "an empty base takes no space" {
    try std.testing.expectEqual(0, @offsetOf(OverEmpty, "q"));
    try std.testing.expectEqual(4, @sizeOf(OverEmpty));
}
