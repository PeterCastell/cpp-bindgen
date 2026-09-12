//! Zig type -> C++ type description, consumed by both manglers.
const std = @import("std");
const builtin = @import("builtin");

/// C++ `wchar_t` (16 bits on Windows, 32 elsewhere), distinct from `u16`/`i32`.
pub const wchar_t = enum(if (builtin.os.tag == .windows) u16 else i32) { _ };
/// C++ `char16_t`.
pub const char16_t = enum(u16) { _ };
/// C++ `char32_t`.
pub const char32_t = enum(u32) { _ };
/// C++ `unsigned char`. Zig's `u8` maps to `char` (as translate-c does), so
/// this newtype exists to spell `unsigned char` when the C++ side uses it.
pub const uchar = enum(u8) { _ };

/// Marks a parameter or return type as a C++ lvalue reference. `P` is the
/// Zig pointer the call site passes: `Ref(*const T)` is `const T&` and
/// `Ref(*T)` is `T&`. A reference is passed exactly like a pointer on every
/// supported ABI; the marker only changes the mangled name. It never exists
/// at runtime: the bound function's actual parameter type is `P`.
pub fn Ref(comptime P: type) type {
    return opaque {
        pub const cpp_ref = P;
        pub const cpp_rvalue = false;
    };
}

/// Marks a C++ rvalue reference `T&&`. See `Ref`.
pub fn RRef(comptime P: type) type {
    return opaque {
        pub const cpp_ref = P;
        pub const cpp_rvalue = true;
    };
}

/// Marks a parameter or return type whose *pointer* is const, not its
/// pointee: `ConstPtr([*c]u8)` is `char* const` and
/// `ConstPtr([*c]const u8)` is `const char* const`. Itanium drops a
/// top-level qualifier from a parameter type, so this changes nothing there;
/// MSVC mangles it, spelling the pointer `Q` rather than `P`. The MSVC
/// standard library declares parameters this way, `basic_string`'s
/// `const char* const` constructors among them. Like `Ref`, the marker never
/// exists at run time: the bound function still takes `P`.
///
/// Only the outermost pointer needs it. A const pointer further in is the
/// parent pointer's pointee constness, which `*const [*c]T` already spells.
pub fn ConstPtr(comptime P: type) type {
    return opaque {
        pub const cpp_const_ptr = P;
    };
}

/// Marks the place a function template's declaration wrote one of its own
/// template parameters. `TParam(0)` is the first, `TParam(1)` the second.
///
/// Itanium mangles a function template specialization from the template's
/// declaration, not from the substituted signature: `f<std::string>(const T&)`
/// encodes its parameter as `RKT_`, a reference to template-parameter 0. MSVC
/// writes the substituted type instead, and takes it from the signature's
/// `template_args`, so one marker serves both.
pub fn TParam(comptime index: usize) type {
    return opaque {
        pub const cpp_template_param = index;
    };
}

pub fn isTParam(comptime T: type) bool {
    return @typeInfo(T) == .@"opaque" and @hasDecl(T, "cpp_template_param");
}

/// The pointer behind a `Ref`/`RRef`/`ConstPtr` marker, otherwise `T`.
pub fn resolve(comptime T: type) type {
    if (isRefMarker(T)) return T.cpp_ref;
    if (isConstPtrMarker(T)) return T.cpp_const_ptr;
    return T;
}

pub fn isRefMarker(comptime T: type) bool {
    return @typeInfo(T) == .@"opaque" and @hasDecl(T, "cpp_ref");
}

pub fn isConstPtrMarker(comptime T: type) bool {
    return @typeInfo(T) == .@"opaque" and @hasDecl(T, "cpp_const_ptr");
}

pub const Builtin = enum {
    void,
    bool,
    char,
    schar,
    uchar,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
    longlong,
    ulonglong,
    float,
    double,
    longdouble,
    wchar_t,
    char16_t,
    char32_t,

    pub fn isIntegral(b: Builtin) bool {
        return switch (b) {
            .void, .float, .double, .longdouble => false,
            else => true,
        };
    }
};

/// How the C++ side declared a named type. Only MSVC mangles the difference.
pub const Kind = enum { @"struct", class, @"union", @"enum" };

/// How a class travels when passed or returned by value, declared on the
/// Zig type as `pub const cpp_abi: ClassAbi`. Absent means `.c_struct`,
/// which is right for plain data but silently wrong for the other two, so
/// declare it for every class that has any constructor. Pointers and
/// references never need it.
pub const ClassAbi = enum {
    /// Could have been written in C: no user-declared constructors,
    /// destructor, or copy assignment; no bases, virtuals, private data, or
    /// reference members; every member also `.c_struct`. Passed and returned
    /// exactly like a C struct on every ABI.
    c_struct,
    /// Copies are a memcpy (trivial copy/move constructors and destructor),
    /// but it has constructors, bases, private data, or copy assignment.
    /// Passed like a C struct everywhere; returned like one on Itanium, but
    /// through a hidden pointer on MSVC regardless of size.
    trivial_copy,
    /// A user-provided copy or move constructor or destructor, or virtual
    /// functions (Itanium: "non-trivial for the purposes of calls"). Passed
    /// as a pointer to a temporary and returned through a hidden pointer on
    /// every ABI. In a bound signature a by-value argument becomes `*T` and
    /// is consumed (destroyed) by the call; a by-value return becomes an
    /// out-pointer first parameter.
    managed_copy,
};

/// A class-template specialization such as `glm::vec<3, float, defaultp>`.
/// Use it as a Zig type's `cpp_name`, or nested inside another `Template`'s
/// arguments for a specialization that has no Zig type of its own (for
/// example `std::char_traits<char>`). Every argument must be given,
/// including ones the C++ declaration defaults: the mangled name always
/// carries all of them.
pub const Template = struct {
    /// Qualified template name, e.g. `"glm::vec"`.
    name: []const u8,
    args: []const TemplateArg,
    /// Only MSVC encodes this. When the `Template` is a Zig type's
    /// `cpp_name`, a `cpp_kind` declaration on that type takes precedence.
    kind: Kind = .@"struct",
};

/// One argument of a `Template`.
pub const TemplateArg = union(enum) {
    /// A type argument, mapped through `fromZig`.
    type: type,
    /// A type argument that is itself a specialization without a Zig type.
    template: Template,
    /// A non-type argument of type `int`.
    int: i64,
    /// A non-type argument of another integral, `bool`, or enum type. The
    /// declared type matters: Itanium mangles it, so `3` as `int` and as
    /// `unsigned` are different symbols. Enum types are Zig enums with a
    /// `cpp_name`; the value is the enumerator's integer value.
    value: Value,

    pub const Value = struct { type: type, int: i64 };
};

pub const CType = union(enum) {
    builtin: Builtin,
    pointer: Pointer,
    reference: Reference,
    named: Named,
    /// A template parameter of the enclosing function template, by index.
    /// Only Itanium encodes one; `substitute` replaces it for everyone else.
    template_param: usize,

    pub const Pointer = struct {
        child: *const CType,
        /// Pointee constness; a const pointer further in is the parent's
        /// `is_const`.
        is_const: bool,
        /// The pointer itself is const: `T* const`, from `ConstPtr`. Only
        /// MSVC mangles it, and only at the top level of a parameter or a
        /// return type.
        top_const: bool = false,
    };

    pub const Reference = struct {
        child: *const CType,
        is_const: bool,
        rvalue: bool,
    };

    pub const Named = struct {
        path: []const Component,
        kind: Kind,
        abi: ClassAbi = .c_struct,
    };

    /// Canonical spelling; the key for substitution / back-reference tables.
    pub fn key(comptime t: CType) []const u8 {
        return switch (t) {
            .builtin => |b| @tagName(b),
            .pointer => |p| p.child.key() ++ (if (p.is_const) " const*" else "*") ++ (if (p.top_const) " const" else ""),
            .reference => |r| r.child.key() ++ (if (r.is_const) " const" else "") ++ (if (r.rvalue) "&&" else "&"),
            .named => |n| pathKey(n.path),
            .template_param => |i| "$T" ++ decimal(i),
        };
    }
};

/// One component of a qualified name, with template arguments if any.
pub const Component = struct {
    name: []const u8,
    args: []const Arg = &.{},

    pub fn key(comptime c: Component) []const u8 {
        if (c.args.len == 0) return c.name;
        comptime var out: []const u8 = c.name ++ "<";
        inline for (c.args, 0..) |a, i| out = out ++ (if (i == 0) "" else ",") ++ a.key();
        return out ++ ">";
    }
};

pub const Arg = union(enum) {
    type: CType,
    integral: Integral,

    pub const Integral = struct { type: CType, value: i64 };

    pub fn key(comptime a: Arg) []const u8 {
        return switch (a) {
            .type => |t| t.key(),
            .integral => |v| v.type.key() ++ "=" ++ signedDecimal(v.value),
        };
    }
};

/// An overloadable operator. A signature names one by prefixing its C++
/// spelling with a colon: `":+"`, `":[]"`, `":delete"`. The colon is what
/// keeps `":~"` (`operator~`) apart from `"~"` (the destructor), and `":*"`
/// from `"*"` (the constructor).
pub const Op = struct {
    /// How C++ source spells it, for the glue.
    cpp: []const u8,
    /// Itanium code for the binary form, or for the only form there is.
    itanium: []const u8,
    /// Itanium code for the unary form, where one spelling serves both.
    /// MSVC uses a single code and leaves arity to the parameter list.
    itanium_unary: ?[]const u8 = null,
    msvc: []const u8,
    /// A conversion operator: Itanium puts the target type in the name.
    conversion: bool = false,
};

/// Every operator `bind` understands, keyed by the spelling after the colon.
/// The codes were read off clang's output for both ABIs.
const operators = [_]struct { name: []const u8, op: Op }{
    .{ .name = "+", .op = .{ .cpp = "operator+", .itanium = "pl", .itanium_unary = "ps", .msvc = "?H" } },
    .{ .name = "-", .op = .{ .cpp = "operator-", .itanium = "mi", .itanium_unary = "ng", .msvc = "?G" } },
    .{ .name = "*", .op = .{ .cpp = "operator*", .itanium = "ml", .itanium_unary = "de", .msvc = "?D" } },
    .{ .name = "&", .op = .{ .cpp = "operator&", .itanium = "an", .itanium_unary = "ad", .msvc = "?I" } },
    .{ .name = "/", .op = .{ .cpp = "operator/", .itanium = "dv", .msvc = "?K" } },
    .{ .name = "%", .op = .{ .cpp = "operator%", .itanium = "rm", .msvc = "?L" } },
    .{ .name = "|", .op = .{ .cpp = "operator|", .itanium = "or", .msvc = "?U" } },
    .{ .name = "^", .op = .{ .cpp = "operator^", .itanium = "eo", .msvc = "?T" } },
    .{ .name = "<<", .op = .{ .cpp = "operator<<", .itanium = "ls", .msvc = "?6" } },
    .{ .name = ">>", .op = .{ .cpp = "operator>>", .itanium = "rs", .msvc = "?5" } },
    .{ .name = "~", .op = .{ .cpp = "operator~", .itanium = "co", .msvc = "?S" } },
    .{ .name = "!", .op = .{ .cpp = "operator!", .itanium = "nt", .msvc = "?7" } },
    .{ .name = "=", .op = .{ .cpp = "operator=", .itanium = "aS", .msvc = "?4" } },
    .{ .name = "+=", .op = .{ .cpp = "operator+=", .itanium = "pL", .msvc = "?Y" } },
    .{ .name = "-=", .op = .{ .cpp = "operator-=", .itanium = "mI", .msvc = "?Z" } },
    .{ .name = "*=", .op = .{ .cpp = "operator*=", .itanium = "mL", .msvc = "?X" } },
    .{ .name = "/=", .op = .{ .cpp = "operator/=", .itanium = "dV", .msvc = "?_0" } },
    .{ .name = "%=", .op = .{ .cpp = "operator%=", .itanium = "rM", .msvc = "?_1" } },
    .{ .name = "&=", .op = .{ .cpp = "operator&=", .itanium = "aN", .msvc = "?_4" } },
    .{ .name = "|=", .op = .{ .cpp = "operator|=", .itanium = "oR", .msvc = "?_5" } },
    .{ .name = "^=", .op = .{ .cpp = "operator^=", .itanium = "eO", .msvc = "?_6" } },
    .{ .name = "<<=", .op = .{ .cpp = "operator<<=", .itanium = "lS", .msvc = "?_3" } },
    .{ .name = ">>=", .op = .{ .cpp = "operator>>=", .itanium = "rS", .msvc = "?_2" } },
    .{ .name = "==", .op = .{ .cpp = "operator==", .itanium = "eq", .msvc = "?8" } },
    .{ .name = "!=", .op = .{ .cpp = "operator!=", .itanium = "ne", .msvc = "?9" } },
    .{ .name = "<", .op = .{ .cpp = "operator<", .itanium = "lt", .msvc = "?M" } },
    .{ .name = ">", .op = .{ .cpp = "operator>", .itanium = "gt", .msvc = "?O" } },
    .{ .name = "<=", .op = .{ .cpp = "operator<=", .itanium = "le", .msvc = "?N" } },
    .{ .name = ">=", .op = .{ .cpp = "operator>=", .itanium = "ge", .msvc = "?P" } },
    .{ .name = "&&", .op = .{ .cpp = "operator&&", .itanium = "aa", .msvc = "?V" } },
    .{ .name = "||", .op = .{ .cpp = "operator||", .itanium = "oo", .msvc = "?W" } },
    .{ .name = ",", .op = .{ .cpp = "operator,", .itanium = "cm", .msvc = "?Q" } },
    // `++`/`--` take an unused `int` in their postfix form, which is how both
    // manglings tell the two apart; the code is the same.
    .{ .name = "++", .op = .{ .cpp = "operator++", .itanium = "pp", .msvc = "?E" } },
    .{ .name = "--", .op = .{ .cpp = "operator--", .itanium = "mm", .msvc = "?F" } },
    .{ .name = "[]", .op = .{ .cpp = "operator[]", .itanium = "ix", .msvc = "?A" } },
    .{ .name = "()", .op = .{ .cpp = "operator()", .itanium = "cl", .msvc = "?R" } },
    .{ .name = "->", .op = .{ .cpp = "operator->", .itanium = "pt", .msvc = "?C" } },
    .{ .name = "->*", .op = .{ .cpp = "operator->*", .itanium = "pm", .msvc = "?J" } },
    .{ .name = "new", .op = .{ .cpp = "operator new", .itanium = "nw", .msvc = "?2" } },
    .{ .name = "delete", .op = .{ .cpp = "operator delete", .itanium = "dl", .msvc = "?3" } },
    .{ .name = "new[]", .op = .{ .cpp = "operator new[]", .itanium = "na", .msvc = "?_U" } },
    .{ .name = "delete[]", .op = .{ .cpp = "operator delete[]", .itanium = "da", .msvc = "?_V" } },
    // A conversion operator's target is its return type: `":cast"` with
    // `.ret = c_int` is `operator int`.
    .{ .name = "cast", .op = .{ .cpp = "operator", .itanium = "cv", .msvc = "?B", .conversion = true } },
};

/// The operator a `":..."` name refers to, or null.
pub fn findOperator(comptime spelling: []const u8) ?Op {
    inline for (operators) |e| if (std.mem.eql(u8, e.name, spelling)) return e.op;
    return null;
}

/// Every spelling, for an error message.
pub fn operatorList() []const u8 {
    comptime var out: []const u8 = "";
    inline for (operators, 0..) |e, i| out = out ++ (if (i == 0) "" else " ") ++ ":" ++ e.name;
    return out;
}

/// A function to mangle. `params` excludes `this`; the last path component
/// is the function name (ignored for ctors/dtors, see `special`).
pub const Function = struct {
    path: []const Component,
    params: []const CType,
    ret: CType,
    this: ?This = null,
    is_static: bool = false,
    special: Special = .none,
    /// Set when the last path component names an operator. The component
    /// itself carries the C++ spelling, so only the manglers need this.
    op: ?Op = null,
    is_virtual: bool = false,
    virtual_bases: bool = false,

    pub const This = struct { is_const: bool };
    pub const Special = enum { none, ctor, dtor };
};

pub fn decimal(comptime n: usize) []const u8 {
    if (n < 10) return &[_]u8{'0' + n};
    return decimal(n / 10) ++ &[_]u8{'0' + n % 10};
}

pub fn signedDecimal(comptime n: i64) []const u8 {
    return if (n < 0) "-" ++ decimal(@intCast(-n)) else decimal(@intCast(n));
}

pub fn pathKey(comptime path: []const Component) []const u8 {
    comptime var out: []const u8 = "";
    inline for (path, 0..) |c, i| out = out ++ (if (i == 0) "" else "::") ++ c.key();
    return out;
}

pub fn splitPath(comptime name: []const u8) []const Component {
    if (name.len == 0) @compileError("empty C++ name");
    comptime var parts: []const Component = &.{};
    comptime var start: usize = 0;
    comptime var i: usize = 0;
    inline while (i + 1 < name.len) : (i += 1) {
        if (name[i] == ':' and name[i + 1] == ':') {
            parts = parts ++ &[_]Component{.{ .name = name[start..i] }};
            i += 1;
            start = i + 1;
        }
    }
    parts = parts ++ &[_]Component{.{ .name = name[start..] }};
    inline for (parts) |p| if (p.name.len == 0) @compileError("empty component in C++ name \"" ++ name ++ "\"");
    return parts;
}

/// Maps a Zig type to its C++ counterpart.
///
/// Integers: `c_*` types map to the C++ type of the same name; fixed-width
/// integers to the type of that width (`i32` -> `int`, `i64` -> `long long`,
/// `i8` -> `signed char`); `usize`/`isize` to `size_t`/`ptrdiff_t`. `u8` is
/// `char` (as in translate-c), so `[*:0]const u8` is `const char*`; use
/// `uchar` for `unsigned char`. Pass `c_long` when C++ says `long`: it
/// mangles differently from `long long` even at the same width.
///
/// Pointers: `*T`, `[*]T`, `[*c]T`, `[*:0]T` and their optionals are `T*`,
/// `*anyopaque` is `void*`, and `*const [*c]T` is `T* const`.
///
/// References: `Ref(*const T)` is `const T&`, `RRef(*T)` is `T&&`.
///
/// Named types (struct, opaque, enum, union) read `cpp_name` (`"ns::Name"`)
/// or `cpp_template` (a `Template`), else the last component of `@typeName`;
/// `cpp_kind` (else the Template's kind, else struct/enum/union by Zig kind);
/// and `cpp_abi` (see `ClassAbi`).
pub fn fromZig(comptime T: type) CType {
    return switch (T) {
        void, anyopaque => .{ .builtin = .void },
        bool => .{ .builtin = .bool },
        c_char, u8 => .{ .builtin = .char },
        i8 => .{ .builtin = .schar },
        uchar => .{ .builtin = .uchar },
        c_short, i16 => .{ .builtin = .short },
        c_ushort, u16 => .{ .builtin = .ushort },
        c_int, i32 => .{ .builtin = .int },
        c_uint, u32 => .{ .builtin = .uint },
        c_long => .{ .builtin = .long },
        c_ulong => .{ .builtin = .ulong },
        c_longlong, i64 => .{ .builtin = .longlong },
        c_ulonglong, u64 => .{ .builtin = .ulonglong },
        usize => .{ .builtin = if (@sizeOf(c_ulong) == @sizeOf(usize)) .ulong else .ulonglong },
        isize => .{ .builtin = if (@sizeOf(c_long) == @sizeOf(isize)) .long else .longlong },
        f32 => .{ .builtin = .float },
        f64 => .{ .builtin = .double },
        c_longdouble => .{ .builtin = .longdouble },
        wchar_t => .{ .builtin = .wchar_t },
        char16_t => .{ .builtin = .char16_t },
        char32_t => .{ .builtin = .char32_t },
        else => if (comptime isTParam(T))
            .{ .template_param = T.cpp_template_param }
        else if (comptime isConstPtrMarker(T)) blk: {
            const inner = fromZig(T.cpp_const_ptr);
            if (inner != .pointer) @compileError("ConstPtr takes a pointer type, got " ++ @typeName(T.cpp_const_ptr));
            break :blk .{ .pointer = .{ .child = inner.pointer.child, .is_const = inner.pointer.is_const, .top_const = true } };
        } else if (comptime isRefMarker(T)) blk: {
            const info = @typeInfo(T.cpp_ref);
            if (info != .pointer or info.pointer.size != .one) @compileError("Ref/RRef take a single-item pointer, got " ++ @typeName(T.cpp_ref));
            if (comptime isRefMarker(info.pointer.child)) @compileError("a reference to a reference is not a C++ type (" ++ @typeName(T.cpp_ref) ++ ")");
            if (comptime isConstPtrMarker(info.pointer.child)) @compileError("a reference to a const pointer is `T* const&`, which is Ref(*const [*c]T) (" ++ @typeName(T.cpp_ref) ++ ")");
            const child = fromZig(info.pointer.child);
            break :blk .{ .reference = .{ .child = &child, .is_const = info.pointer.attrs.@"const", .rvalue = T.cpp_rvalue } };
        } else switch (@typeInfo(T)) {
            .pointer => |p| blk: {
                if (p.size == .slice) @compileError("slices have no C++ equivalent; use a pointer (" ++ @typeName(T) ++ ")");
                if (@typeInfo(p.child) == .@"fn") @compileError("function pointers are not supported yet (" ++ @typeName(T) ++ ")");
                if (comptime isRefMarker(p.child)) @compileError("a pointer to a reference is not a C++ type (" ++ @typeName(T) ++ ")");
                if (comptime isConstPtrMarker(p.child)) @compileError("a const pointer inside a pointer is the outer pointer's pointee constness; write *const " ++ @typeName(p.child.cpp_const_ptr) ++ " (" ++ @typeName(T) ++ ")");
                const child = fromZig(p.child);
                break :blk .{ .pointer = .{ .child = &child, .is_const = p.attrs.@"const" } };
            },
            .optional => |o| blk: {
                if (@typeInfo(o.child) != .pointer) @compileError("only optional pointers map to C++ (" ++ @typeName(T) ++ ")");
                break :blk fromZig(o.child);
            },
            .@"struct", .@"opaque", .@"enum", .@"union" => .{ .named = namedOf(T) },
            else => @compileError("no C++ equivalent for Zig type " ++ @typeName(T)),
        },
    };
}

fn namedOf(comptime T: type) CType.Named {
    const default_kind: Kind = switch (@typeInfo(T)) {
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        else => .@"struct",
    };
    // A C++ class has the field order its declaration gives it. Zig reorders
    // the fields of a non-extern struct, so a type that stands for a C++ class
    // must say `extern`, and its author must know the compiled layout.
    switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.layout != .@"extern") @compileError(@typeName(T) ++ ": a Zig type that stands for a C++ class must be an extern struct, an extern union, an enum, or opaque"),
        .@"union" => |u| if (u.layout != .@"extern") @compileError(@typeName(T) ++ ": a Zig type that stands for a C++ union must be an extern union"),
        else => {},
    }
    const abi: ClassAbi = if (@hasDecl(T, "cpp_abi")) T.cpp_abi else .c_struct;
    if (@hasDecl(T, "cpp_name") and @hasDecl(T, "cpp_template")) @compileError(@typeName(T) ++ ": declare either cpp_name or cpp_template, not both");
    if (@hasDecl(T, "cpp_template")) {
        const t: Template = T.cpp_template;
        return .{
            .path = templatePath(t),
            .kind = if (@hasDecl(T, "cpp_kind")) T.cpp_kind else t.kind,
            .abi = abi,
        };
    }
    const path = if (@hasDecl(T, "cpp_name")) blk: {
        if (@TypeOf(T.cpp_name) == Template) @compileError(@typeName(T) ++ ": a Template goes in cpp_template, not cpp_name");
        break :blk splitPath(T.cpp_name);
    } else &[_]Component{.{ .name = lastComponent(@typeName(T)) }};
    return .{
        .path = path,
        .kind = if (@hasDecl(T, "cpp_kind")) T.cpp_kind else default_kind,
        .abi = abi,
    };
}

/// A `Template` as a type, for nested template arguments.
pub fn fromTemplate(comptime t: Template) CType {
    return .{ .named = .{ .path = templatePath(t), .kind = t.kind } };
}

fn templatePath(comptime t: Template) []const Component {
    const plain = splitPath(t.name);
    const args = convertArgs(t.name, t.args);
    return plain[0 .. plain.len - 1] ++ &[_]Component{.{ .name = plain[plain.len - 1].name, .args = args }};
}

/// Replaces every `template_param` with the matching entry of `args`. The
/// Itanium mangler is the only consumer that wants the parameters left in,
/// so everything else runs a type through this first.
pub fn substitute(comptime t: CType, comptime args: []const Arg) CType {
    return switch (t) {
        .builtin => t,
        .template_param => |i| blk: {
            if (i >= args.len) @compileError("TParam(" ++ decimal(i) ++ ") but the signature has " ++ decimal(args.len) ++ " template arguments");
            if (args[i] != .type) @compileError("TParam(" ++ decimal(i) ++ ") names a non-type template argument, which is not a type");
            break :blk args[i].type;
        },
        .pointer => |p| blk: {
            const child = substitute(p.child.*, args);
            break :blk .{ .pointer = .{ .child = &child, .is_const = p.is_const, .top_const = p.top_const } };
        },
        .reference => |r| blk: {
            const child = substitute(r.child.*, args);
            break :blk .{ .reference = .{ .child = &child, .is_const = r.is_const, .rvalue = r.rvalue } };
        },
        .named => |n| .{ .named = .{ .path = substitutePath(n.path, args), .kind = n.kind, .abi = n.abi } },
    };
}

fn substitutePath(comptime path: []const Component, comptime args: []const Arg) []const Component {
    comptime var out: []const Component = &.{};
    inline for (path) |c| {
        comptime var cargs: []const Arg = &.{};
        inline for (c.args) |a| cargs = cargs ++ &[_]Arg{switch (a) {
            .type => |t| .{ .type = substitute(t, args) },
            .integral => a,
        }};
        out = out ++ &[_]Component{.{ .name = c.name, .args = cargs }};
    }
    return out;
}

/// `TemplateArg` values as `Arg` values, for a function template's arguments.
pub fn convertArgs(comptime tname: []const u8, comptime args: []const TemplateArg) []const Arg {
    comptime var out: []const Arg = &.{};
    inline for (args) |a| out = out ++ &[_]Arg{convertArg(tname, a)};
    return out;
}

fn convertArg(comptime tname: []const u8, comptime a: TemplateArg) Arg {
    switch (a) {
        .type => |T| return .{ .type = fromZig(T) },
        .template => |t| return .{ .type = fromTemplate(t) },
        .int => |v| return .{ .integral = .{ .type = .{ .builtin = .int }, .value = v } },
        .value => |v| {
            const t = fromZig(v.type);
            const ok = switch (t) {
                .builtin => |b| b.isIntegral(),
                .named => |n| n.kind == .@"enum",
                else => false,
            };
            if (!ok) @compileError(tname ++ ": a non-type template argument must be an integer, bool, or enum type, got " ++ @typeName(v.type));
            return .{ .integral = .{ .type = t, .value = v.int } };
        },
    }
}

fn lastComponent(comptime name: []const u8) []const u8 {
    comptime var i = name.len;
    inline while (i > 0) : (i -= 1) {
        if (name[i - 1] == '.') return name[i..];
    }
    return name;
}

test "splitPath" {
    const parts = comptime splitPath("ns::inner::f");
    try std.testing.expectEqual(3, parts.len);
    try std.testing.expectEqualStrings("ns", parts[0].name);
    try std.testing.expectEqualStrings("inner", parts[1].name);
    try std.testing.expectEqualStrings("f", parts[2].name);
    try std.testing.expectEqual(1, comptime splitPath("f").len);
}

test "fromZig keys" {
    try std.testing.expectEqualStrings("int", comptime fromZig(c_int).key());
    try std.testing.expectEqualStrings("char const*", comptime fromZig([*:0]const u8).key());
    try std.testing.expectEqualStrings("char const*", comptime fromZig(?[*]const c_char).key());
    try std.testing.expectEqualStrings("uchar*", comptime fromZig([*]uchar).key());
    try std.testing.expectEqualStrings("schar*", comptime fromZig([*]i8).key());
    try std.testing.expectEqualStrings("void*", comptime fromZig(*anyopaque).key());
    const S = opaque {
        pub const cpp_name = "a::b::S";
    };
    try std.testing.expectEqualStrings("a::b::S*", comptime fromZig(*S).key());
    const P = extern struct { x: c_int };
    try std.testing.expectEqualStrings("P const*", comptime fromZig(*const P).key());
    try std.testing.expectEqualStrings("P const&", comptime fromZig(Ref(*const P)).key());
    try std.testing.expectEqualStrings("P&&", comptime fromZig(RRef(*P)).key());
    try std.testing.expectEqualStrings("int* const&", comptime fromZig(Ref(*const [*c]c_int)).key());
}

test "template keys" {
    const Q = enum(c_int) {
        lowp,
        highp,
        _,
        pub const cpp_name = "tpl::qualifier";
    };
    const V = extern struct {
        v: [3]f32,
        pub const cpp_template = Template{ .name = "tpl::vec", .args = &.{ .{ .int = 3 }, .{ .type = f32 }, .{ .value = .{ .type = Q, .int = 1 } } } };
    };
    try std.testing.expectEqualStrings("tpl::vec<int=3,float,tpl::qualifier=1>", comptime fromZig(V).key());
    const L = extern struct {
        n: c_int,
        pub const cpp_template = Template{ .name = "tpl::List", .args = &.{ .{ .type = V }, .{ .template = .{ .name = "tpl::Alloc", .args = &.{.{ .type = V }} } } }, .kind = .class };
    };
    const l = comptime fromZig(L);
    try std.testing.expectEqualStrings("tpl::List<tpl::vec<int=3,float,tpl::qualifier=1>,tpl::Alloc<tpl::vec<int=3,float,tpl::qualifier=1>>>", comptime l.key());
    try std.testing.expectEqual(Kind.class, l.named.kind);
    try std.testing.expectEqual(Kind.@"struct", l.named.path[1].args[1].type.named.kind);
}

test "resolve strips reference markers" {
    try std.testing.expectEqual(*const c_int, resolve(Ref(*const c_int)));
    try std.testing.expectEqual(*c_int, resolve(RRef(*c_int)));
    try std.testing.expectEqual(c_int, resolve(c_int));
    try std.testing.expectEqual(Ref(*c_int), Ref(*c_int));
}
