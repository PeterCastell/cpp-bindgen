//! Virtual function tables. A polymorphic class lists the virtual functions
//! its header declares (`cpp_virtuals`), and `tables` computes from those
//! lists where every slot of every vtable of the class sits on the target's
//! ABI:
//!
//! ```zig
//! pub const Camera = extern struct {
//!     // ...as for any class with bases...
//!     pub const cpp_virtuals: []const cpp.Signature = &.{ dtor, begin, begin_viewport, end };
//! };
//! ```
//!
//! The list is in header order, includes the destructor and every override,
//! and leaves out what the class only inherits. That one list is correct on
//! both ABIs: the slot order of each is a function of header order. The
//! rules, measured against clang's `-fdump-vtable-layouts` on both (every
//! case is a test below):
//!
//! - Each polymorphic base keeps its own tables, at the offset where that
//!   base sits. The primary base's first table is the class's own, at offset
//!   0; a class with no polymorphic base starts an empty one there.
//! - A declaration with the name, parameters and constness of an inherited
//!   slot overrides it, in every table that has it. Return types are not
//!   compared: a covariant override is out of scope.
//! - The rest are new, and go to the end of the table at offset 0.
//!   Itanium appends them in declaration order, with two destructor slots
//!   (complete, then deleting). It also appends an override that matches
//!   nothing in that table, so that a call through the class itself needs no
//!   `this` adjustment; an implicit destructor counts as declared last.
//!   MSVC appends one destructor slot (the vector deleting destructor) and
//!   never appends an override. It groups overloads: a group goes where the
//!   *first declaration of its name* in the class is, and lists its new
//!   members last to first.
//!
//! "First declaration of its name" means any declaration (clang's
//! `GroupNewVirtualOverloads`): an override, a non-virtual method, a
//! using-declaration. Overrides are in the list already. For the others,
//! put `cpp.firstNamed("name")` in the list where the header declares it.
//! It takes no slot, Itanium ignores it, and it is needed only when such a
//! declaration comes before the name's first entry in the list.
const std = @import("std");
const builtin = @import("builtin");
const cpp = @import("root.zig");
const ctype = @import("ctype.zig");
const inherit = @import("inherit.zig");
const itanium_mangle = @import("itanium.zig");
const msvc_mangle = @import("msvc.zig");

const Signature = cpp.Signature;

/// The slot layout follows the target's C++ ABI, as the base layout does.
const msvc = builtin.target.abi == .msvc;

pub const SlotKind = enum { method, dtor_complete, dtor_deleting };

pub const Slot = struct {
    kind: SlotKind,
    /// The declaration that introduced the slot. An override changes only
    /// `owner`.
    sig: Signature,
    /// The class whose definition the slot holds: the last class in the
    /// chain to declare it. A class with a virtual destructor owns every
    /// destructor slot, since an implicit destructor overrides too.
    owner: type,
    /// Where `owner`'s definition expects `this`, from the start of the
    /// class. A slot in a table elsewhere holds a thunk that moves `this`
    /// there. Itanium: the owner's own start. MSVC: the first table, in the
    /// owner, that has the slot; a destructor, the owner's start.
    this_offset: comptime_int = 0,
    /// The owner declares it pure, so the slot holds the ABI's pure-call
    /// handler rather than a definition.
    pure: bool = false,
    /// The owner's access to its declaration, which MSVC mangles into the
    /// definition's symbol. An override may differ from what it overrides:
    /// ofLight overrides ofNode's public customDraw in a private section.
    access: cpp.Access = .public,
};

pub const Table = struct {
    /// Where the table's vtable pointer sits in the class.
    offset: comptime_int,
    /// The class that introduced the vtable pointer.
    intro: type,
    slots: []const Slot,
    /// MSVC: what tells this table's symbols (`??_7`, `??_R4`) apart from
    /// the class's other tables'. Empty unless the class has two tables that
    /// would otherwise share a name; then the direct base each came through
    /// is appended, a level at a time, until none do (clang's
    /// `MicrosoftVTableContext::computeVTablePaths`). Mangled after `6B`.
    msvc_path: []const type = &.{},
    /// The base `msvc_path` would grow by next.
    msvc_pending: ?type = null,
};

const NameMarker = opaque {};

/// A `cpp_virtuals` entry for a declaration that is not a virtual function
/// of this class, such as a non-virtual method or a using-declaration, but
/// whose name a virtual function of this class shares. It takes no slot; it
/// tells MSVC where that name is first declared. See the top of this file.
pub fn firstNamed(comptime name: []const u8) Signature {
    return .{ .name = name, .class = NameMarker };
}

pub fn isNameMarker(comptime sig: Signature) bool {
    return if (sig.class) |c| c == NameMarker else false;
}

fn isDtor(comptime sig: Signature) bool {
    return std.mem.eql(u8, sig.name, "~");
}

fn isConst(comptime sig: Signature) bool {
    return @typeInfo(sig.this.?).pointer.attrs.@"const";
}

/// What MSVC groups by: the name, which for a conversion operator includes
/// its target type.
fn groupName(comptime sig: Signature) []const u8 {
    if (!isNameMarker(sig) and std.mem.eql(u8, sig.name, ":cast")) return sig.name ++ " " ++ ctype.fromZig(sig.ret).key();
    return sig.name;
}

/// Whether `b` overrides `a`, or the other way round: the same name, the
/// same C++ parameter types, and the same constness. `[*c]T` and `*T` are
/// both `T*`, so parameters are compared as C++ types.
pub fn sameVirtual(comptime a: Signature, comptime b: Signature) bool {
    return comptime blk: {
        if (isDtor(a) or isDtor(b)) break :blk isDtor(a) and isDtor(b);
        if (!std.mem.eql(u8, groupName(a), groupName(b))) break :blk false;
        if (a.args.len != b.args.len) break :blk false;
        for (a.args, b.args) |x, y| {
            if (x != y and !std.mem.eql(u8, ctype.fromZig(x).key(), ctype.fromZig(y).key())) break :blk false;
        }
        break :blk isConst(a) == isConst(b);
    };
}

/// Every vtable of `C`, the one at offset 0 first, each with its slots in
/// the target ABI's order. A slot's index here is its index from where the
/// vtable pointer points.
pub fn tables(comptime C: type) []const Table {
    comptime {
        @setEvalBranchQuota(1 << 20);
        if (!inherit.isPolymorphic(C))
            @compileError(@typeName(C) ++ " has no virtual functions, so it has no vtable (declare cpp_polymorphic or cpp_virtual_dtor if the C++ class has them)");
        if (!@hasDecl(C, "cpp_virtuals"))
            @compileError(@typeName(C) ++ " is polymorphic but declares no cpp_virtuals; list every virtual function its header declares, in header order, the destructor and overrides included (`&.{}` if it declares none)");
        const list: []const Signature = C.cpp_virtuals;
        checkList(C, list);

        var out: []const Table = &.{};
        for (inherit.directBases(C)) |b| {
            if (!inherit.isPolymorphic(b.type)) continue;
            for (tables(b.type)) |t| {
                var moved = t;
                moved.offset = b.offset + t.offset;
                moved.slots = &.{};
                for (t.slots) |s| {
                    var m = s;
                    m.this_offset = b.offset + s.this_offset;
                    moved.slots = moved.slots ++ &[_]Slot{m};
                }
                const p = t.msvc_path;
                if (p.len == 0 or p[p.len - 1] != b.type) moved.msvc_pending = b.type;
                out = out ++ &[_]Table{moved};
            }
        }

        const vdtor = @hasDecl(C, "cpp_virtual_dtor") and C.cpp_virtual_dtor;
        const declares_dtor = for (list) |s| {
            if (isDtor(s)) break true;
        } else false;
        if (hasDtor(out) and !vdtor)
            @compileError(@typeName(C) ++ ": a base's destructor is virtual, so this class's is too; declare cpp_virtual_dtor = true");
        if (vdtor and !hasDtor(out) and !declares_dtor)
            @compileError(@typeName(C) ++ ": the virtual destructor starts here, so it takes a slot where the header declares it; list it in cpp_virtuals");
        if (out.len == 0) {
            const declares_any = for (list) |s| {
                if (!isNameMarker(s)) break true;
            } else false;
            if (!declares_any) @compileError(@typeName(C) ++ " is declared polymorphic, but neither it nor a base lists a virtual function in cpp_virtuals");
            out = &.{.{ .offset = 0, .intro = C, .slots = &.{} }};
        }

        var news: []const Signature = &.{};
        for (list) |sig| {
            if (isNameMarker(sig)) continue;
            const first: ?comptime_int = for (out) |t| {
                if (for (t.slots) |s| {
                    if (sameVirtual(s.sig, sig)) break true;
                } else false) break t.offset;
            } else null;
            const this_offset = if (msvc and !isDtor(sig)) first orelse 0 else 0;
            var in_primary = false;
            var next: []const Table = &.{};
            for (out, 0..) |t, ti| {
                var nt = t;
                nt.slots = &.{};
                for (t.slots) |s| {
                    if (sameVirtual(s.sig, sig)) {
                        if (ti == 0) in_primary = true;
                        nt.slots = nt.slots ++ &[_]Slot{.{ .kind = s.kind, .sig = s.sig, .owner = C, .this_offset = this_offset, .pure = sig.pure, .access = sig.access }};
                    } else nt.slots = nt.slots ++ &[_]Slot{s};
                }
                next = next ++ &[_]Table{nt};
            }
            out = next;
            if (if (msvc) first == null else !in_primary) news = news ++ &[_]Signature{sig};
        }
        if (vdtor) out = ownDestructors(out, C, for (list) |s| {
            if (isDtor(s)) break s.access;
        } else .public);
        if (!msvc and vdtor and !declares_dtor and !hasDtor(out[0..1]))
            news = news ++ &[_]Signature{.{ .name = "~", .this = *C }};

        var primary = out[0];
        primary.slots = primary.slots ++ newSlots(C, list, news);
        const all = &[_]Table{primary} ++ out[1..];
        return if (msvc) disambiguate(C, all) else all;
    }
}

/// Extends `msvc_path`s until no two tables share one.
fn disambiguate(comptime C: type, comptime ts: []const Table) []const Table {
    var cur = ts;
    while (true) {
        var ambiguous = false;
        var extended = false;
        var next: []const Table = &.{};
        for (cur, 0..) |t, i| {
            var nt = t;
            const shared = for (cur, 0..) |u, j| {
                if (i != j and samePath(t.msvc_path, u.msvc_path)) break true;
            } else false;
            if (shared) {
                ambiguous = true;
                if (t.msvc_pending) |b| {
                    nt.msvc_path = t.msvc_path ++ &[_]type{b};
                    nt.msvc_pending = null;
                    extended = true;
                }
            }
            next = next ++ &[_]Table{nt};
        }
        if (!ambiguous) return next;
        if (!extended) @compileError(@typeName(C) ++ ": two of its vtables cannot be told apart by the bases they came through");
        cur = next;
    }
}

fn samePath(comptime a: []const type, comptime b: []const type) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn hasDtor(comptime ts: []const Table) bool {
    for (ts) |t| for (t.slots) |s| if (s.kind != .method) return true;
    return false;
}

/// `access` is that of `C`'s destructor: as listed, or public if implicit.
fn ownDestructors(comptime ts: []const Table, comptime C: type, comptime access: cpp.Access) []const Table {
    var out: []const Table = &.{};
    for (ts) |t| {
        var nt = t;
        nt.slots = &.{};
        for (t.slots) |s| nt.slots = nt.slots ++ &[_]Slot{if (s.kind == .method) s else .{ .kind = s.kind, .sig = s.sig, .owner = C, .access = access }};
        out = out ++ &[_]Table{nt};
    }
    return out;
}

/// `news` in the ABI's order. MSVC orders the groups by `list`, which
/// holds every declaration that can place one.
fn newSlots(comptime C: type, comptime list: []const Signature, comptime news: []const Signature) []const Slot {
    var out: []const Slot = &.{};
    if (!msvc) {
        for (news) |s| out = out ++ if (isDtor(s))
            &[_]Slot{ .{ .kind = .dtor_complete, .sig = s, .owner = C, .access = s.access }, .{ .kind = .dtor_deleting, .sig = s, .owner = C, .access = s.access } }
        else
            &[_]Slot{.{ .kind = .method, .sig = s, .owner = C, .pure = s.pure, .access = s.access }};
        return out;
    }
    var groups: []const []const u8 = &.{};
    for (list) |s| {
        if (!contains(groups, groupName(s))) groups = groups ++ &[_][]const u8{groupName(s)};
    }
    for (groups) |g| {
        var i = news.len;
        while (i > 0) {
            i -= 1;
            const s = news[i];
            if (!std.mem.eql(u8, groupName(s), g)) continue;
            out = out ++ &[_]Slot{.{ .kind = if (isDtor(s)) .dtor_deleting else .method, .sig = s, .owner = C, .pure = s.pure, .access = s.access }};
        }
    }
    return out;
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Where a virtual call finds its function: the vtable pointer at `offset`
/// in the object, and slot `index` of the table it points at.
pub const Location = struct { offset: comptime_int, index: comptime_int };

/// The slot a virtual call through a `*C` reads for `sig`. With `.class`
/// naming a base, the call goes through that base's table; otherwise
/// through the first table that has the slot, the one at offset 0 first,
/// which on Itanium is also the one that needs no thunk.
pub fn slotOf(comptime C: type, comptime sig: Signature) Location {
    comptime {
        if (sig.class) |K| if (K != C) {
            var inner = sig;
            inner.class = null;
            const at = slotOf(K, inner);
            return .{ .offset = inherit.baseOffset(C, K).? + at.offset, .index = at.index };
        };
        for (tables(C)) |t| for (t.slots, 0..) |s, i| {
            if (s.kind == .method and sameVirtual(s.sig, sig)) return .{ .offset = t.offset, .index = i };
        };
        @compileError(sig.name ++ " is not a virtual function of " ++ @typeName(C) ++ " or of its bases, as their cpp_virtuals list them");
    }
}

/// Checks the computed layout of `C` against the vtables the C++ compiler
/// emitted for it: every method slot must hold the function the layout says,
/// so a missing, extra or misplaced entry in the `cpp_virtuals` of `C` or of
/// any base shows as the first slot it moves. Call it from a test; it needs
/// `C`'s vtable to be linked, which it is wherever `C` can be constructed.
///
/// A pure virtual's slot must hold the pure-call handler, which every pure
/// slot shares, so a pure entry listed out of order among other pure ones
/// looks the same. What it cannot see at all: destructor slots and thunks,
/// which hold compiler-generated code with no name a binding gives; and an
/// entry missing from the end of a table, since nothing records how
/// long a table is (on Itanium the next table's header does, so only the
/// last table is blind). Identical code folding at link time can merge two
/// functions with the same body, and a slot holding either then matches
/// both, so run it in a build that does not fold.
pub fn verify(comptime C: type) error{VtableMismatch}!void {
    inline for (comptime tables(C), 0..) |_, ti| try checkTable(C, ti, emitted(C, ti));
}

/// Slot 0 of table `ti` of `C` as the C++ compiler emitted it: what `C`'s
/// constructor points that vtable pointer at.
pub fn emitted(comptime C: type, comptime ti: usize) [*]const usize {
    const sym = comptime symbolOf(C, ti);
    const words: [*]const usize = @ptrCast(@extern(*const [1]usize, .{ .name = sym.name }));
    return words + sym.start;
}

/// `verify`, against the tables a live object's vtable pointers point at:
/// what `C`'s constructor installed, or what a subclass's did.
pub fn verifyObject(comptime C: type, obj: *const C) error{VtableMismatch}!void {
    inline for (comptime tables(C), 0..) |t, ti| {
        const vptr: *const [*]const usize = @ptrFromInt(@intFromPtr(obj) + t.offset);
        try checkTable(C, ti, vptr.*);
    }
}

/// Checks table `ti` of `C`, given where its vtable pointer points.
fn checkTable(comptime C: type, comptime ti: usize, slots: [*]const usize) error{VtableMismatch}!void {
    const t = comptime tables(C)[ti];
    if (!msvc) {
        const top: isize = @bitCast((slots - 2)[0]);
        if (top != -t.offset) {
            log.warn("{s}: the table at {d} is not where the computed layout puts it; a table before it has more slots than the cpp_virtuals lists give", .{ @typeName(C), t.offset });
            return error.VtableMismatch;
        }
    }
    inline for (t.slots, 0..) |s, si| {
        if (s.kind != .method) continue;
        if (s.pure) {
            if (slots[si] != @intFromPtr(pureCall())) {
                log.warn("{s}: slot {d} of the table at {d} does not hold the pure {s}::{s}; check the cpp_virtuals of {s} and its bases", .{ @typeName(C), si, t.offset, comptime cppName(s.owner), s.sig.name, @typeName(C) });
                return error.VtableMismatch;
            }
        } else if (s.this_offset == t.offset and slots[si] != @intFromPtr(definition(s))) {
            log.warn("{s}: slot {d} of the table at {d} does not hold {s}::{s}; check the cpp_virtuals of {s} and its bases", .{ @typeName(C), si, t.offset, comptime cppName(s.owner), s.sig.name, @typeName(C) });
            return error.VtableMismatch;
        }
    }
}

const log = std.log.scoped(.cpp_bindgen);

fn cppName(comptime T: type) []const u8 {
    return ctype.pathKey(ctype.fromZig(T).named.path);
}

/// The symbol holding table `ti` of `C`, and the word of it where the
/// vtable pointer points. MSVC gives each table a symbol of its own;
/// Itanium puts them all in one, each after a two-word header.
fn symbolOf(comptime C: type, comptime ti: usize) struct { name: []const u8, start: comptime_int } {
    const ts = tables(C);
    if (msvc) return .{ .name = msvcSymbol("??_7", C, ti), .start = 0 };
    var start = 2;
    for (ts[0..ti]) |t| start += t.slots.len + 2;
    return .{ .name = "_ZTV" ++ itanium_mangle.typeName(ctype.fromZig(C)), .start = start };
}

/// The RTTI the header of table `ti` of `C` points at: on MSVC that
/// table's complete object locator, on Itanium the class's typeinfo.
pub fn rttiSymbol(comptime C: type, comptime ti: usize) []const u8 {
    if (msvc) return msvcSymbol("??_R4", C, ti);
    return "_ZTI" ++ itanium_mangle.typeName(ctype.fromZig(C));
}

fn msvcSymbol(comptime prefix: []const u8, comptime C: type, comptime ti: usize) []const u8 {
    var path: []const []const ctype.Component = &.{};
    for (tables(C)[ti].msvc_path) |K| path = path ++ &[_][]const ctype.Component{ctype.fromZig(K).named.path};
    return msvc_mangle.vfptrSymbol(prefix, ctype.fromZig(C).named.path, path);
}

/// What a pure virtual function's slot holds: the C++ runtime's handler,
/// which reports the call and aborts.
pub fn pureCall() *const fn () callconv(.c) void {
    return @extern(*const fn () callconv(.c) void, .{ .name = if (msvc) "_purecall" else "__cxa_pure_virtual" });
}

/// The owner's own definition of a slot's function: the symbol `cpp.bind`
/// would call.
pub fn definition(comptime s: Slot) *const fn () callconv(.c) void {
    const d = comptime blk: {
        var d = s.sig;
        d.this = if (isConst(s.sig)) *const s.owner else *s.owner;
        d.class = null;
        d.access = s.access;
        break :blk d;
    };
    return @extern(*const fn () callconv(.c) void, .{ .name = cpp.mangledName(cpp.default_mangling, d) });
}

/// Each entry is one of `C`'s own declarations, spelled so that binding it
/// reaches the same function.
fn checkList(comptime C: type, comptime list: []const Signature) void {
    const vdtor = @hasDecl(C, "cpp_virtual_dtor") and C.cpp_virtual_dtor;
    for (list, 0..) |s, i| {
        const where = @typeName(C) ++ ".cpp_virtuals, " ++ (if (isNameMarker(s)) "firstNamed(\"" ++ s.name ++ "\")" else s.name) ++ ": ";
        if (std.mem.indexOf(u8, s.name, "::") != null)
            @compileError(where ++ "use the bare name; the class is the one declaring cpp_virtuals");
        if (isNameMarker(s)) {
            for (list[0..i]) |e| if (std.mem.eql(u8, groupName(e), s.name))
                @compileError(where ++ "the name is already declared earlier in the list; the marker goes where the header first declares it");
            const later = for (list[i + 1 ..]) |e| {
                if (!isNameMarker(e) and std.mem.eql(u8, groupName(e), s.name)) break true;
            } else false;
            if (!later) @compileError(where ++ "no virtual function after it has this name, so it marks nothing");
            continue;
        }
        const Self = s.this orelse
            @compileError(where ++ "a virtual function has a `this`; set it to *" ++ @typeName(C) ++ " or *const " ++ @typeName(C));
        const info = @typeInfo(Self);
        if (info != .pointer or info.pointer.size != .one or info.pointer.child != C)
            @compileError(where ++ "`this` is " ++ @typeName(Self) ++ "; cpp_virtuals lists only " ++ @typeName(C) ++ "'s own declarations, so it must be *" ++ @typeName(C) ++ " or *const " ++ @typeName(C));
        if (s.class) |K| if (K != C)
            @compileError(where ++ ".class names " ++ @typeName(K) ++ "; cpp_virtuals lists only " ++ @typeName(C) ++ "'s own declarations");
        if (s.template_args.len != 0) @compileError(where ++ "a function template cannot be virtual");
        if (std.mem.eql(u8, s.name, "*")) @compileError(where ++ "a constructor cannot be virtual");
        if (isDtor(s)) {
            if (!vdtor) @compileError(where ++ "the destructor is listed, so it is virtual; declare cpp_virtual_dtor = true");
        } else if (!s.virtual and !s.pure) {
            @compileError(where ++ "set .virtual = true: MSVC mangles a virtual method differently, so this Signature would bind the wrong symbol");
        }
        for (list[0..i]) |e| if (!isNameMarker(e) and sameVirtual(e, s))
            @compileError(where ++ "listed twice");
    }
}

// Every expectation below was read off `clang -fdump-vtable-layouts` for the
// same C++ on x86_64-windows-msvc and x86_64-windows-gnu. Slots are counted
// from where the vtable pointer points: MSVC's RTTI locator and Itanium's
// offset-to-top and typeinfo come before slot 0. The classes are in namespace `vt`:
// test/vtable_fixture.cpp defines them and src/vtable_fixture.zig binds them,
// so the tests at the end also check every layout against the real vtables.

const fx = @import("vtable_fixture.zig");
const virt = fx.virt;
const dtorOf = fx.dtorOf;
const Node = fx.Node;
const Cam = fx.Cam;
const Mid = fx.Mid;
const Leaf = fx.Leaf;
const In = fx.In;
const Out = fx.Out;
const App = fx.App;
const Mix = fx.Mix;
const NoDtor = fx.NoDtor;
const Mix2 = fx.Mix2;
const Mix3 = fx.Mix3;
const B = fx.B;
const D1 = fx.D1;
const D2 = fx.D2;
const D3 = fx.D3;
const G = fx.G;
const Conv = fx.Conv;
const Pod = fx.Pod;
const P1 = fx.P1;
const P3 = fx.P3;
const P = fx.P;
const Q = fx.Q;
const PQ = fx.PQ;
const Top = fx.Top;
const L1 = fx.L1;
const L2 = fx.L2;
const Dia = fx.Dia;
const E1 = fx.E1;
const E2 = fx.E2;
const F = fx.F;
const Vec2 = fx.Vec2;
const Shape = fx.Shape;
const Square = fx.Square;
const BadNode = fx.BadNode;
const ShortApp = fx.ShortApp;

fn method(comptime sig: Signature, comptime owner: type) []const Slot {
    return &.{.{ .kind = .method, .sig = sig, .owner = owner }};
}

/// The destructor's slots: one on MSVC, two on Itanium.
fn dtors(comptime owner: type) []const Slot {
    const sig = dtorOf(owner);
    if (msvc) return &.{.{ .kind = .dtor_deleting, .sig = sig, .owner = owner }};
    return &.{ .{ .kind = .dtor_complete, .sig = sig, .owner = owner }, .{ .kind = .dtor_deleting, .sig = sig, .owner = owner } };
}

fn expectTable(comptime t: Table, comptime offset: comptime_int, comptime intro: type, comptime want: []const Slot) !void {
    if (comptime mismatch(t, offset, intro, want)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.TestUnexpectedResult;
    }
}

fn mismatch(comptime t: Table, comptime offset: comptime_int, comptime intro: type, comptime want: []const Slot) ?[]const u8 {
    if (t.offset != offset) return "the table is at " ++ ctype.decimal(t.offset) ++ ", expected " ++ ctype.decimal(offset);
    if (t.intro != intro) return "the table was introduced by " ++ @typeName(t.intro) ++ ", expected " ++ @typeName(intro);
    for (0..@max(want.len, t.slots.len)) |i| {
        const at = "slot " ++ ctype.decimal(i) ++ ": ";
        if (i >= t.slots.len) return at ++ "missing, expected " ++ want[i].sig.name;
        const s = t.slots[i];
        if (i >= want.len) return at ++ s.sig.name ++ " is one too many";
        const w = want[i];
        if (s.kind != w.kind or !sameVirtual(s.sig, w.sig) or s.owner != w.owner)
            return at ++ @tagName(s.kind) ++ " " ++ s.sig.name ++ " owned by " ++ @typeName(s.owner) ++
                ", expected " ++ @tagName(w.kind) ++ " " ++ w.sig.name ++ " owned by " ++ @typeName(w.owner);
    }
    return null;
}

test "overloads: MSVC reverses each group, Itanium keeps declaration order" {
    const node = comptime tables(Node);
    try std.testing.expectEqual(1, node.len);
    try expectTable(node[0], 0, Node, if (msvc)
        dtors(Node) ++ method(Node.customDraw, Node) ++ method(Node.customDraw_r, Node) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node)
    else
        dtors(Node) ++ method(Node.customDraw_r, Node) ++ method(Node.customDraw, Node) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node));

    const cam = comptime tables(Cam);
    try std.testing.expectEqual(1, cam.len);
    const inherited = comptime if (msvc)
        method(Node.customDraw, Node) ++ method(Node.customDraw_r, Node) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node)
    else
        method(Node.customDraw_r, Node) ++ method(Node.customDraw, Node) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node);
    try expectTable(cam[0], 0, Node, dtors(Cam) ++ inherited ++ if (msvc)
        method(Cam.begin_vp, Cam) ++ method(Cam.begin, Cam) ++ method(Cam.end, Cam)
    else
        method(Cam.begin, Cam) ++ method(Cam.begin_vp, Cam) ++ method(Cam.end, Cam));
}

test "a chain: an override two levels down keeps its slot, an implicit destructor owns its slots" {
    const leaf = comptime tables(Leaf);
    try std.testing.expectEqual(1, leaf.len);
    try expectTable(leaf[0], 0, Node, dtors(Leaf) ++ (if (msvc)
        method(Node.customDraw, Node) ++ method(Node.customDraw_r, Node) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node) ++
            method(Cam.begin_vp, Leaf) ++ method(Cam.begin, Cam)
    else
        method(Node.customDraw_r, Node) ++ method(Node.customDraw, Node) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node) ++
            method(Cam.begin, Cam) ++ method(Cam.begin_vp, Leaf)) ++ method(Cam.end, Cam) ++ method(Leaf.zoom, Leaf));
    try std.testing.expect(comptime tables(Mid)[0].slots[0].owner == Mid);
}

test "two polymorphic bases: two tables, new virtuals in the first, the destructor in both" {
    const app = comptime tables(App);
    try std.testing.expectEqual(2, app.len);
    try expectTable(app[0], 0, In, dtors(App) ++ method(In.audioIn, In) ++ method(App.update, App));
    try expectTable(app[1], 8, Out, dtors(App) ++ method(Out.audioOut, Out));
}

test "an override of a secondary base's virtual: a new primary slot on Itanium only" {
    const mix = comptime tables(Mix);
    try std.testing.expectEqual(2, mix.len);
    try expectTable(mix[0], 0, In, dtors(Mix) ++ method(In.audioIn, In) ++
        (if (msvc) &[_]Slot{} else method(Mix.audioOut, Mix)) ++ method(Mix.update, Mix));
    try expectTable(mix[1], 8, Out, dtors(Mix) ++ method(Out.audioOut, Mix));
}

test "a destructor only a secondary base made virtual: Itanium gives it primary slots, an implicit one last" {
    const mix2 = comptime tables(Mix2);
    try expectTable(mix2[0], 0, NoDtor, if (msvc)
        method(NoDtor.a, NoDtor) ++ method(Mix2.u, Mix2)
    else
        method(NoDtor.a, NoDtor) ++ dtors(Mix2) ++ method(Mix2.u, Mix2));
    try expectTable(mix2[1], 8, Out, dtors(Mix2) ++ method(Out.audioOut, Out));

    const mix3 = comptime tables(Mix3);
    try expectTable(mix3[0], 0, NoDtor, method(NoDtor.a, NoDtor) ++ method(Mix3.u, Mix3) ++ if (msvc) &[_]Slot{} else dtors(Mix3));
    try expectTable(mix3[1], 8, Out, dtors(Mix3) ++ method(Out.audioOut, Out));
}

test "MSVC places a group at the first declaration of its name, of any kind" {
    try expectTable(comptime tables(D1)[0], 0, B, dtors(D1) ++ method(B.f, B) ++ if (msvc)
        method(D1.g, D1) ++ method(D1.h, D1)
    else
        method(D1.h, D1) ++ method(D1.g, D1));
    try expectTable(comptime tables(D2)[0], 0, B, dtors(D2) ++ method(B.f, D2) ++ if (msvc)
        method(D2.f_int, D2) ++ method(D2.k, D2)
    else
        method(D2.k, D2) ++ method(D2.f_int, D2));
    try expectTable(comptime tables(D3)[0], 0, B, dtors(D3) ++ method(B.f, B) ++ if (msvc)
        method(D3.f_int, D3) ++ method(D3.k, D3)
    else
        method(D3.k, D3) ++ method(D3.f_int, D3));
}

test "a destructor declared after other virtuals takes its place in the order" {
    try expectTable(comptime tables(G)[0], 0, G, if (msvc)
        method(G.a, G) ++ method(G.a_int, G) ++ dtors(G) ++ method(G.b, G)
    else
        method(G.a_int, G) ++ dtors(G) ++ method(G.b, G) ++ method(G.a, G));
}

test "conversion operators to different types are different names" {
    try std.testing.expect(!sameVirtual(Conv.to_int, Conv.to_float));
    try expectTable(comptime tables(Conv)[0], 0, Conv, method(Conv.to_int, Conv) ++ method(Conv.v, Conv) ++ method(Conv.to_float, Conv));
}

test "non-polymorphic bases: the class's own table, or the polymorphic base's wherever it was declared" {
    const p1 = comptime tables(P1);
    try std.testing.expectEqual(1, p1.len);
    try expectTable(p1[0], 0, P1, dtors(P1) ++ method(P1.f, P1));

    const p3 = comptime tables(P3);
    try std.testing.expectEqual(1, p3.len);
    try expectTable(p3[0], 0, Node, dtors(P3) ++ (if (msvc)
        method(Node.customDraw, Node) ++ method(Node.customDraw_r, Node)
    else
        method(Node.customDraw_r, Node) ++ method(Node.customDraw, Node)) ++ method(Node.draw, Node) ++ method(Node.onChanged, Node) ++ method(P3.extra, P3));
}

test "nested multiple inheritance: a base's own tables move with it" {
    const top = comptime tables(Top);
    try std.testing.expectEqual(3, top.len);
    try expectTable(top[0], 0, In, dtors(Top) ++ method(In.audioIn, In) ++
        (if (msvc) &[_]Slot{} else method(Top.q, Top) ++ method(Top.p, Top)) ++ method(Top.t, Top));
    try expectTable(top[1], 8, P, method(P.p, Top) ++ (if (msvc) &[_]Slot{} else method(PQ.q, Top)) ++ method(PQ.pq, PQ));
    try expectTable(top[2], 16, Q, method(Q.q, Top));
}

test "parameters are compared as C++ types" {
    const a = virt(*Node, "f", &.{*c_int}, void);
    const b = virt(*Cam, "f", &.{[*c]c_int}, void);
    const c = virt(*const Cam, "f", &.{[*c]c_int}, void);
    try std.testing.expect(sameVirtual(a, b));
    try std.testing.expect(!sameVirtual(a, c));
    try std.testing.expect(sameVirtual(dtorOf(Node), dtorOf(Cam)));
    try std.testing.expect(!isNameMarker(a));
    try std.testing.expect(isNameMarker(firstNamed("f")));
}

test "MSVC names a table by the bases that tell it apart" {
    if (!msvc) return error.SkipZigTest;
    const names = comptime blk: {
        var out: []const []const u8 = &.{};
        for (.{ App, Top, Dia, F }) |C| for (0..tables(C).len) |ti| {
            out = out ++ &[_][]const u8{symbolOf(C, ti).name};
        };
        break :blk out;
    };
    const want = [_][]const u8{
        "??_7App@vt@@6BIn@1@@",    "??_7App@vt@@6BOut@1@@",
        "??_7Top@vt@@6B@",         "??_7Top@vt@@6BP@1@@",
        "??_7Top@vt@@6BQ@1@@",     "??_7Dia@vt@@6BL1@1@@",
        "??_7Dia@vt@@6BL2@1@@",    "??_7F@vt@@6BL1@1@E1@1@@",
        "??_7F@vt@@6BL2@1@E1@1@@", "??_7F@vt@@6BL1@1@E2@1@@",
        "??_7F@vt@@6BL2@1@E2@1@@",
    };
    try std.testing.expectEqual(want.len, names.len);
    for (want, names) |w, n| try std.testing.expectEqualStrings(w, n);
}

// Against the vtables clang emitted.

test "verify: every layout above matches the vtables clang emitted" {
    inline for (.{ Node, Cam, Mid, Leaf, In, Out, App, Mix, NoDtor, Mix2, Mix3, B, D1, D2, D3, G, Conv, P1, P3, P, Q, PQ, Top, L1, L2, Dia, E1, E2, F, Shape, Square, fx.Talker, fx.Duo, fx.Abstract, fx.Concrete, fx.PureOut, fx.Plug, fx.Lamp, fx.Guarded }) |C| {
        verify(C) catch |err| {
            std.debug.print("{s}\n", .{@typeName(C)});
            return err;
        };
    }
}

test "verify: a misordered list is caught, and a short table only where its length shows" {
    try std.testing.expectError(error.VtableMismatch, verify(BadNode));
    // Itanium's next table header shows where the first table ends; MSVC
    // records no table's length anywhere.
    if (msvc) try verify(ShortApp) else try std.testing.expectError(error.VtableMismatch, verify(ShortApp));
}

fn construct(comptime T: type, obj: *T) void {
    cpp.bind(.{ .name = "*", .this = *T })(obj);
}

fn destroy(comptime T: type, obj: *T) void {
    cpp.bind(.{ .name = "~", .this = *T })(obj);
}

test "bindVirtual reaches the override that bind skips" {
    var leaf: Leaf = undefined;
    construct(Leaf, &leaf);
    defer destroy(Leaf, &leaf);
    const cam = cpp.basePtr(Cam, &leaf);

    try std.testing.expectEqual(1004, cpp.bind(Cam.begin_vp)(cam, 4));
    try std.testing.expectEqual(2004, cpp.bindVirtual(Cam.begin_vp)(cam, 4));
    // The same call spelled through the derived pointer, by the base's name.
    const via_leaf: Signature = .{ .name = "begin", .class = Cam, .this = *Leaf, .args = &.{c_int}, .ret = c_int, .virtual = true };
    try std.testing.expectEqual(2004, cpp.bindVirtual(via_leaf)(&leaf, 4));
    // A const slot, and Leaf's own new one.
    try std.testing.expectEqual(105, cpp.bindVirtual(Node.customDraw_r)(cpp.basePtr(Node, &leaf), 5));
    try std.testing.expectEqual(2100, cpp.bindVirtual(Leaf.zoom)(&leaf));
}

test "bindVirtual through a second vtable moves `this` to it" {
    var app: App = undefined;
    construct(App, &app);
    defer destroy(App, &app);
    try std.testing.expectEqual(12, cpp.bindVirtual(Out.audioOut)(cpp.basePtr(Out, &app), 4));
    const by_name: Signature = .{ .name = "audioOut", .class = Out, .this = *App, .args = &.{c_int}, .ret = c_int, .virtual = true };
    try std.testing.expectEqual(12, cpp.bindVirtual(by_name)(&app, 4));
    try std.testing.expectEqual(7, cpp.bindVirtual(App.update)(&app));

    // Itanium gives Mix::audioOut a slot in the first table too; the call
    // takes it, and the override reads a member, so its `this` must be right.
    var mix: Mix = undefined;
    construct(Mix, &mix);
    defer destroy(Mix, &mix);
    try std.testing.expectEqual(13, cpp.bindVirtual(Mix.audioOut)(&mix, 4));
    try std.testing.expectEqual(13, cpp.bindVirtual(Out.audioOut)(cpp.basePtr(Out, &mix), 4));

    var top: Top = undefined;
    construct(Top, &top);
    defer destroy(Top, &top);
    try std.testing.expectEqual(30, cpp.bindVirtual(Top.p)(&top));
    try std.testing.expectEqual(31, cpp.bindVirtual(Top.q)(&top));
    try std.testing.expectEqual(31, cpp.bindVirtual(Q.q)(cpp.basePtr(Q, &top)));
    try std.testing.expectEqual(22, cpp.bindVirtual(PQ.pq)(cpp.basePtr(PQ, &top)));
}

test "bindVirtual handles the call shapes bind wraps" {
    var sq: Square = undefined;
    construct(Square, &sq);
    defer destroy(Square, &sq);
    const shape = cpp.basePtr(Shape, &sq);
    // MSVC returns Vec2 from a member function through a hidden pointer.
    const p = cpp.bindVirtual(Shape.pos)(shape);
    try std.testing.expectEqual(40, p.x);
    try std.testing.expectEqual(40, p.y);
    try std.testing.expectEqual(4, cpp.bind(Shape.pos)(shape).x);
    const scale: Vec2 = .{ .x = 2, .y = 3 };
    try std.testing.expectEqual(97, cpp.bindVirtual(Shape.area)(shape, &scale));
    try std.testing.expectEqual(96, cpp.bind(Shape.area)(shape, &scale));
}

test "bindVirtual has bind's type" {
    inline for (.{ Cam.begin_vp, Node.customDraw_r, Out.audioOut, Shape.pos, Shape.area }) |sig| {
        try std.testing.expect(@TypeOf(cpp.bindVirtual(sig)) == @TypeOf(cpp.bind(sig)));
    }
}
