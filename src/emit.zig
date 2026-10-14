//! Emits a C++ translation unit that does two things the Zig side cannot do
//! for itself:
//!
//! 1. Forces a definition to exist for every entity a binding names. A class
//!    template specialization, an inline function, an inline member: each has
//!    no symbol until some translation unit emits one, and a header alone
//!    never does. The glue is that translation unit.
//! 2. Checks, in the C++ compiler, that every Zig type standing for a C++
//!    class has the size, alignment, member offsets, and ABI category that
//!    the class really has, and that its declared bases are bases and its
//!    polymorphism is as declared. `cpp-bindgen` reads no headers, so these are the
//!    facts a binding gets wrong; a `static_assert` turns a silent memory
//!    corruption into a compile error.
//!
//! `render` builds the whole file as a comptime string. A generator binary
//! (`tools/emit.zig`) writes it out, and `build.zig` either compiles it into
//! the same build as the bindings (`addCppGlue`) or hands back its path
//! (`generateCppGlue`). The file needs no particular compiler flags of its
//! own: what would otherwise be optimized away carries `CPPBINDGEN_KEEP`,
//! and the one warning it provokes is suppressed in the file.
const std = @import("std");
const cpp = @import("root.zig");
const ctype = @import("ctype.zig");
const cppsrc = @import("cppsrc.zig");
const inherit = @import("inherit.zig");
const itanium = @import("itanium.zig");

const CType = ctype.CType;
const Signature = cpp.Signature;

/// What to emit. `build.zig` writes this; a binding file never declares one.
///
/// `modules` are the roots of the scan. Each is walked for types carrying
/// `cpp_name` or `cpp_template` and for `Signature` constants, then the walk
/// follows every public re-export of another namespace, and finally each type
/// found is itself walked for the `Signature` constants declared on it.
pub const Manifest = struct {
    /// `#include` lines, verbatim and in order: `"ofMain.h"`, `<vector>`.
    headers: []const []const u8 = &.{},
    /// Where the scan starts.
    modules: []const type = &.{},
};

// Declarations a Zig type may carry to steer the glue:
//
// - `cpp_no_instantiate: bool`: do not explicitly instantiate this class
//   template specialization. Explicit instantiation instantiates *every*
//   member, including ones that do not compile for these template arguments,
//   which is a real hazard for a standard-library container.
// - `cpp_no_offsets: bool`: check size and alignment but not member offsets.
//
// A field whose name starts with `_` is not checked: that is how a binding
// spells a vtable pointer, a virtual base, or tail padding, none of which is
// a C++ member that `offsetof` can name.
//
// A type with `cpp_bases`, `cpp_polymorphic`, or `cpp_virtual_dtor` is also
// checked for those: each base is a base of it, and it and each base are
// polymorphic exactly when the binding says. Where the bases end is what the
// derived class's own members are placed after, so their `offsetof` checks
// cover that too.
//
// A public `Signature` declared on the type is a method of that class, and is
// picked up exactly as one declared at module scope would be.

/// What every stub carries. A constructor, a destructor, and a virtual
/// function have no address to take, so a stub names one by calling it, and
/// it is that call that has to survive: inline it and the out-of-line copy
/// the linker needs is dead, and is dropped. `optnone` says so for the one
/// function, which `-fno-inline` -- a flag over the whole file -- cannot: the
/// definitions this file exists to emit stay optimized, so the copy it
/// contributes to the link is no worse than any other translation unit's.
const keep = "CPPBINDGEN_KEEP ";

/// Defines `keep`, or fails the compile where nothing can.
const keep_macro =
    \\
    \\// A constructor, a destructor, and a virtual function are named below by
    \\// calling them, and those calls have to survive the optimizer.
    \\#if defined(__clang__)
    \\#  define CPPBINDGEN_KEEP [[clang::optnone]]
    \\#elif defined(__NO_INLINE__)
    \\#  define CPPBINDGEN_KEEP
    \\#else
    \\#  error "cpp-bindgen: this file must be compiled with -fno-inline when not using clang."
    \\#  define CPPBINDGEN_KEEP
    \\#endif
    \\
;

/// libc++ tags every header-only member with `[[gnu::abi_tag]]`, and the tag
/// spells the libc++ version and build flags (`B9nie220108`), so the mangled
/// name of `std::string::size` would change with every Zig release and
/// differ between members no binding can tell apart. This file emits those
/// members for the bindings, so it turns the tags off and emits them under
/// their plain names. Every other translation unit keeps its tagged copies;
/// the two never collide, and libc++ already makes these members hidden, a
/// copy per linked image, so nothing depends on there being only one.
const libcxx_no_abi_tag =
    \\
    \\// The bindings name libc++'s header-only members without libc++'s ABI tag.
    \\#ifndef _LIBCPP_NO_ABI_TAG
    \\#  define _LIBCPP_NO_ABI_TAG
    \\#endif
    \\
    \\
;

/// `_LIBCPP_NO_ABI_TAG` is an escape hatch libc++ means to remove someday.
/// When it does, this fails here rather than as undefined symbols.
const libcxx_no_abi_tag_check =
    \\
    \\#if defined(_LIBCPP_VERSION) && defined(_LIBCPP_HIDE_FROM_ABI)
    \\#  define CPPBINDGEN_STR2(...) #__VA_ARGS__
    \\#  define CPPBINDGEN_STR(...) CPPBINDGEN_STR2(__VA_ARGS__)
    \\static constexpr bool cppbindgen_starts(const char* s, const char* w) { return !*w || (*s == *w && cppbindgen_starts(s + 1, w + 1)); }
    \\static constexpr bool cppbindgen_contains(const char* s, const char* w) { return *s && (cppbindgen_starts(s, w) || cppbindgen_contains(s + 1, w)); }
    \\static_assert(!cppbindgen_contains(CPPBINDGEN_STR(_LIBCPP_HIDE_FROM_ABI), "abi_tag"),
    \\    "cpp-bindgen: this libc++ ignores _LIBCPP_NO_ABI_TAG, so its header-only members keep their ABI tag and the bindings cannot name them; "
    \\    "a header included before this file may have pulled libc++ in first, or libc++ has dropped the escape hatch");
    \\#endif
    \\
;

/// The whole glue translation unit.
pub fn render(comptime m: Manifest) []const u8 {
    @setEvalBranchQuota(1 << 30);
    const scope = comptime collectNamespaces(m);
    const types = comptime collectTypes(scope);
    const fns = comptime collectFns(scope, types);

    comptime var out: []const u8 =
        \\// Generated by cpp-bindgen. Do not edit; edit the bindings instead.
        \\//
        \\// Compile this with the same compiler, flags, and headers as the C++ it
        \\// binds, or the facts it checks are not the facts that will be linked.
        \\
        \\
    ;
    if (cpp.default_mangling == .itanium) out = out ++ libcxx_no_abi_tag;
    inline for (m.headers) |h| out = out ++ "#include " ++ include(h) ++ "\n";
    // offsetof needs a declaration, and no C++ header is guaranteed here.
    out = out ++ "#include <stddef.h>\n";
    if (cpp.default_mangling == .itanium) out = out ++ libcxx_no_abi_tag_check;
    out = out ++ keep_macro;

    // Aliases first: they name each class once, so the checks and the stubs
    // below stay readable however long a template-id is.
    out = out ++ "\n// Every C++ class a binding names.\n";
    inline for (types, 0..) |t, i| out = out ++ "typedef " ++ cppsrc.pathName(t.info.path) ++ " " ++ alias(i) ++ ";\n";

    if (cpp.default_mangling == .itanium) out = out ++ libcxxChecks(types, fns);
    out = out ++ instantiations(types);
    out = out ++ definitions(fns, types);
    out = out ++ notForced(fns);
    out = out ++ checks(types);
    return out;
}

fn include(comptime h: []const u8) []const u8 {
    // A header already spelled `<...>` or `"..."` is taken as written.
    if (h.len > 0 and (h[0] == '<' or h[0] == '"')) return h;
    return "\"" ++ h ++ "\"";
}

fn alias(comptime i: usize) []const u8 {
    return "cppbindgen_t" ++ ctype.decimal(i);
}

/// A scanned type: the Zig type and what `ctype` made of it.
const Entry = struct {
    T: type,
    info: CType.Named,
    /// The specialization is explicitly instantiated.
    instantiate: bool,
    /// Member offsets are checked.
    offsets: bool,
};

/// Every namespace the scan covers: the manifest's modules, and whatever
/// they publicly re-export, transitively. A bindings file split across
/// several files is reached by `pub const string = @import("string.zig");`.
fn collectNamespaces(comptime m: Manifest) []const type {
    comptime var out: []const type = &.{};
    inline for (m.modules) |mod| out = addNamespace(out, mod);
    return out;
}

fn addNamespace(comptime list: []const type, comptime T: type) []const type {
    inline for (list) |seen| if (seen == T) return list;
    comptime var out: []const type = list ++ &[_]type{T};
    inline for (declNames(T)) |name| {
        if (@TypeOf(@field(T, name)) != type) continue;
        const D = @field(T, name);
        if (isNamespace(D)) out = addNamespace(out, D);
    }
    return out;
}

/// A file or a plain namespace: a struct with no fields that does not stand
/// for a C++ class. Only *public* declarations are visible to the walk, so a
/// private `const std = @import("std")` cannot drag the standard library in;
/// a public one would, and is worth avoiding in a binding file.
fn isNamespace(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (info.@"struct".field_names.len != 0) return false;
    return !@hasDecl(T, "cpp_name") and !@hasDecl(T, "cpp_template");
}

fn collectTypes(comptime scope: []const type) []const Entry {
    comptime var out: []const Entry = &.{};
    inline for (scope) |mod| {
        inline for (declNames(mod)) |name| {
            if (@TypeOf(@field(mod, name)) != type) continue;
            const T = @field(mod, name);
            if (!isClassLike(T)) continue;
            if (!@hasDecl(T, "cpp_name") and !@hasDecl(T, "cpp_template")) continue;
            out = addType(out, T);
        }
    }
    return out;
}

fn isClassLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

/// The public declarations of any container. A module is a struct, so this
/// reads a file and a class the same way.
///
/// Every scan tests a declaration's type before it reads the value: reading
/// a function's value makes the generator compile it, and a wrapper that
/// calls a bound function then references a C++ symbol the generator, which
/// links no C++, cannot resolve.
fn declNames(comptime T: type) []const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => |c| c.decl_names,
        .@"union" => |c| c.decl_names,
        .@"enum" => |c| c.decl_names,
        .@"opaque" => |c| c.decl_names,
        else => @compileError(@typeName(T) ++ ": only a container has declarations to scan"),
    };
}

fn addType(comptime list: []const Entry, comptime T: type) []const Entry {
    const t = ctype.fromZig(T);
    if (t != .named) @compileError(@typeName(T) ++ ": not a C++ class type");
    // Two Zig types may describe one C++ class; the class is checked once.
    inline for (list) |e| if (std.mem.eql(u8, ctype.pathKey(e.info.path), ctype.pathKey(t.named.path))) return list;
    const templated = t.named.path[t.named.path.len - 1].args.len > 0;
    return list ++ &[_]Entry{.{
        .T = T,
        .info = t.named,
        .instantiate = templated and t.named.kind != .@"enum" and !flag(T, "cpp_no_instantiate"),
        .offsets = !flag(T, "cpp_no_offsets"),
    }};
}

fn flag(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, name) and @field(T, name);
}

fn collectFns(comptime scope: []const type, comptime types: []const Entry) []const ctype.Function {
    comptime var out: []const ctype.Function = &.{};
    inline for (scope) |mod| out = addSignatures(out, mod);
    // A method belongs with its class, so a class is scanned like a module.
    inline for (types) |e| out = addSignatures(out, e.T);
    return out;
}

fn addSignatures(comptime list: []const ctype.Function, comptime container: type) []const ctype.Function {
    comptime var out = list;
    inline for (declNames(container)) |name| {
        if (@TypeOf(@field(container, name)) != Signature) continue;
        const d = @field(container, name);
        // A `cpp.firstNamed` marker names no function, and a pure virtual
        // function usually has no definition to force.
        if (comptime cpp.vtable.isNameMarker(d) or d.pure) continue;
        out = addFn(out, cpp.describe(d));
    }
    return out;
}

/// One entry per function. A signature reached twice -- listed in the
/// manifest and declared on its class, say -- must not be emitted twice:
/// two explicit instantiations of one specialization is a redefinition.
fn addFn(comptime list: []const ctype.Function, comptime f: ctype.Function) []const ctype.Function {
    const k = fnKey(f);
    inline for (list) |e| if (std.mem.eql(u8, fnKey(e), k)) return list;
    return list ++ &[_]ctype.Function{f};
}

fn fnKey(comptime f: ctype.Function) []const u8 {
    comptime var k: []const u8 = ctype.pathKey(f.path) ++ "(";
    inline for (f.params) |p| k = k ++ p.key() ++ ",";
    k = k ++ ")";
    if (f.this) |t| k = k ++ (if (t.is_const) " const" else " mut");
    return k;
}

/// The Itanium mangler spells a standard-library name the way libc++
/// declares it, `std::__1::basic_string` for `std::basic_string`, except for
/// the names it knows libc++ keeps directly in `std`. Here each of those
/// spellings is written out for the compiler: one that names nothing is a
/// name the mangler has in the wrong namespace, and fails on its own line
/// rather than as an undefined symbol at link time.
fn libcxxChecks(comptime types: []const Entry, comptime fns: []const ctype.Function) []const u8 {
    comptime var classes: []const []const ctype.Component = &.{};
    comptime var free: []const []const ctype.Component = &.{};
    inline for (types) |e| classes = stdPaths(classes, .{ .named = e.info });
    inline for (fns) |f| {
        classes = stdPaths(classes, f.ret);
        inline for (f.params) |p| classes = stdPaths(classes, p);
        if (f.this != null or f.is_static or f.special != .none) {
            classes = addStdPath(classes, f.path[0 .. f.path.len - 1]);
        } else {
            free = addStdPath(free, f.path);
        }
    }

    comptime var out: []const u8 = "";
    inline for (classes) |path| {
        const mangled = itanium.libcxxPath(path);
        if (mangled.len == path.len) continue;
        const written = cppsrc.pathName(path);
        out = out ++ assert("__is_same(" ++ written ++ ", " ++ cppsrc.pathName(mangled) ++ ")", written ++ libcxx_note);
    }
    // A function is named by a using-declaration, which takes the whole
    // overload set and so needs no signature.
    comptime var usings: []const u8 = "";
    inline for (free) |path| {
        const mangled = itanium.libcxxPath(path);
        if (mangled.len == path.len) continue;
        usings = usings ++ "    using ::" ++ cppsrc.pathName(mangled[0 .. mangled.len - 1]) ++ "::" ++ mangled[mangled.len - 1].name ++ ";\n";
    }
    if (usings.len > 0) out = out ++ "// Each of these functions" ++ libcxx_note ++ "\nnamespace cppbindgen_libcxx {\n" ++ usings ++ "}\n";
    if (out.len == 0) return "";
    return "\n// Standard-library names, spelled as the mangler spells them.\n" ++ out;
}

const libcxx_note = " is mangled as a member of libc++'s inline namespace std::__1; a name libc++ declares directly in std belongs in cpp-bindgen's abi.libcxx.unversioned";

/// Every `std::` class path in `t`, template arguments included.
fn stdPaths(comptime list: []const []const ctype.Component, comptime t: CType) []const []const ctype.Component {
    return switch (t) {
        .builtin, .template_param => list,
        .pointer => |p| stdPaths(list, p.child.*),
        .reference => |r| stdPaths(list, r.child.*),
        .named => |n| blk: {
            comptime var out = addStdPath(list, n.path);
            inline for (n.path) |c| inline for (c.args) |a| {
                out = switch (a) {
                    .type => |at| stdPaths(out, at),
                    .integral => |v| stdPaths(out, v.type),
                };
            };
            break :blk out;
        },
    };
}

fn addStdPath(comptime list: []const []const ctype.Component, comptime path: []const ctype.Component) []const []const ctype.Component {
    if (path.len < 2 or !std.mem.eql(u8, path[0].name, "std")) return list;
    const k = ctype.pathKey(path);
    inline for (list) |p| if (std.mem.eql(u8, ctype.pathKey(p), k)) return list;
    return list ++ &[_][]const ctype.Component{path};
}

/// `template struct tpl::vec<3, float, (tpl::qualifier)1>;` — the one
/// construct that emits a whole specialization, members included.
fn instantiations(comptime types: []const Entry) []const u8 {
    comptime var out: []const u8 = "";
    inline for (types) |e| {
        if (!e.instantiate) continue;
        out = out ++ "template " ++ cppsrc.kindKeyword(e.info.kind) ++ " " ++ cppsrc.pathName(e.info.path) ++ ";\n";
    }
    if (out.len == 0) return "";
    return "\n// Class template specializations, instantiated here so their\n" ++
        "// members exist as symbols.\n" ++ out;
}

/// Forces a definition for each named function. Taking a function's address
/// from a variable with external linkage is the only form that survives
/// optimization: a call can be inlined, after which the out-of-line copy of
/// an inline function is dead and is dropped. Constructors, destructors, and
/// virtual functions have no usable address, so they get a stub that calls
/// them instead, and the call is the thing that has to survive: every such
/// stub carries `keep`.
fn definitions(comptime fns: []const ctype.Function, comptime types: []const Entry) []const u8 {
    comptime var out: []const u8 = "";
    inline for (fns, 0..) |f, i| {
        if (f.access != .public) continue;
        const name = "cppbindgen_f" ++ ctype.decimal(i);
        out = out ++ switch (f.special) {
            .ctor => ctorStub(f, types, name),
            .dtor => dtorStub(f, types, name),
            .none => if (f.path[f.path.len - 1].args.len > 0)
                fnInstantiation(f)
            else if (f.is_virtual)
                virtualStub(f, types, name)
            else
                pointerDecl(f, name),
        } ++ "\n";
    }
    if (out.len == 0) return "";
    return "\n// Header-only functions, forced to exist as symbols.\n" ++ out;
}

/// The functions `definitions` leaves out, by name, so the gap shows. A
/// non-public member cannot be named from outside its class: a private one
/// not at all, a protected one only from a derived class. A virtual one
/// needs nothing from the glue, since its class's vtable references it and
/// is emitted wherever the class is constructed.
fn notForced(comptime fns: []const ctype.Function) []const u8 {
    comptime var out: []const u8 = "";
    inline for (fns) |f| {
        if (f.access == .public) continue;
        out = out ++ "//   " ++ @tagName(f.access) ++ ": " ++ displayName(f) ++ "\n";
    }
    if (out.len == 0) return "";
    return "\n// Not forced, because not public. Each exists only if some other\n" ++
        "// translation unit emits it.\n" ++ out;
}

/// `ns::X::get(int) const`, `ns::X::X(int)`, `ns::X::~X()`.
fn displayName(comptime f: ctype.Function) []const u8 {
    const class = f.path[0 .. f.path.len - 1];
    const own = class[class.len - 1].name;
    const name = switch (f.special) {
        .ctor => own,
        .dtor => "~" ++ own,
        .none => f.path[f.path.len - 1].name,
    };
    const qual = if (f.this) |t| (if (t.is_const) " const" else "") else "";
    return cppsrc.pathName(class) ++ "::" ++ name ++ cppsrc.paramList(f.params) ++ qual;
}

/// `template int ns::tpl_id<int>(int const&);` — an explicit instantiation
/// definition, which emits the specialization outright. Taking the address
/// would only deduce it, and a deduced specialization of a header-only
/// template is still nothing the linker can find. Where the program also
/// explicitly specializes these arguments the instantiation has no effect,
/// which is right: that specialization has its own definition elsewhere.
fn fnInstantiation(comptime f: ctype.Function) []const u8 {
    const targs = f.path[f.path.len - 1].args;
    const ret = cppsrc.typeName(ctype.substitute(f.ret, targs));
    const params = cppsrc.paramList(substituteAll(f.params, targs));
    const qual = if (f.this) |t| (if (t.is_const) " const" else "") else "";
    return "template " ++ ret ++ " " ++ cppsrc.pathName(f.path) ++ params ++ qual ++ ";";
}

fn substituteAll(comptime params: []const CType, comptime targs: []const ctype.Arg) []const CType {
    comptime var out: []const CType = &.{};
    inline for (params) |p| out = out ++ &[_]CType{ctype.substitute(p, targs)};
    return out;
}

/// `int (*cppbindgen_f0)(int, int) = &ns::add;`, or the member-pointer form.
/// The declared type is what picks one function out of an overload set.
fn pointerDecl(comptime f: ctype.Function, comptime name: []const u8) []const u8 {
    const target = " = &" ++ cppsrc.pathName(f.path) ++ ";";
    const ret = cppsrc.typeName(f.ret) ++ " ";
    const params = cppsrc.paramList(f.params);
    if (f.this) |t| {
        const cls = cppsrc.pathName(f.path[0 .. f.path.len - 1]);
        return ret ++ "(" ++ cls ++ "::*" ++ name ++ ")" ++ params ++ (if (t.is_const) " const" else "") ++ target;
    }
    return ret ++ "(*" ++ name ++ ")" ++ params ++ target;
}

/// A virtual function's address is a vtable slot, not the definition, so the
/// address form would force nothing. A qualified call names the definition.
fn virtualStub(comptime f: ctype.Function, comptime types: []const Entry, comptime name: []const u8) []const u8 {
    const cls = aliasOf(f.path[0 .. f.path.len - 1], types, f);
    const self = cls ++ (if (f.this.?.is_const) " const" else "") ++ "* self";
    const args = cppsrc.argList(f.params);
    const sep = if (f.params.len == 0) "" else ", ";
    return keep ++ "void " ++ name ++ "(" ++ self ++ sep ++ innerParams(f.params) ++ ") { (void)(self->" ++
        cls ++ "::" ++ f.path[f.path.len - 1].name ++ "(" ++ args ++ ")); }";
}

/// Constructing an object is the only way to name a constructor.
fn ctorStub(comptime f: ctype.Function, comptime types: []const Entry, comptime name: []const u8) []const u8 {
    const cls = aliasOf(f.path[0 .. f.path.len - 1], types, f);
    const init = if (f.params.len == 0) "" else "(" ++ cppsrc.argList(f.params) ++ ")";
    return keep ++ "void " ++ name ++ "(" ++ innerParams(f.params) ++ ") { " ++ cls ++ " tmp" ++ init ++ "; (void)tmp; }";
}

/// A destructor named through a typedef, which is how a template-id or a
/// qualified name can appear in a destructor call at all. The call is
/// qualified: an unqualified one on a class with a virtual destructor is a
/// vtable dispatch, which names no definition and so forces nothing.
fn dtorStub(comptime f: ctype.Function, comptime types: []const Entry, comptime name: []const u8) []const u8 {
    const cls = aliasOf(f.path[0 .. f.path.len - 1], types, f);
    return keep ++ "void " ++ name ++ "(" ++ cls ++ "* self) { self->" ++ cls ++ "::~" ++ cls ++ "(); }";
}

fn innerParams(comptime params: []const CType) []const u8 {
    if (params.len == 0) return "";
    const list = cppsrc.namedParamList(params);
    return list[1 .. list.len - 1];
}

/// The alias of a class the glue already named. A constructor or destructor
/// can only be spelled through one, so the class has to be in the manifest.
fn aliasOf(comptime path: []const ctype.Component, comptime types: []const Entry, comptime f: ctype.Function) []const u8 {
    const key = ctype.pathKey(path);
    inline for (types, 0..) |e, i| if (std.mem.eql(u8, ctype.pathKey(e.info.path), key)) return alias(i);
    @compileError(ctype.pathKey(f.path) ++ ": the glue needs a Zig type for '" ++ key ++
        "'; add it to the manifest's modules or types");
}

/// The layout and ABI facts a binding asserts, checked against the real class.
fn checks(comptime types: []const Entry) []const u8 {
    comptime var out: []const u8 = "";
    inline for (types, 0..) |e, i| {
        const a = alias(i);
        const cxx = cppsrc.pathName(e.info.path);
        if (@typeInfo(e.T) != .@"opaque") {
            out = out ++ assert("sizeof(" ++ a ++ ") == " ++ ctype.decimal(@sizeOf(e.T)), cxx ++ " is not " ++ ctype.decimal(@sizeOf(e.T)) ++ " bytes, the size of " ++ @typeName(e.T));
            out = out ++ assert("alignof(" ++ a ++ ") == " ++ ctype.decimal(@alignOf(e.T)), cxx ++ " does not have alignment " ++ ctype.decimal(@alignOf(e.T)) ++ ", the alignment of " ++ @typeName(e.T));
            out = out ++ abiCheck(e, a, cxx);
            out = out ++ baseChecks(e, a, cxx);
            if (e.offsets) out = out ++ offsetChecks(e, a, cxx);
        }
    }
    if (out.len == 0) return "";
    // `offsetof` on a class that is not standard layout is conditionally
    // supported rather than ill-formed, and a binding for a class with a base
    // or a vtable needs it. Suppressing the warning here rather than through
    // a flag is what lets this file be compiled any way at all.
    return "\n// What the bindings claim about each class, checked against it.\n" ++
        "#if defined(__clang__) || defined(__GNUC__)\n" ++
        "#  pragma GCC diagnostic ignored \"-Winvalid-offsetof\"\n" ++
        "#endif\n" ++ out;
}

/// `ClassAbi` in the C++ compiler's own terms. The category decides how a
/// class travels by value, so getting it wrong corrupts every by-value call;
/// nothing on the Zig side can catch that, and this does.
fn abiCheck(comptime e: Entry, comptime a: []const u8, comptime cxx: []const u8) []const u8 {
    if (@typeInfo(e.T) == .@"enum") return "";
    // Itanium's "non-trivial for the purposes of calls": a class travels by
    // pointer once any of its copy constructor, move constructor, or
    // destructor is non-trivial.
    const trivial_for_calls = "__is_trivially_constructible(" ++ a ++ ", " ++ a ++ " const&) && " ++
        "__is_trivially_constructible(" ++ a ++ ", " ++ a ++ "&&) && " ++
        "__is_trivially_destructible(" ++ a ++ ")";
    return switch (e.info.abi) {
        .c_struct => assert(
            "__is_trivial(" ++ a ++ ") && __is_standard_layout(" ++ a ++ ")",
            cxx ++ " is not a plain C struct, so cpp_abi = .c_struct is wrong for it; it needs .trivial_copy or .managed_copy",
        ),
        // MSVC returns a class in a register only when it could have been
        // written in C, so a genuinely trivial class is .c_struct, not this.
        .trivial_copy => assert(
            trivial_for_calls ++ " && !__is_trivial(" ++ a ++ ")",
            cxx ++ " does not match cpp_abi = .trivial_copy; it is either a plain C struct (.c_struct) or non-trivial to copy (.managed_copy)",
        ),
        .managed_copy => assert(
            "!(" ++ trivial_for_calls ++ ")",
            cxx ++ " is trivial to copy, so cpp_abi = .managed_copy is wrong for it; it needs .c_struct or .trivial_copy",
        ),
    };
}

/// The inheritance facts a binding declares. `__is_base_of` catches a
/// `cpp_bases` entry that names the wrong class; `__is_polymorphic` catches
/// a vtable pointer the calculator put in or left out, which the size check
/// alone would not, since the class's own members shift to absorb it.
fn baseChecks(comptime e: Entry, comptime a: []const u8, comptime cxx: []const u8) []const u8 {
    if (@typeInfo(e.T) != .@"struct") return "";
    if (!@hasDecl(e.T, "cpp_bases") and !@hasDecl(e.T, "cpp_polymorphic") and !@hasDecl(e.T, "cpp_virtual_dtor")) return "";
    inherit.checkSpan(e.T);
    comptime var out: []const u8 = polymorphicCheck(e.T, a, cxx);
    if (@hasDecl(e.T, "cpp_bases")) inline for (e.T.cpp_bases) |B| {
        const b = cppsrc.pathName(ctype.fromZig(B).named.path);
        out = out ++ assert("__is_base_of(" ++ b ++ ", " ++ a ++ ")", b ++ " is not a base of " ++ cxx ++ ", which " ++ @typeName(e.T) ++ "'s cpp_bases claims");
        out = out ++ polymorphicCheck(B, b, b);
    };
    return out;
}

fn polymorphicCheck(comptime T: type, comptime a: []const u8, comptime cxx: []const u8) []const u8 {
    return if (inherit.isPolymorphic(T))
        assert("__is_polymorphic(" ++ a ++ ")", cxx ++ " has no virtual functions, but " ++ @typeName(T) ++ " says it does (cpp_polymorphic or cpp_virtual_dtor)")
    else
        assert("!__is_polymorphic(" ++ a ++ ")", cxx ++ " has virtual functions, which " ++ @typeName(T) ++ " does not declare (cpp_polymorphic = true)");
}

/// One `offsetof` per field, which is what catches a member the binding is
/// missing, has in the wrong order, or spells at the wrong width.
fn offsetChecks(comptime e: Entry, comptime a: []const u8, comptime cxx: []const u8) []const u8 {
    if (@typeInfo(e.T) != .@"struct") return "";
    comptime var out: []const u8 = "";
    inline for (@typeInfo(e.T).@"struct".field_names) |field| {
        if (field[0] == '_') continue;
        const off = ctype.decimal(@offsetOf(e.T, field));
        out = out ++ assert("offsetof(" ++ a ++ ", " ++ field ++ ") == " ++ off, cxx ++ "::" ++ field ++ " is not at offset " ++ off ++ ", where " ++ @typeName(e.T) ++ " puts it");
    }
    return out;
}

fn assert(comptime cond: []const u8, comptime message: []const u8) []const u8 {
    return "static_assert(" ++ cond ++ ", \"cpp-bindgen: " ++ message ++ "\");\n";
}

test "render checks a class" {
    const mod = struct {
        pub const Counter = extern struct {
            n: c_int,
            pub const cpp_name = "ns::Counter";
        };
        pub const get: Signature = .{ .name = "get", .ret = c_int, .this = *const Counter };
    };
    const out = comptime render(.{ .headers = &.{"counter.h"}, .modules = &.{mod} });
    try expectContains(out, "#include \"counter.h\"");
    try expectContains(out, "typedef ns::Counter cppbindgen_t0;");
    try expectContains(out, "int (ns::Counter::*cppbindgen_f0)() const = &ns::Counter::get;");
    try expectContains(out, "static_assert(sizeof(cppbindgen_t0) == 4,");
    try expectContains(out, "static_assert(alignof(cppbindgen_t0) == 4,");
    try expectContains(out, "static_assert(offsetof(cppbindgen_t0, n) == 0,");
    try expectContains(out, "static_assert(__is_trivial(cppbindgen_t0) && __is_standard_layout(cppbindgen_t0),");
}

test "render spells standard-library names as the mangler does" {
    const mod = struct {
        pub const Str = opaque {
            pub const cpp_template = cpp.Template{ .name = "std::basic_string", .kind = .class, .args = &.{
                .{ .type = u8 },
                .{ .template = .{ .name = "std::char_traits", .args = &.{.{ .type = u8 }} } },
                .{ .template = .{ .name = "std::allocator", .args = &.{.{ .type = u8 }}, .kind = .class } },
            } };
            pub const cpp_abi: cpp.ClassAbi = .managed_copy;
            pub const cpp_no_instantiate = true;
        };
        pub const Exc = opaque {
            pub const cpp_name = "std::exception";
        };
        pub const size: Signature = .{ .name = "size", .ret = c_ulong, .this = *const Str };
        pub const what: Signature = .{ .name = "f", .args = &.{*const Exc} };
        pub const stoi: Signature = .{ .name = "std::stoi", .args = &.{cpp.Ref(*const Str)}, .ret = c_int };
        pub const terminate: Signature = .{ .name = "std::terminate" };
    };
    const out = comptime render(.{ .modules = &.{mod} });
    if (cpp.default_mangling == .itanium) {
        try expectContains(out, "static_assert(__is_same(std::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::__1::basic_string<char, std::char_traits<char>, std::allocator<char> >),");
        try expectContains(out, "static_assert(__is_same(std::char_traits<char>, std::__1::char_traits<char>),");
        try expectContains(out, "    using ::std::__1::stoi;\n");
        // Already directly in `std`: nothing to check.
        try std.testing.expect(std.mem.indexOf(u8, out, "std::__1::exception") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "__1::terminate") == null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, out, "__1") == null);
    }
}

test "render checks bases and polymorphism" {
    const mod = struct {
        pub const Base = extern struct {
            _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
            b: c_int,
            pub const cpp_name = "ns::Base";
            pub const cpp_abi: cpp.ClassAbi = .managed_copy;
            pub const cpp_virtual_dtor = true;
        };
        pub const Derived = extern struct {
            _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
            d: c_int,
            pub const cpp_name = "ns::Derived";
            pub const cpp_abi: cpp.ClassAbi = .managed_copy;
            pub const cpp_bases: []const type = &.{Base};
        };
        pub const Plain = extern struct {
            _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
            pub const cpp_name = "ns::Plain";
            pub const cpp_abi: cpp.ClassAbi = .trivial_copy;
            pub const cpp_bases: []const type = &.{Pod};
        };
        pub const Pod = extern struct {
            n: c_int,
            pub const cpp_name = "ns::Pod";
        };
    };
    const out = comptime render(.{ .headers = &.{"b.h"}, .modules = &.{mod} });
    // Aliases follow declaration order: t0 Base, t1 Derived, t2 Plain, t3 Pod.
    try expectContains(out, "static_assert(__is_polymorphic(cppbindgen_t0),");
    try expectContains(out, "static_assert(__is_base_of(ns::Base, cppbindgen_t1),");
    try expectContains(out, "static_assert(__is_polymorphic(cppbindgen_t1),");
    try expectContains(out, "static_assert(__is_polymorphic(ns::Base),");
    try expectContains(out, "static_assert(__is_base_of(ns::Pod, cppbindgen_t2),");
    try expectContains(out, "static_assert(!__is_polymorphic(cppbindgen_t2),");
    try expectContains(out, "static_assert(!__is_polymorphic(ns::Pod),");
    // The base span is not a member; the own member sits where the base ends,
    // which is after its data on Itanium and after its whole size on MSVC.
    try std.testing.expect(std.mem.indexOf(u8, out, "offsetof(cppbindgen_t1, _bases)") == null);
    try expectContains(out, "static_assert(offsetof(cppbindgen_t0, b) == 8,");
    try expectContains(out, "static_assert(offsetof(cppbindgen_t1, d) == " ++ (if (cpp.default_mangling == .msvc) "16" else "12") ++ ",");
}

test "render instantiates a specialization and forces a constructor" {
    const mod = struct {
        pub const Cell = extern struct {
            val: c_int,
            pub const cpp_template = cpp.Template{ .name = "tpl::Cell", .args = &.{.{ .type = c_int }} };
            pub const cpp_abi: cpp.ClassAbi = .managed_copy;
        };
        pub const ctor: Signature = .{ .name = "*", .args = &.{c_int}, .this = *Cell };
        pub const dtor: Signature = .{ .name = "~", .this = *Cell };
    };
    const out = comptime render(.{ .headers = &.{"<cell>"}, .modules = &.{mod} });
    try expectContains(out, "#include <cell>");
    try expectContains(out, "template struct tpl::Cell<int>;");
    try expectContains(out, "CPPBINDGEN_KEEP void cppbindgen_f0(int a0) { cppbindgen_t0 tmp(a0); (void)tmp; }");
    try expectContains(out, "CPPBINDGEN_KEEP void cppbindgen_f1(cppbindgen_t0* self) { self->cppbindgen_t0::~cppbindgen_t0(); }");
    try expectContains(out, "static_assert(!(__is_trivially_constructible(cppbindgen_t0, cppbindgen_t0 const&)");
}

test "render names an operator the way C++ spells it" {
    const mod = struct {
        pub const V = extern struct {
            x: c_int,
            pub const cpp_name = "ns::V";
            pub const add: Signature = .{ .name = ":+", .this = *const @This(), .args = &.{cpp.Ref(*const @This())}, .ret = c_int };
            pub const index: Signature = .{ .name = ":[]", .this = *@This(), .args = &.{c_int}, .ret = c_int };
            pub const to_int: Signature = .{ .name = ":cast", .this = *const @This(), .ret = c_int };
        };
    };
    const out = comptime render(.{ .modules = &.{mod} });
    try expectContains(out, "int (ns::V::*cppbindgen_f0)(ns::V const&) const = &ns::V::operator+;");
    try expectContains(out, "int (ns::V::*cppbindgen_f1)(int) = &ns::V::operator[];");
    try expectContains(out, "int (ns::V::*cppbindgen_f2)() const = &ns::V::operator int;");
}

test "render follows public re-exports" {
    const inner = struct {
        pub const Vec = extern struct {
            x: c_int,
            pub const cpp_name = "ns::Vec";
            pub const len: Signature = .{ .name = "len", .ret = c_int, .this = *const @This() };
        };
    };
    const outer = struct {
        // A bindings file split in two reaches the other half this way.
        pub const vec = inner;
        pub const Counter = extern struct {
            n: c_int,
            pub const cpp_name = "ns::Counter";
        };
    };
    const out = comptime render(.{ .modules = &.{outer} });
    try expectContains(out, "typedef ns::Counter cppbindgen_t0;");
    try expectContains(out, "typedef ns::Vec cppbindgen_t1;");
    try expectContains(out, "int (ns::Vec::*cppbindgen_f0)() const = &ns::Vec::len;");
}

test "render finds signatures declared on a class" {
    const mod = struct {
        pub const Counter = extern struct {
            n: c_int,
            pub const cpp_name = "ns::Counter";
            pub const get: Signature = .{ .name = "get", .ret = c_int, .this = *const @This() };
            pub const magic: Signature = .{ .name = "magic", .ret = c_int, .class = @This() };
        };
        // Reaching the same function twice must still emit it once.
        pub const also_get: Signature = Counter.get;
    };
    const out = comptime render(.{ .modules = &.{mod} });
    try expectContains(out, "int (ns::Counter::*cppbindgen_f0)() const = &ns::Counter::get;");
    try expectContains(out, "int (*cppbindgen_f1)() = &ns::Counter::magic;");
    try std.testing.expect(std.mem.indexOf(u8, out, "cppbindgen_f2") == null);
}

test "render instantiates a function template" {
    const mod = struct {
        pub const Vec = extern struct {
            x: c_int,
            pub const cpp_name = "ns::Vec";
        };
        pub const id: Signature = .{ .name = "ns::tpl_id", .template_args = &.{.{ .type = Vec }}, .args = &.{cpp.Ref(*const cpp.TParam(0))}, .ret = c_int };
        pub const take: Signature = .{ .name = "take", .this = *const Vec, .template_args = &.{.{ .type = c_int }}, .args = &.{cpp.Ref(*const cpp.TParam(0))}, .ret = c_int };
    };
    const out = comptime render(.{ .modules = &.{mod} });
    try expectContains(out, "template int ns::tpl_id<ns::Vec>(ns::Vec const&);");
    try expectContains(out, "template int ns::Vec::take<int>(int const&) const;");
}

test "render skips padding fields and honours opt-outs" {
    const mod = struct {
        pub const Poly = extern struct {
            _vptr: *const anyopaque,
            n: c_int,
            _pad: [4]u8,
            pub const cpp_name = "ns::Poly";
            pub const cpp_abi: cpp.ClassAbi = .managed_copy;
        };
        pub const Vec = extern struct {
            v: [3]f32,
            pub const cpp_template = cpp.Template{ .name = "tpl::vec", .args = &.{ .{ .int = 3 }, .{ .type = f32 } } };
            pub const cpp_no_instantiate = true;
            pub const cpp_no_offsets = true;
        };
        pub const f: Signature = .{ .name = "f", .ret = c_int, .this = *Poly, .virtual = true };
        // Pure, and usually without a definition to force.
        pub const g: Signature = .{ .name = "g", .ret = c_int, .this = *Poly, .pure = true };
        pub const marker = cpp.firstNamed("g");
        // Not public: no stub, but named in a comment.
        pub const h: Signature = .{ .name = "h", .args = &.{c_int}, .ret = c_int, .this = *const Poly, .access = .protected };
        pub const hidden_ctor: Signature = .{ .name = "*", .args = &.{u8}, .this = *Poly, .access = .private };
    };
    const out = comptime render(.{ .modules = &.{mod} });
    try std.testing.expect(std.mem.indexOf(u8, out, "::g(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "->cppbindgen_t0::h(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tmp(a0)") == null);
    try expectContains(out, "//   protected: ns::Poly::h(int) const\n");
    try expectContains(out, "//   private: ns::Poly::Poly(char)\n");
    try expectContains(out, "static_assert(offsetof(cppbindgen_t0, n) == 8,");
    try std.testing.expect(std.mem.indexOf(u8, out, "_vptr") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "template struct tpl::vec") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "offsetof(cppbindgen_t1") == null);
    try expectContains(out, "CPPBINDGEN_KEEP void cppbindgen_f0(cppbindgen_t0* self) { (void)(self->cppbindgen_t0::f()); }");
}

fn expectContains(comptime haystack: []const u8, comptime needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nmissing:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}
