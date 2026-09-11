//! C++ type description -> C++ source text, the inverse of `ctype.fromZig`.
//! `emit.zig` uses it to write a glue translation unit that a C++ compiler
//! reads back, so every spelling here must be valid C++ in a context where
//! the class's own headers are included.
const std = @import("std");
const ctype = @import("ctype.zig");
const CType = ctype.CType;
const Component = ctype.Component;

/// The C++ spelling of a type: `const char*`, `ns::Vec2&`, `tpl::vec<3, float, (tpl::qualifier)1>`.
pub fn typeName(comptime t: CType) []const u8 {
    return switch (t) {
        .builtin => |b| builtinName(b),
        .pointer => |p| typeName(p.child.*) ++ (if (p.is_const) " const*" else "*") ++ (if (p.top_const) " const" else ""),
        .reference => |r| typeName(r.child.*) ++ (if (r.is_const) " const" else "") ++ (if (r.rvalue) "&&" else "&"),
        .named => |n| pathName(n.path),
    };
}

/// A qualified name, with template arguments where a component has them.
pub fn pathName(comptime path: []const Component) []const u8 {
    comptime var out: []const u8 = "";
    inline for (path, 0..) |c, i| {
        out = out ++ (if (i == 0) "" else "::") ++ c.name;
        if (c.args.len > 0) out = out ++ templateArgs(c.args);
    }
    return out;
}

fn templateArgs(comptime args: []const ctype.Arg) []const u8 {
    comptime var out: []const u8 = "<";
    inline for (args, 0..) |a, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ switch (a) {
            .type => |t| typeName(t),
            // A named non-type argument is an enumerator whose spelling Zig
            // never sees, only its value; the cast names the same argument.
            .integral => |v| switch (v.type) {
                .named => "(" ++ typeName(v.type) ++ ")" ++ ctype.signedDecimal(v.value),
                else => literal(v.type, v.value),
            },
        };
    }
    // `>>` lexes as a shift before C++11; separate them when it would occur.
    return out ++ (if (out[out.len - 1] == '>') " >" else ">");
}

fn literal(comptime t: CType, comptime v: i64) []const u8 {
    if (t == .builtin and t.builtin == .bool) return if (v != 0) "true" else "false";
    const digits = ctype.signedDecimal(v);
    // An `unsigned`/`long` argument must keep its type through the cast, or
    // the compiler picks a different specialization than the mangled name says.
    return switch (t) {
        .builtin => |b| switch (b) {
            .int => digits,
            else => "(" ++ builtinName(b) ++ ")" ++ digits,
        },
        else => digits,
    };
}

/// The parameter list of a function, `(int, char const*)`, or `()`.
pub fn paramList(comptime params: []const CType) []const u8 {
    if (params.len == 0) return "()";
    comptime var out: []const u8 = "(";
    inline for (params, 0..) |p, i| out = out ++ (if (i == 0) "" else ", ") ++ typeName(p);
    return out ++ ")";
}

/// The type of a pointer to `f`, as a cast target: a member-function pointer
/// for a method, a plain function pointer otherwise. Naming the type is what
/// disambiguates an overload set, so it is never omitted.
pub fn pointerType(comptime f: ctype.Function) []const u8 {
    const ret = typeName(f.ret) ++ " ";
    const params = paramList(f.params);
    if (f.this) |t| {
        const cls = pathName(f.path[0 .. f.path.len - 1]);
        return ret ++ "(" ++ cls ++ "::*)" ++ params ++ (if (t.is_const) " const" else "");
    }
    return ret ++ "(*)" ++ params;
}

/// A parameter declaration list, `(int a0, char const* a1)`, for a stub.
/// Only pointers and references occur in a bound signature, so the declarator
/// forms that would need the name in the middle cannot arise.
pub fn namedParamList(comptime params: []const CType) []const u8 {
    if (params.len == 0) return "()";
    comptime var out: []const u8 = "(";
    inline for (params, 0..) |p, i| out = out ++ (if (i == 0) "" else ", ") ++ typeName(p) ++ " a" ++ ctype.decimal(i);
    return out ++ ")";
}

/// The argument list matching `namedParamList`: `a0, a1`. A stub only has to
/// odr-use the callee, so an rvalue-reference parameter needs no `std::move`.
pub fn argList(comptime params: []const CType) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..params.len) |i| out = out ++ (if (i == 0) "" else ", ") ++ "a" ++ ctype.decimal(i);
    return out;
}

pub fn builtinName(comptime b: ctype.Builtin) []const u8 {
    return switch (b) {
        .void => "void",
        .bool => "bool",
        .char => "char",
        .schar => "signed char",
        .uchar => "unsigned char",
        .short => "short",
        .ushort => "unsigned short",
        .int => "int",
        .uint => "unsigned int",
        .long => "long",
        .ulong => "unsigned long",
        .longlong => "long long",
        .ulonglong => "unsigned long long",
        .float => "float",
        .double => "double",
        .longdouble => "long double",
        .wchar_t => "wchar_t",
        .char16_t => "char16_t",
        .char32_t => "char32_t",
    };
}

/// `struct`/`class`/`union`/`enum`, for an elaborated-type-specifier.
pub fn kindKeyword(comptime k: ctype.Kind) []const u8 {
    return @tagName(k);
}

test "type spellings" {
    const expect = std.testing.expectEqualStrings;
    try expect("int", comptime typeName(ctype.fromZig(c_int)));
    try expect("char const*", comptime typeName(ctype.fromZig([*:0]const u8)));
    try expect("void*", comptime typeName(ctype.fromZig(*anyopaque)));
    try expect("unsigned char*", comptime typeName(ctype.fromZig([*]ctype.uchar)));
    const S = opaque {
        pub const cpp_name = "a::b::S";
    };
    try expect("a::b::S*", comptime typeName(ctype.fromZig(*S)));
    try expect("a::b::S const&", comptime typeName(ctype.fromZig(ctype.Ref(*const S))));
    try expect("a::b::S&&", comptime typeName(ctype.fromZig(ctype.RRef(*S))));
    try expect("int* const&", comptime typeName(ctype.fromZig(ctype.Ref(*const [*c]c_int))));
}

test "template spellings" {
    const expect = std.testing.expectEqualStrings;
    const Q = enum(c_int) {
        lowp,
        highp,
        _,
        pub const cpp_name = "tpl::qualifier";
    };
    const V = extern struct {
        v: [3]f32,
        pub const cpp_template = ctype.Template{ .name = "tpl::vec", .args = &.{ .{ .int = 3 }, .{ .type = f32 }, .{ .value = .{ .type = Q, .int = 1 } } } };
    };
    try expect("tpl::vec<3, float, (tpl::qualifier)1>", comptime typeName(ctype.fromZig(V)));
    const F = extern struct {
        v: c_int,
        pub const cpp_template = ctype.Template{ .name = "Flags", .args = &.{ .{ .value = .{ .type = bool, .int = 1 } }, .{ .int = -1 } } };
    };
    try expect("Flags<true, -1>", comptime typeName(ctype.fromZig(F)));
    const L = extern struct {
        n: c_int,
        pub const cpp_template = ctype.Template{ .name = "tpl::List", .args = &.{ .{ .type = V }, .{ .template = .{ .name = "tpl::Alloc", .args = &.{.{ .type = V }} } } } };
    };
    try expect("tpl::List<tpl::vec<3, float, (tpl::qualifier)1>, tpl::Alloc<tpl::vec<3, float, (tpl::qualifier)1> > >", comptime typeName(ctype.fromZig(L)));
}

test "pointer and parameter spellings" {
    const expect = std.testing.expectEqualStrings;
    const C = extern struct {
        n: c_int,
        pub const cpp_name = "ns::Counter";
    };
    const f: ctype.Function = comptime .{
        .path = &.{ .{ .name = "ns" }, .{ .name = "Counter" }, .{ .name = "get" } },
        .params = &.{},
        .ret = ctype.fromZig(c_int),
        .this = .{ .is_const = true },
    };
    try expect("int (ns::Counter::*)() const", comptime pointerType(f));
    const g: ctype.Function = comptime .{
        .path = &.{ .{ .name = "ns" }, .{ .name = "add" } },
        .params = &.{ ctype.fromZig(c_int), ctype.fromZig(*const C) },
        .ret = ctype.fromZig(c_int),
    };
    try expect("int (*)(int, ns::Counter const*)", comptime pointerType(g));
    try expect("(int a0, ns::Counter const* a1)", comptime namedParamList(g.params));
    try expect("a0, a1", comptime argList(g.params));
}
