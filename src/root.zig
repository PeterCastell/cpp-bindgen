//! cpp-bindgen: call C++ functions from Zig without a C shim.
//!
//! `bind*` compute the mangled symbol name at compile time and return a
//! pointer to the external function with the C calling convention, which is
//! what C++ uses for everything except classes passed by value. Those follow
//! ABI-specific rules; the class declares its category (`ClassAbi`) and the
//! binder inserts a wrapper where the call shape differs from C.
const std = @import("std");
const builtin = @import("builtin");

pub const ctype = @import("ctype.zig");
const cppsrc = @import("cppsrc.zig");
pub const emit = @import("emit.zig");
const itanium = @import("itanium.zig");
const msvc = @import("msvc.zig");

pub const Kind = ctype.Kind;
pub const wchar_t = ctype.wchar_t;
pub const char16_t = ctype.char16_t;
pub const char32_t = ctype.char32_t;
pub const uchar = ctype.uchar;
pub const Ref = ctype.Ref;
pub const RRef = ctype.RRef;
pub const ConstPtr = ctype.ConstPtr;
pub const TParam = ctype.TParam;
pub const Op = ctype.Op;
pub const Template = ctype.Template;
pub const TemplateArg = ctype.TemplateArg;
pub const ClassAbi = ctype.ClassAbi;

pub const Mangling = enum { itanium, msvc };

/// The mangling the target's C++ compiler uses: MSVC for the `msvc` ABI,
/// Itanium everywhere else (including `*-windows-gnu`).
pub const default_mangling: Mangling = if (builtin.target.abi == .msvc) .msvc else .itanium;

/// A C++ function signature expressed in Zig types.
pub const Signature = struct {
    /// Either a fully qualified C++ name such as `"ns::Counter::get"`, or a
    /// bare member name such as `"get"` when the class is given by `class`
    /// or by the pointee of `this`. Only the bare form can name a member of
    /// a class-template specialization, since the class's `cpp_name` is
    /// what carries the template arguments.
    name: []const u8,
    /// The class a bare `name` belongs to. With `this` unset, the function
    /// is a static member function, which MSVC mangles differently from a
    /// free function in the same scope.
    class: ?type = null,
    /// Parameter types, excluding `this`. A C++ reference parameter is
    /// written as `Ref(*T)` / `Ref(*const T)` / `RRef(*T)`, and a `T* const`
    /// parameter as `ConstPtr([*c]T)`; the bound function then takes the
    /// plain pointer.
    args: []const type = &.{},
    /// Return type. May also be a `Ref`/`RRef` marker.
    ret: type = void,
    /// For non-static member functions: `*T` or `*const T`. The constness is
    /// the constness of the method.
    this: ?type = null,
    /// Template arguments, for a specialization of a function template.
    /// Wherever the template's *declaration* wrote one of its own parameters,
    /// write `TParam(n)`: `void f<std::string>(const T&, float)` is
    /// `.template_args = &.{.{ .type = Str }}` with
    /// `.args = &.{ Ref(*const TParam(0)), f32 }`. Itanium needs the
    /// declared form, MSVC the substituted one, and this gives both.
    template_args: []const TemplateArg = &.{},
    /// The method is declared `virtual`. Only MSVC mangles the difference;
    /// the call is still a direct call to that class's implementation.
    /// Destructors take this from the class's `cpp_virtual_dtor` instead.
    virtual: bool = false,
};

// Declarations a Zig type may carry to describe its C++ class, read by
// `ctype.fromZig` and by constructor/destructor binding:
//
// - `cpp_name`: the qualified C++ name, or `cpp_template` for a class-template
//   specialization (see `ctype.fromZig`).
// - `cpp_kind: Kind`: struct/class/union/enum, for MSVC.
// - `cpp_abi: ClassAbi`: how the class travels by value (see `ClassAbi`).
// - `cpp_virtual_dtor: bool`: the destructor is virtual (MSVC `U`).
// - `cpp_virtual_bases: bool`: the class has virtual bases. Selects MSVC's
//   `??_D` complete destructor and makes constructors pass the hidden
//   "most derived" flag.
//
// A constructor is bound as a method named `"*"` (or `"ns::Class::*"`) with
// a `*T` self and `void` return; a destructor as `"~"`, with no arguments.
// Both run on caller-provided storage, so the Zig type must have the C++
// object's size and alignment.

/// The type of a bound signature that needs a wrapper. Past ten parameters
/// the whole list collapses into one tuple, since that is the only shape a
/// single declaration can give every arity. A wrapper is a Zig function, so
/// it takes Zig's calling convention rather than the C one.
fn TrampolineFnType(comptime sig: Signature) type {
    const r = comptime substituted(sig);
    const params = visibleParams(r);
    return @Fn(if (params.len <= 10) params else &[_]type{@Tuple(params)}, &@splat(.{}), visibleRet(r), .{});
}

fn IdentityFnType(comptime sig: Signature) type {
    const r = comptime substituted(sig);
    return @Fn(visibleParams(r), &@splat(.{}), visibleRet(r), .{ .@"callconv" = .c });
}

/// The signature with every `TParam` replaced by the template argument it
/// names. Only the mangled name is built from the declared form; everything
/// that decides how the call is shaped works from this.
fn substituted(comptime sig: Signature) Signature {
    if (sig.template_args.len == 0) return sig;
    comptime var out = sig;
    comptime var args: []const type = &.{};
    inline for (sig.args) |A| args = args ++ &[_]type{substType(sig, A)};
    out.args = args;
    out.ret = substType(sig, sig.ret);
    return out;
}

fn substType(comptime sig: Signature, comptime T: type) type {
    if (comptime ctype.isTParam(T)) return argType(sig, T);
    if (comptime ctype.isRefMarker(T)) {
        const P = substPointer(sig, T.cpp_ref);
        return if (T.cpp_rvalue) ctype.RRef(P) else ctype.Ref(P);
    }
    if (comptime ctype.isConstPtrMarker(T)) return ctype.ConstPtr(substPointer(sig, T.cpp_const_ptr));
    return substPointer(sig, T);
}

/// Only a single-item pointer is rebuilt: that is what a reference to a
/// template parameter resolves to, and what a `T*` parameter is.
fn substPointer(comptime sig: Signature, comptime P: type) type {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one) return P;
    if (!comptime ctype.isTParam(info.pointer.child)) return P;
    const Sub = argType(sig, info.pointer.child);
    return if (info.pointer.attrs.@"const") *const Sub else *Sub;
}

fn argType(comptime sig: Signature, comptime T: type) type {
    const i = T.cpp_template_param;
    if (i >= sig.template_args.len) @compileError(sig.name ++ ": TParam(" ++ ctype.decimal(i) ++ ") but only " ++ ctype.decimal(sig.template_args.len) ++ " template arguments were given");
    const a = sig.template_args[i];
    if (a != .type) @compileError(sig.name ++ ": TParam(" ++ ctype.decimal(i) ++ ") names a non-type template argument, which cannot be a parameter type");
    return a.type;
}

// Helpers below force comptime evaluation so runtime callers (the trampoline)
// do not turn their branches into runtime conditions.

fn visibleParams(comptime sig: Signature) []const type {
    return comptime blk: {
        var params: []const type = &.{};
        if (classAbi(sig.ret) == .managed_copy) params = params ++ &[_]type{*sig.ret};
        if (sig.this) |t| params = params ++ &[_]type{t};
        for (sig.args) |A| params = params ++ &[_]type{if (classAbi(A) == .managed_copy) *A else ctype.resolve(A)};
        break :blk params;
    };
}

fn visibleRet(comptime sig: Signature) type {
    return comptime if (classAbi(sig.ret) == .managed_copy) void else ctype.resolve(sig.ret);
}

/// Null unless `T` is a class type passed by value. `ctype.fromZig` has
/// already rejected any non-extern struct or union.
fn classAbi(comptime T: type) ?ClassAbi {
    return comptime blk: {
        const t = ctype.fromZig(T);
        if (t != .named) break :blk null;
        if (t.named.abi != .managed_copy and @typeInfo(T) == .@"opaque")
            @compileError(@typeName(T) ++ ": an opaque type has no size, so it cannot be passed by value; declare cpp_abi = .managed_copy, which passes a pointer");
        break :blk t.named.abi;
    };
}

/// A class type, as opposed to an enum, which `classAbi` also accepts.
fn isClass(comptime T: type) bool {
    const t = comptime ctype.fromZig(T);
    return t == .named and t.named.kind != .@"enum";
}

/// Binds a C++ function or method by its signature, using the target's
/// mangling.
pub fn bind(comptime sig: Signature) *const FnType(default_mangling, sig) {
    return bindWithMangling(default_mangling, sig);
}

/// The function pointer type of a bound signature, as Zig sees it: an
/// out-pointer first when a `.managed_copy` class is returned by value,
/// then `this` (if any), then `args`. Reference markers become the pointers
/// they wrap; `.managed_copy` arguments become `*T`. See `ClassAbi`.
///
/// A signature whose call shape already matches the C++ symbol gets that
/// symbol's own `callconv(.c)` type; one that needs a wrapper gets the
/// wrapper's. Which of the two applies depends on the mangling.
pub fn FnType(comptime mangling: Mangling, comptime sig: Signature) type {
    const r = comptime substituted(sig);
    const f = comptime describe(sig);
    const plan = comptime planFor(mangling, r, f);
    if (comptime plan.isIdentity(r)) {
        return IdentityFnType(sig);
    }
    return TrampolineFnType(sig);
}

/// Like `bind`, with an explicit mangling. Useful for a `windows-gnu` build
/// that links a library produced by Visual C++.
pub fn bindWithMangling(comptime mangling: Mangling, comptime sig: Signature) *const FnType(mangling, sig) {
    const r = comptime substituted(sig);
    const f = comptime describe(sig);
    const plan = comptime planFor(mangling, r, f);
    const name = comptime mangledName(mangling, sig);
    if (comptime plan.isIdentity(r)) {
        return @extern(*const IdentityFnType(sig), .{ .name = name });
    }
    const ext = @extern(*const @Fn(plan.ext_params, &@splat(.{}), plan.ext_ret, .{ .@"callconv" = .c }), .{ .name = name });
    return &trampoline(mangling, r, plan, ext);
}

/// Where a parameter of the real extern function comes from.
const Source = union(enum) {
    visible: usize,
    /// Address of a local the callee returns into (MSVC trivial_copy returns).
    tmp_ret,
    /// MSVC "most derived" flag for constructors with virtual bases.
    hidden_int: c_int,
};

/// Maps the Zig-visible call onto the real C++ call for one ABI.
const Plan = struct {
    ext_params: []const type,
    ext_ret: type,
    sources: []const Source,
    /// Visible indices of managed_copy arguments the caller destroys after the call.
    destroy: []const usize,
    ret_from_tmp: bool,

    fn isIdentity(comptime p: Plan, comptime sig: Signature) bool {
        if (p.ret_from_tmp or p.destroy.len > 0 or p.ext_ret != visibleRet(sig)) return false;
        if (p.sources.len != visibleParams(sig).len) return false;
        inline for (p.sources, 0..) |src, i| if (src != .visible or src.visible != i) return false;
        return true;
    }
};

fn planFor(comptime mangling: Mangling, comptime sig: Signature, comptime f: ctype.Function) Plan {
    const managed_ret = classAbi(sig.ret) == .managed_copy;
    // MSVC returns a class through a hidden pointer from any instance member
    // function, whatever its size and however trivial it is; a free or static
    // function returning the same class uses a register. `.trivial_copy` is
    // indirect either way.
    const msvc_hidden = mangling == .msvc and
        (classAbi(sig.ret) == .trivial_copy or (sig.this != null and isClass(sig.ret)));
    const hidden_ret = managed_ret or msvc_hidden;
    if (hidden_ret and builtin.cpu.arch.isAARCH64())
        @compileError(sig.name ++ ": returning a class through a hidden pointer is not supported on AArch64 yet (the pointer goes in x8)");

    const RetPtr = *ctype.resolve(sig.ret);
    const ret_src: Source = if (managed_ret) .{ .visible = 0 } else .tmp_ret;
    const this_idx: usize = if (managed_ret) 1 else 0;
    const args_base = this_idx + @as(usize, if (sig.this != null) 1 else 0);

    comptime var ext_params: []const type = &.{};
    comptime var sources: []const Source = &.{};
    comptime var destroy: []const usize = &.{};

    // Hidden return pointer: before `this` on Itanium, after it on MSVC.
    if (hidden_ret and mangling == .itanium) {
        ext_params = ext_params ++ &[_]type{RetPtr};
        sources = sources ++ &[_]Source{ret_src};
    }
    if (sig.this) |T| {
        ext_params = ext_params ++ &[_]type{T};
        sources = sources ++ &[_]Source{.{ .visible = this_idx }};
    }
    if (hidden_ret and mangling == .msvc) {
        ext_params = ext_params ++ &[_]type{RetPtr};
        sources = sources ++ &[_]Source{ret_src};
    }
    inline for (sig.args, 0..) |A, i| {
        const vis = args_base + i;
        if (classAbi(A) == .managed_copy) {
            ext_params = ext_params ++ &[_]type{*A};
            if (mangling == .itanium) destroy = destroy ++ &[_]usize{vis};
        } else {
            ext_params = ext_params ++ &[_]type{ctype.resolve(A)};
        }
        sources = sources ++ &[_]Source{.{ .visible = vis }};
    }
    if (mangling == .msvc and f.special == .ctor and f.virtual_bases) {
        ext_params = ext_params ++ &[_]type{c_int};
        sources = sources ++ &[_]Source{.{ .hidden_int = 1 }};
    }
    return .{
        .ext_params = ext_params,
        .ext_ret = if (hidden_ret) void else visibleRet(sig),
        .sources = sources,
        .destroy = destroy,
        .ret_from_tmp = hidden_ret and !managed_ret,
    };
}

/// A function with the visible signature that performs the real call per
/// `plan`. A function body cannot take a generated parameter list, so there
/// is one entry point per arity and a last one, `fN`, that takes the whole
/// argument list as a tuple for the arities no named entry point covers.
fn trampoline(comptime mangling: Mangling, comptime sig: Signature, comptime plan: Plan, comptime extern_func: anytype) TrampolineFnType(sig) {
    const V = comptime visibleParams(sig);
    const R = comptime visibleRet(sig);
    const T = struct {
        inline fn invoke(args: @Tuple(V)) R {
            var tmp: (if (plan.ret_from_tmp) R else void) = undefined;
            var ext_args: @Tuple(plan.ext_params) = undefined;
            inline for (plan.sources, 0..) |src, i| {
                ext_args[i] = switch (src) {
                    .visible => |v| args[v],
                    .tmp_ret => &tmp,
                    .hidden_int => |c| c,
                };
            }
            const r = @call(.auto, extern_func, ext_args);
            inline for (plan.destroy) |v| {
                const dtor = comptime bindWithMangling(mangling, .{ .name = "~", .this = V[v] });
                dtor(args[v]);
            }
            return if (plan.ret_from_tmp) tmp else r;
        }
        fn f0() R {
            return invoke(.{});
        }
        fn f1(a: V[0]) R {
            return invoke(.{a});
        }
        fn f2(a: V[0], b: V[1]) R {
            return invoke(.{ a, b });
        }
        fn f3(a: V[0], b: V[1], c: V[2]) R {
            return invoke(.{ a, b, c });
        }
        fn f4(a: V[0], b: V[1], c: V[2], d: V[3]) R {
            return invoke(.{ a, b, c, d });
        }
        fn f5(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4]) R {
            return invoke(.{ a, b, c, d, e });
        }
        fn f6(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5]) R {
            return invoke(.{ a, b, c, d, e, g });
        }
        fn f7(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6]) R {
            return invoke(.{ a, b, c, d, e, g, h });
        }
        fn f8(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6], i: V[7]) R {
            return invoke(.{ a, b, c, d, e, g, h, i });
        }
        fn f9(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6], i: V[7], j: V[8]) R {
            return invoke(.{ a, b, c, d, e, g, h, i, j });
        }
        fn f10(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6], i: V[7], j: V[8], k: V[9]) R {
            return invoke(.{ a, b, c, d, e, g, h, i, j, k });
        }
        fn fN(args: @Tuple(V)) R {
            return invoke(args);
        }
    };
    return switch (comptime V.len) {
        0 => T.f0,
        1 => T.f1,
        2 => T.f2,
        3 => T.f3,
        4 => T.f4,
        5 => T.f5,
        6 => T.f6,
        7 => T.f7,
        8 => T.f8,
        9 => T.f9,
        10 => T.f10,
        else => T.fN,
    };
}

/// Binds a free function: `int ns::add(int, int)` is
/// `bindFn(&.{ c_int, c_int }, c_int, "ns::add")`.
pub fn bindFn(comptime Args: []const type, comptime Ret: type, comptime name: []const u8) *const FnType(default_mangling, .{ .name = name, .args = Args, .ret = Ret }) {
    return bind(.{ .name = name, .args = Args, .ret = Ret });
}

/// Binds a non-static member function. `Self` is `*T` for a non-const method
/// and `*const T` for a const one, and becomes the first parameter:
/// `int ns::Counter::get() const` is
/// `bindMethod(*const Counter, &.{}, c_int, "get")`, with the class taken
/// from `Counter`'s `cpp_name`. A qualified name such as `"ns::Base::get"`
/// overrides the class, which is how a base-class method is called through
/// a derived pointer.
pub fn bindMethod(comptime Self: type, comptime Args: []const type, comptime Ret: type, comptime name: []const u8) *const FnType(default_mangling, .{ .name = name, .args = Args, .ret = Ret, .this = Self }) {
    return bind(.{ .name = name, .args = Args, .ret = Ret, .this = Self });
}

/// Binds a static member function of `Class`, which takes no `this`:
/// `static int ns::Counter::instances()` is
/// `bindStatic(Counter, &.{}, c_int, "instances")`.
pub fn bindStatic(comptime Class: type, comptime Args: []const type, comptime Ret: type, comptime name: []const u8) *const FnType(default_mangling, .{ .name = name, .args = Args, .ret = Ret, .class = Class }) {
    return bind(.{ .name = name, .args = Args, .ret = Ret, .class = Class });
}

/// The mangled symbol name for a signature.
pub fn mangledName(comptime mangling: Mangling, comptime sig: Signature) []const u8 {
    @setEvalBranchQuota(1 << 20);
    const f = comptime describe(sig);
    return switch (mangling) {
        .itanium => itanium.mangle(f),
        .msvc => msvc.mangle(f),
    };
}

/// The C++-level description of a signature, as the manglers and the glue
/// emitter see it.
pub fn describe(comptime sig: Signature) ctype.Function {
    comptime var params: []const ctype.CType = &.{};
    inline for (sig.args) |A| params = params ++ &[_]ctype.CType{ctype.fromZig(A)};

    const ret = ctype.fromZig(sig.ret);
    const named = operatorOf(sig, templated(sig, pathOf(sig)), ret);
    const path = named.path;
    const last = path[path.len - 1].name;
    const special: ctype.Function.Special = if (std.mem.eql(u8, last, "*")) .ctor else if (std.mem.eql(u8, last, "~")) .dtor else .none;

    comptime var f = ctype.Function{
        .path = path,
        .params = params,
        .ret = ret,
        .this = if (sig.this) |Self| thisOf(sig.name, Self) else null,
        .is_static = sig.this == null and sig.class != null,
        .special = special,
        .op = named.op,
        .is_virtual = sig.virtual,
    };
    if (sig.this) |Self| {
        const Class = thisPointee(sig.name, Self);
        f.virtual_bases = @hasDecl(Class, "cpp_virtual_bases") and Class.cpp_virtual_bases;
        if (special == .dtor and @hasDecl(Class, "cpp_virtual_dtor") and Class.cpp_virtual_dtor) f.is_virtual = true;
    }
    if (special != .none) {
        const what = if (special == .ctor) "constructor" else "destructor";
        if (sig.this == null) @compileError(sig.name ++ ": a " ++ what ++ " needs a `*T` self; use bindMethod");
        if (f.this.?.is_const) @compileError(sig.name ++ ": a " ++ what ++ " takes a non-const `*T` self");
        if (sig.ret != void) @compileError(sig.name ++ ": a " ++ what ++ " returns void");
        if (special == .dtor and sig.args.len != 0) @compileError(sig.name ++ ": a destructor takes no arguments");
    }
    return f;
}

/// Recognises a `":..."` name. The component keeps the C++ spelling, which
/// is what the glue writes; the `Op` goes on the function for the manglers.
fn operatorOf(comptime sig: Signature, comptime path: []const ctype.Component, comptime ret: ctype.CType) struct { path: []const ctype.Component, op: ?ctype.Op } {
    const last = path[path.len - 1];
    if (last.name.len < 2 or last.name[0] != ':') return .{ .path = path, .op = null };
    const op = ctype.findOperator(last.name[1..]) orelse
        @compileError(sig.name ++ ": '" ++ last.name ++ "' is not an operator; the spellings are " ++ ctype.operatorList());
    if (last.args.len > 0) @compileError(sig.name ++ ": an operator cannot take explicit template arguments");
    // `operator int`, `operator ns::Vec2 const*`: the target is the return type.
    const cpp = if (op.conversion) op.cpp ++ " " ++ cppsrc.typeName(ret) else op.cpp;
    return .{
        .path = path[0 .. path.len - 1] ++ &[_]ctype.Component{.{ .name = cpp }},
        .op = op,
    };
}

/// Attaches `template_args` to the function's own name component, which is
/// where both manglers look for them.
fn templated(comptime sig: Signature, comptime path: []const ctype.Component) []const ctype.Component {
    if (sig.template_args.len == 0) return path;
    const last = path[path.len - 1];
    if (last.args.len > 0) @compileError(sig.name ++ ": the name already carries template arguments");
    return path[0 .. path.len - 1] ++ &[_]ctype.Component{.{ .name = last.name, .args = ctype.convertArgs(sig.name, sig.template_args) }};
}

fn pathOf(comptime sig: Signature) []const ctype.Component {
    if (std.mem.indexOf(u8, sig.name, "::") != null) {
        if (sig.class != null) @compileError(sig.name ++ ": give either a qualified name or a class, not both");
        return ctype.splitPath(sig.name);
    }
    const Class: type = if (sig.class) |C|
        C
    else if (sig.this) |Self|
        thisPointee(sig.name, Self)
    else
        return ctype.splitPath(sig.name);
    const class = ctype.fromZig(Class);
    if (class != .named) @compileError(sig.name ++ ": the class must be a struct, opaque, union, or enum type, got " ++ @typeName(Class));
    return class.named.path ++ &[_]ctype.Component{.{ .name = sig.name }};
}

fn thisPointee(comptime name: []const u8, comptime Self: type) type {
    const info = @typeInfo(Self);
    if (info != .pointer or info.pointer.size != .one) @compileError(name ++ ": `this` must be a single-item pointer, got " ++ @typeName(Self));
    if (ctype.fromZig(info.pointer.child) != .named) @compileError(name ++ ": `this` must point to a struct or opaque type, got " ++ @typeName(Self));
    return info.pointer.child;
}

fn thisOf(comptime name: []const u8, comptime Self: type) ctype.Function.This {
    _ = thisPointee(name, Self);
    return .{ .is_const = @typeInfo(Self).pointer.attrs.@"const" };
}

test {
    _ = ctype;
    _ = emit;
    _ = @import("cppsrc.zig");
    _ = itanium;
    _ = msvc;
    _ = @import("testing.zig");
}
