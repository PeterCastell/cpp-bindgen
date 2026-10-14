//! cpp-bindgen: call C++ functions from Zig without a C shim.
//!
//! `bind*` compute the mangled symbol name at compile time and return a
//! pointer to the external function with the C calling convention, which is
//! what C++ uses for everything except classes passed by value. Those follow
//! ABI-specific rules; the class declares its category (`ClassAbi`) and the
//! binder inserts a wrapper where the call shape differs from C.
//!
//! A class with bases declares them (`cpp_bases`), and where each base sits
//! is computed for the target's ABI (`inherit.zig`). A base's method bound
//! through a derived pointer is checked against that and has `this` moved to
//! the base subobject.
const std = @import("std");
const builtin = @import("builtin");

pub const ctype = @import("ctype.zig");
const cppsrc = @import("cppsrc.zig");
pub const emit = @import("emit.zig");
const inherit = @import("inherit.zig");
const itanium = @import("itanium.zig");
const msvc = @import("msvc.zig");
pub const vtable = @import("vtable.zig");
const subclass = @import("subclass.zig");

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
pub const BaseSpan = inherit.BaseSpan;
pub const baseAlign = inherit.baseAlign;
pub const basePtr = inherit.basePtr;
pub const baseOffset = inherit.baseOffset;
pub const firstNamed = vtable.firstNamed;
pub const verifyVtable = vtable.verify;
pub const Subclass = subclass.Subclass;

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
    /// free function in the same scope. With `this` pointing at a class
    /// derived from it (see `cpp_bases`), it is the base's method called
    /// through the derived pointer, and `this` is moved to the base
    /// subobject before the call.
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
    /// `bind` still makes a direct call to that class's implementation, and
    /// `bindVirtual` makes the virtual call.
    /// Destructors take this from the class's `cpp_virtual_dtor` instead.
    virtual: bool = false,
    /// The method is pure virtual (`= 0`), which implies `virtual`. Its
    /// vtable slot holds the ABI's pure-call handler, a `Subclass` must
    /// override it, and the glue forces no definition for it, since it
    /// usually has none.
    pure: bool = false,
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
// - `cpp_bases: []const type`: the direct bases, in C++ source order. The
//   type then starts with `_bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This()))`,
//   which is every base laid out where the ABI puts it (see `inherit.zig`).
// - `cpp_polymorphic: bool`: the class has virtual functions. Implied by
//   `cpp_virtual_dtor`; needed only for a class whose destructor is not
//   virtual but something else is, since it decides whether a vtable
//   pointer precedes the bases.
// - `cpp_virtuals: []const Signature`: the virtual functions the class
//   declares, in header order, the destructor and overrides included. From
//   these lists `vtable.tables` computes every slot of every vtable (see
//   `vtable.zig`).
// - `cpp_no_rtti: bool`: the class's vtable was compiled without RTTI, so a
//   `Subclass` of it carries none either (see `subclass.zig`).
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
    @setEvalBranchQuota(1 << 20);
    const r = comptime substituted(sig);
    const f = comptime describe(sig);
    const plan = comptime planFor(mangling, r, f);
    if (comptime plan.isIdentity(r)) {
        return IdentityFnType(sig);
    }
    return TrampolineFnType(sig);
}

/// A member function's C call as its *callee* receives it: what a function
/// standing in for the C++ definition, such as a `Subclass` override, has to
/// accept and hand back. It is `bind`'s call seen from the other side.
pub const CalleeShape = struct {
    /// The C parameters, `this` and any hidden return pointer included.
    params: []const type,
    /// What the callee returns. With a hidden return pointer, that pointer:
    /// the callee hands it back on both ABIs.
    ret: type,
    this_index: usize,
    /// Where the hidden return pointer is in `params`, if there is one.
    ret_index: ?usize,
    /// `FnType`'s parameters and return type: what `bind` takes and gives.
    visible_params: []const type,
    visible_ret: type,
    /// Where each of `visible_params` is in `params`.
    from: []const usize,
    /// Which of `visible_params` is `this`.
    this_visible: usize,
    /// Whether the hidden return pointer is one of `visible_params` (a
    /// `.managed_copy` out-pointer) rather than behind `visible_ret`.
    ret_visible: bool,
    /// Indices into `visible_params` of the `.managed_copy` arguments the
    /// callee destroys: every one on MSVC, none on Itanium.
    destroy: []const usize,
};

/// The callee's side of a member function's call. `.class` is ignored: a
/// virtual function's slot receives `this` already moved to its table.
pub fn calleeShape(comptime mangling: Mangling, comptime sig: Signature) CalleeShape {
    comptime {
        @setEvalBranchQuota(1 << 20);
        var u = substituted(sig);
        u.class = null;
        if (u.this == null) @compileError(sig.name ++ ": only a member function has a callee shape");
        const plan = planFor(mangling, u, describe(u));
        const V = visibleParams(u);
        const managed_ret = classAbi(u.ret) == .managed_copy;
        const this_visible: usize = if (managed_ret) 1 else 0;
        var from: []const usize = &.{};
        for (0..V.len) |v| {
            const i = for (plan.sources, 0..) |src, i| {
                if (src == .visible and src.visible == v) break i;
            } else unreachable;
            from = from ++ &[_]usize{i};
        }
        const ret_index: ?usize = if (managed_ret) from[0] else for (plan.sources, 0..) |src, i| {
            if (src == .tmp_ret) break i;
        } else null;
        var destroy: []const usize = &.{};
        if (mangling == .msvc) for (u.args, 0..) |A, k| {
            if (classAbi(A) == .managed_copy) destroy = destroy ++ &[_]usize{this_visible + 1 + k};
        };
        return .{
            .params = plan.ext_params,
            .ret = if (ret_index) |i| plan.ext_params[i] else plan.ext_ret,
            .this_index = plan.this_ext.?,
            .ret_index = ret_index,
            .visible_params = V,
            .visible_ret = visibleRet(u),
            .from = from,
            .this_visible = this_visible,
            .ret_visible = managed_ret,
            .destroy = destroy,
        };
    }
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
    const ext = @extern(*const ExtFnType(plan), .{ .name = name });
    return &trampoline(mangling, r, plan, Direct(ext), false);
}

/// Binds a virtual function for a *virtual* call: the function comes from
/// the object's vtable, so an override runs, whichever class defines it and
/// whether it is C++ or Zig. `bind` on the same signature calls that one
/// class's definition directly, as a qualified call would in C++.
///
/// The result has `bind`'s type, so a binding can switch between the two by
/// name alone. The signature is the one `bind` takes, with `.virtual = true`;
/// `.class` names a base of what `this` points at, and the call then goes
/// through that base's vtable. The class `this` points at needs
/// `cpp_virtuals` all the way down (see `vtable.zig`).
pub fn bindVirtual(comptime sig: Signature) *const FnType(default_mangling, sig) {
    @setEvalBranchQuota(1 << 20);
    const r = comptime substituted(sig);
    const f = comptime describe(sig);
    const Self = comptime checkVirtualCall(sig);
    const loc = comptime vtable.slotOf(Self, sig);
    // `this` goes to the subobject whose vtable holds the slot, not to the
    // base the name belongs to: `loc.offset` already accounts for both.
    const unadjusted = comptime blk: {
        var u = r;
        u.class = null;
        break :blk u;
    };
    const plan = comptime planFor(default_mangling, unadjusted, f);
    const Ext = ExtFnType(plan);
    const Callee = struct {
        inline fn get(ext_args: *@Tuple(plan.ext_params)) *const Ext {
            const i = comptime plan.this_ext.?;
            const sub = @intFromPtr(ext_args[i]) + loc.offset;
            ext_args[i] = @ptrFromInt(sub);
            const vptr: *const [*]const *const anyopaque = @ptrFromInt(sub);
            return @ptrCast(vptr.*[loc.index]);
        }
    };
    const c_abi = comptime planFor(default_mangling, r, f).isIdentity(r);
    return &trampoline(default_mangling, unadjusted, plan, Callee, c_abi);
}

/// The class whose vtable a virtual call reads.
fn checkVirtualCall(comptime sig: Signature) type {
    const Self = sig.this orelse @compileError(sig.name ++ ": a virtual call needs a `this`");
    const C = thisPointee(sig.name, Self);
    if (std.mem.eql(u8, sig.name, "*") or std.mem.eql(u8, sig.name, "~"))
        @compileError(sig.name ++ ": a constructor or destructor cannot be called virtually through bindVirtual; call it with bind");
    if (!sig.virtual and !sig.pure) @compileError(sig.name ++ ": bindVirtual needs .virtual = true");
    if (std.mem.indexOf(u8, sig.name, "::") != null)
        @compileError(sig.name ++ ": bindVirtual needs a bare name, with the base in .class if it is not the class `this` points at");
    _ = thisAdjust(sig); // checks that `.class` is a base
    return C;
}

fn ExtFnType(comptime plan: Plan) type {
    return @Fn(plan.ext_params, &@splat(.{}), plan.ext_ret, .{ .@"callconv" = .c });
}

/// The callee a trampoline calls when it is one fixed symbol.
fn Direct(comptime ext: anytype) type {
    return struct {
        inline fn get(_: anytype) @TypeOf(ext) {
            return ext;
        }
    };
}

/// Where a parameter of the real extern function comes from.
const Source = union(enum) {
    visible: usize,
    /// A visible pointer plus a constant: `this` moved to a base subobject.
    adjusted: struct { visible: usize, offset: usize },
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
    /// The index of `this` in `ext_params`, for a member function.
    this_ext: ?usize = null,

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
    comptime var this_ext: ?usize = null;

    // Hidden return pointer: before `this` on Itanium, after it on MSVC.
    if (hidden_ret and mangling == .itanium) {
        ext_params = ext_params ++ &[_]type{RetPtr};
        sources = sources ++ &[_]Source{ret_src};
    }
    if (sig.this) |T| {
        this_ext = ext_params.len;
        const adjust = thisAdjust(sig);
        if (adjust == 0) {
            ext_params = ext_params ++ &[_]type{T};
            sources = sources ++ &[_]Source{.{ .visible = this_idx }};
        } else {
            ext_params = ext_params ++ &[_]type{PointerTo(sig.class.?, T)};
            sources = sources ++ &[_]Source{.{ .adjusted = .{ .visible = this_idx, .offset = adjust } }};
        }
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
        .this_ext = this_ext,
    };
}

/// A function with the visible signature that performs the real call per
/// `plan`. A function body cannot take a generated parameter list, so there
/// is one entry point per arity and a last one, `fN`, that takes the whole
/// argument list as a tuple for the arities no named entry point covers.
///
/// `Callee.get` yields the function to call from the real argument list,
/// which it may also adjust: one fixed symbol (`Direct`), or a vtable slot.
/// With `c_abi` the entry points take the C calling convention and the type
/// is `IdentityFnType`, for a call whose shape needs no wrapper but whose
/// callee is only known at run time.
fn trampoline(comptime mangling: Mangling, comptime sig: Signature, comptime plan: Plan, comptime Callee: type, comptime c_abi: bool) if (c_abi) IdentityFnType(sig) else TrampolineFnType(sig) {
    const V = comptime visibleParams(sig);
    const R = comptime visibleRet(sig);
    const cc: std.builtin.CallingConvention = if (c_abi) .c else .auto;
    const T = struct {
        inline fn invoke(args: @Tuple(V)) R {
            var tmp: (if (plan.ret_from_tmp) R else void) = undefined;
            var ext_args: @Tuple(plan.ext_params) = undefined;
            inline for (plan.sources, 0..) |src, i| {
                ext_args[i] = switch (src) {
                    .visible => |v| args[v],
                    .adjusted => |a| @ptrFromInt(@intFromPtr(args[a.visible]) + a.offset),
                    .tmp_ret => &tmp,
                    .hidden_int => |c| c,
                };
            }
            const callee = Callee.get(&ext_args);
            const r = @call(.auto, callee, ext_args);
            inline for (plan.destroy) |v| {
                const dtor = comptime bindWithMangling(mangling, .{ .name = "~", .this = V[v] });
                dtor(args[v]);
            }
            return if (plan.ret_from_tmp) tmp else r;
        }
        fn f0() callconv(cc) R {
            return invoke(.{});
        }
        fn f1(a: V[0]) callconv(cc) R {
            return invoke(.{a});
        }
        fn f2(a: V[0], b: V[1]) callconv(cc) R {
            return invoke(.{ a, b });
        }
        fn f3(a: V[0], b: V[1], c: V[2]) callconv(cc) R {
            return invoke(.{ a, b, c });
        }
        fn f4(a: V[0], b: V[1], c: V[2], d: V[3]) callconv(cc) R {
            return invoke(.{ a, b, c, d });
        }
        fn f5(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4]) callconv(cc) R {
            return invoke(.{ a, b, c, d, e });
        }
        fn f6(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5]) callconv(cc) R {
            return invoke(.{ a, b, c, d, e, g });
        }
        fn f7(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6]) callconv(cc) R {
            return invoke(.{ a, b, c, d, e, g, h });
        }
        fn f8(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6], i: V[7]) callconv(cc) R {
            return invoke(.{ a, b, c, d, e, g, h, i });
        }
        fn f9(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6], i: V[7], j: V[8]) callconv(cc) R {
            return invoke(.{ a, b, c, d, e, g, h, i, j });
        }
        fn f10(a: V[0], b: V[1], c: V[2], d: V[3], e: V[4], g: V[5], h: V[6], i: V[7], j: V[8], k: V[9]) callconv(cc) R {
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
        else => if (c_abi) @compileError(sig.name ++ ": a virtual call with more than ten parameters needs a wrapper; this shape has none") else T.fN,
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
/// from `Counter`'s `cpp_name`. To call a base's method through a derived
/// pointer, use `bind` with `.class = Base` and the derived `this`: the
/// relation is checked against `cpp_bases` and `this` is moved to the base
/// subobject. A qualified name such as `"ns::Base::get"` also overrides the
/// class, but names no Zig type, so it is neither checked nor adjusted.
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
        .is_virtual = sig.virtual or sig.pure,
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

/// How far `this` moves to reach the class a bare `name` belongs to, when
/// `this` points at a class derived from it: zero for the class itself or a
/// primary base, and a compile error for a class that is not a base at all.
/// A qualified name gives no class to check against and is passed through
/// as written.
fn thisAdjust(comptime sig: Signature) comptime_int {
    const Class = sig.class orelse return 0;
    const Self = sig.this orelse return 0;
    const Derived = thisPointee(sig.name, Self);
    if (Derived == Class) return 0;
    return inherit.baseOffset(Derived, Class) orelse
        @compileError(sig.name ++ ": " ++ @typeName(Class) ++ " is not a base of " ++ @typeName(Derived) ++ ", the class `this` points at; list it in cpp_bases");
}

/// `*Class` with the constness of `Self`.
fn PointerTo(comptime Class: type, comptime Self: type) type {
    return if (@typeInfo(Self).pointer.attrs.@"const") *const Class else *Class;
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
    _ = inherit;
    _ = vtable;
    _ = subclass;
    _ = itanium;
    _ = msvc;
    _ = @import("testing.zig");
}
