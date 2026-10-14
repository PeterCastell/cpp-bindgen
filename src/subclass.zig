//! Subclassing a C++ class from Zig, with no C++ of its own. A C++ compiler
//! does four things for a derived class, and each has a Zig counterpart here:
//!
//! - It emits the vtables. `Subclass` builds them at comptime, one `const`
//!   array per vtable of the base, with the slot layout `vtable.tables`
//!   computes. A slot holds an adapter for an override, a generated
//!   destructor, or else the base's own definition, the same symbol `bind`
//!   calls.
//! - It constructs: the base constructor, then its own vtable pointers over
//!   the base's. That is `init`.
//! - It compiles the overrides. On x86_64 a member function is the C
//!   calling convention with `this` first, so an adapter is a `callconv(.c)`
//!   function that finds the Zig object from `this` and calls the method.
//! - It destroys: its own destructor body, then the base destructor, which
//!   puts the base's vtables back before it runs; and frees the object when
//!   C++ deletes it.
//!
//! ```zig
//! const OrbitCam = struct {
//!     cpp: cpp.Subclass(of.Camera, OrbitCam, "cpp"),
//!     angle: f32 = 0,
//!
//!     pub const cpp_overrides = .{
//!         .{ of.Camera.begin_viewport, beginViewport },
//!     };
//!
//!     fn beginViewport(self: *OrbitCam, viewport: *const of.Rectangle) void { ... }
//! };
//!
//! var orbit: OrbitCam = .{ .cpp = undefined };
//! orbit.cpp.init();
//! defer orbit.cpp.deinit();
//! ```
//!
//! C++ never names the Zig type; it only holds a pointer to the base. So
//! the Zig class needs no slots of its own, and its RTTI is the base's:
//! `dynamic_cast` to the base or anything above it works, and `typeid`
//! names the base.
//!
//! An override takes what `bind` would give for the same signature, `this`
//! aside, and returns what it would return. A `.managed_copy` result comes
//! as an out-pointer to construct it in, as `bind` hands it back; a
//! `.managed_copy` argument as a pointer the method borrows, destroyed after
//! it returns (by the caller on Itanium, by the adapter on MSVC, which is the
//! callee there). A pure virtual function must be overridden, as it must in
//! C++. Virtual bases and `delete[]` from C++ are not supported.
const std = @import("std");
const builtin = @import("builtin");
const cpp = @import("root.zig");
const aarch64 = @import("aarch64.zig");
const vtable = @import("vtable.zig");

const Signature = cpp.Signature;

const msvc = builtin.target.abi == .msvc;

const Word = ?*const anyopaque;

/// The field a Zig type embeds to be a `Base` to C++. It has exactly
/// `Base`'s size and layout. `Outer` is the Zig type holding it, as the
/// field named `field`, and may be any struct.
///
/// `Outer` may declare:
///
/// - `cpp_overrides`: a tuple of `.{ signature, method }` pairs. The
///   signature is the virtual function's, from any class in the chain; it is
///   a list rather than a naming convention because C++ overloads virtual
///   functions and Zig has no overloading. The method takes `*Outer` (or
///   `*const Outer`) and then the parameters of `cpp.bind`'s function other
///   than `this`, and returns what it returns.
/// - `cpp_destroy(self: *Outer) void`: the destructor body. It runs before
///   the base destructor, as a C++ derived destructor's body does.
/// - `cpp_free(self: *Outer) void`: releases the memory when C++ deletes the
///   object. Without it, a `delete` from C++ panics, because Zig owns the
///   storage and C++ cannot know how it was allocated.
///
/// The base needs `cpp_virtuals` all the way down (see `vtable.zig`). A base
/// whose vtable was compiled without RTTI declares `cpp_no_rtti = true`.
pub fn Subclass(comptime Base: type, comptime Outer: type, comptime field: []const u8) type {
    return extern struct {
        base: Base,

        const Self = @This();
        const tabs = vtable.tables(Base);
        /// Words ahead of slot 0: MSVC's RTTI locator; Itanium's
        /// offset-to-top and typeinfo.
        const header = if (msvc) 1 else 2;

        /// Runs `Base()` and installs `Outer`'s vtables. In a safe build it
        /// first checks the vtables the constructor installed against the
        /// computed layout, and panics on a mismatch.
        pub fn init(self: *Self) void {
            self.initWith(.{ .name = "*", .this = *Base }, .{});
        }

        /// `init` through a constructor that takes arguments: `ctor` is its
        /// signature (`"*"`, with `this` a `*Base`) and `args` a tuple.
        pub fn initWith(self: *Self, comptime ctor: Signature, args: anytype) void {
            construct(self, ctor, args);
            if (std.debug.runtime_safety) vtable.verifyObject(Base, &self.base) catch
                @panic(@typeName(Base) ++ ": the vtable its constructor installed does not match its cpp_virtuals, or a base's; see the warning above");
            self.install();
        }

        /// `init`, but the check runs in every build and a mismatch is
        /// returned, after destroying the base again.
        pub fn initChecked(self: *Self) error{VtableMismatch}!void {
            construct(self, .{ .name = "*", .this = *Base }, .{});
            vtable.verifyObject(Base, &self.base) catch |err| {
                baseDestructor(&self.base);
                return err;
            };
            self.install();
        }

        /// Destroys an object Zig owns: `cpp_destroy`, then `~Base()`. Not
        /// for one C++ has already deleted.
        pub fn deinit(self: *Self) void {
            destroy(@fieldParentPtr(field, self));
        }

        fn construct(self: *Self, comptime ctor: Signature, args: anytype) void {
            comptime check();
            comptime {
                if (!std.mem.eql(u8, ctor.name, "*") or ctor.this != *Base)
                    @compileError(@typeName(Outer) ++ ": initWith takes a constructor of " ++ @typeName(Base) ++ ": name \"*\", this *" ++ @typeName(Base));
            }
            @call(.auto, cpp.bind(ctor), .{&self.base} ++ args);
        }

        fn install(self: *Self) void {
            inline for (tabs, 0..) |t, ti| {
                const vptr: *[*]const Word = @ptrFromInt(@intFromPtr(&self.base) + t.offset);
                vptr.* = Table(ti).words[header..];
            }
        }

        fn Table(comptime ti: usize) type {
            const t = tabs[ti];
            return struct {
                const words: [header + t.slots.len]Word = blk: {
                    var w: [header + t.slots.len]Word = undefined;
                    const rtti: Word = if (@hasDecl(Base, "cpp_no_rtti") and Base.cpp_no_rtti)
                        null
                    else
                        @extern(*const anyopaque, .{ .name = vtable.rttiSymbol(Base, ti) });
                    if (msvc) {
                        w[0] = rtti;
                    } else {
                        w[0] = @ptrFromInt(@as(usize, @bitCast(@as(isize, -t.offset))));
                        w[1] = rtti;
                    }
                    for (t.slots, 0..) |s, si| w[header + si] = entry(t, s);
                    break :blk w;
                };
            };
        }

        fn entry(comptime t: vtable.Table, comptime s: vtable.Slot) *const anyopaque {
            return switch (s.kind) {
                .dtor_complete => @ptrCast(&Destructors(t.offset).complete),
                .dtor_deleting => if (msvc) @ptrCast(&Destructors(t.offset).msvcDeleting) else @ptrCast(&Destructors(t.offset).deleting),
                .method => if (overrideOf(s.sig)) |i|
                    overrideEntry(t.offset, Outer.cpp_overrides[i][0], Outer.cpp_overrides[i][1])
                else if (s.this_offset == t.offset)
                    @ptrCast(vtable.definition(s))
                else
                    thunkEntry(t.offset, s),
            };
        }

        /// The Zig object, from the `this` a slot of the table at `off`
        /// receives: the base subobject that table belongs to.
        fn outerFrom(comptime off: comptime_int, this: usize) *Outer {
            const sub: *Self = @ptrFromInt(this - off);
            return @fieldParentPtr(field, sub);
        }

        /// The slot's C call, turned into a call of the Zig method: `this`
        /// becomes the `Outer`, a hidden return pointer receives the
        /// method's result and goes back to the caller, and on MSVC, where
        /// the callee owns them, `.managed_copy` arguments are destroyed
        /// once the method returns.
        fn overrideEntry(comptime off: comptime_int, comptime sig: Signature, comptime method: anytype) *const anyopaque {
            const shape = comptime cpp.calleeShape(cpp.default_mangling, sig);
            const own = comptime methodParams(shape);
            const Body = struct {
                inline fn run(c: anytype) shape.ret {
                    const self = outerFrom(off, @intFromPtr(c[shape.this_index]));
                    var args: @Tuple(own.types) = undefined;
                    inline for (own.visible, 0..) |v, k| args[k] = c[shape.from[v]];
                    if (shape.ret_index) |ri| {
                        if (shape.ret_visible)
                            @call(.auto, method, .{self} ++ args)
                        else
                            c[ri].* = @call(.auto, method, .{self} ++ args);
                        destroyArgs(shape, c);
                        return c[ri];
                    }
                    const r = @call(.auto, method, .{self} ++ args);
                    destroyArgs(shape, c);
                    return r;
                }
            };
            return entryFor(shape, Body);
        }

        inline fn destroyArgs(comptime shape: cpp.CalleeShape, c: anytype) void {
            inline for (shape.destroy) |v| cpp.bind(.{ .name = "~", .this = shape.visible_params[v] })(c[shape.from[v]]);
        }

        /// The method's parameters after `self`: `bind`'s, without `this`.
        fn methodParams(comptime shape: cpp.CalleeShape) struct { visible: []const usize, types: []const type } {
            var visible: []const usize = &.{};
            var types: []const type = &.{};
            for (shape.visible_params, 0..) |T, v| {
                if (v == shape.this_visible) continue;
                visible = visible ++ &[_]usize{v};
                types = types ++ &[_]type{T};
            }
            return .{ .visible = visible, .types = types };
        }

        /// A slot nothing overrides whose definition expects `this` at
        /// another subobject. C++ fills it with a thunk the binding cannot
        /// name, so this is one. The call passes through as it came.
        fn thunkEntry(comptime off: comptime_int, comptime s: vtable.Slot) *const anyopaque {
            const shape = comptime cpp.calleeShape(cpp.default_mangling, s.sig);
            const delta = s.this_offset - off;
            const F = @Fn(shape.params, &@splat(.{}), shape.ret, .{ .@"callconv" = .c });
            const Body = struct {
                inline fn run(c: anytype) shape.ret {
                    const def: *const F = @ptrCast(vtable.definition(s));
                    var moved = c;
                    const p = @intFromPtr(c[shape.this_index]);
                    moved[shape.this_index] = @ptrFromInt(if (delta >= 0) p + delta else p - (-delta));
                    if (shape.via_x8) {
                        aarch64.call(shape.params, @ptrCast(def), moved);
                        return moved[0];
                    }
                    return @call(.auto, def, moved);
                }
            };
            return entryFor(shape, Body);
        }

        fn Destructors(comptime off: comptime_int) type {
            return struct {
                const CompleteRet = if (cpp.abi.structors_return_this) *anyopaque else void;
                /// Returns `this` where the ABI says a complete destructor
                /// does (`abi.structors_return_this`). Clang ignores the
                /// value at a virtual call, but the ABI lets a caller use it.
                fn complete(this: *anyopaque) callconv(.c) CompleteRet {
                    destroy(outerFrom(off, @intFromPtr(this)));
                    if (CompleteRet != void) return this;
                }
                fn deleting(this: *anyopaque) callconv(.c) void {
                    const o = outerFrom(off, @intFromPtr(this));
                    destroy(o);
                    release(o);
                }
                /// MSVC's vector deleting destructor: bit 0 of `flags` frees
                /// the memory, bit 1 is an array `delete[]`.
                fn msvcDeleting(this: *anyopaque, flags: c_uint) callconv(.c) *anyopaque {
                    if (flags & 2 != 0) @panic("C++ used delete[] on " ++ @typeName(Outer) ++ " objects, which Subclass does not support");
                    const o = outerFrom(off, @intFromPtr(this));
                    destroy(o);
                    if (flags & 1 != 0) release(o);
                    return this;
                }
            };
        }

        /// What a C++ derived destructor does: its own body, then the base
        /// destructor, which puts the base's vtables back before it runs.
        fn destroy(o: *Outer) void {
            if (@hasDecl(Outer, "cpp_destroy")) Outer.cpp_destroy(o);
            baseDestructor(&@field(o, field).base);
        }

        /// `~Base()`. For a concrete base, through the destructor slot of
        /// `Base`'s own vtable rather than by name: an implicit destructor
        /// exists as a symbol only if some C++ called it, but the vtable
        /// always holds one. Itanium's first destructor slot is the
        /// complete-object destructor; MSVC's only one is the deleting
        /// destructor, which with no flags destroys without freeing.
        ///
        /// An abstract base is destroyed by name, through the base-object
        /// destructor (`bind`'s `"~"`): clang emits every other destructor
        /// of an abstract class, the ones its vtable holds included, as a
        /// trap, since C++ never calls them (`EmitDestructorBody` in clang's
        /// CGClass.cpp). An implicit one then needs the glue to exist:
        /// declare its `Signature`. A base whose destructor is not virtual
        /// has no slot, and is taken to have a trivial destructor.
        fn baseDestructor(b: *Base) void {
            const found = comptime destructorSlot();
            const at = found orelse return;
            if (comptime abstract()) {
                const access = comptime tabs[at.table].slots[at.slot].access;
                return cpp.bind(.{ .name = "~", .this = *Base, .access = access })(b);
            }
            const this: *anyopaque = @ptrFromInt(@intFromPtr(b) + tabs[at.table].offset);
            const slot = vtable.emitted(Base, at.table)[at.slot];
            if (msvc) {
                const deleting: *const fn (*anyopaque, c_uint) callconv(.c) ?*anyopaque = @ptrFromInt(slot);
                _ = deleting(this, 0);
            } else {
                const complete: *const fn (*anyopaque) callconv(.c) void = @ptrFromInt(slot);
                complete(this);
            }
        }

        fn abstract() bool {
            for (tabs) |t| for (t.slots) |s| if (s.pure) return true;
            return false;
        }

        /// The first destructor slot, the table at 0 first, so that no
        /// thunk is involved when that table has one.
        fn destructorSlot() ?struct { table: usize, slot: usize } {
            for (tabs, 0..) |t, ti| for (t.slots, 0..) |s, si| {
                if (s.kind != .method) return .{ .table = ti, .slot = si };
            };
            return null;
        }

        fn release(o: *Outer) void {
            if (@hasDecl(Outer, "cpp_free"))
                Outer.cpp_free(o)
            else
                @panic("C++ deleted a " ++ @typeName(Outer) ++ ", which declares no cpp_free");
        }

        fn overrideOf(comptime sig: Signature) ?usize {
            if (!@hasDecl(Outer, "cpp_overrides")) return null;
            inline for (Outer.cpp_overrides, 0..) |o, i| if (vtable.sameVirtual(o[0], sig)) return i;
            return null;
        }

        fn check() void {
            if (@FieldType(Outer, field) != Self)
                @compileError(@typeName(Outer) ++ "." ++ field ++ " is not this Subclass; pass the name of the field that holds it");
            // As instantiating an abstract class is in C++.
            for (tabs) |t| for (t.slots) |s| {
                if (s.kind == .method and s.pure and overrideOf(s.sig) == null)
                    @compileError(@typeName(Outer) ++ " must override " ++ s.sig.name ++ ", which " ++ @typeName(s.owner) ++ " declares pure; add it to cpp_overrides");
            };
            if (!@hasDecl(Outer, "cpp_overrides")) return;
            for (Outer.cpp_overrides, 0..) |o, i| {
                const sig: Signature = o[0];
                const where = @typeName(Outer) ++ ".cpp_overrides, " ++ sig.name ++ ": ";
                const slot = for (tabs) |t| {
                    if (for (t.slots) |s| {
                        if (s.kind == .method and vtable.sameVirtual(s.sig, sig)) break true;
                    } else false) break true;
                } else false;
                if (!slot) @compileError(where ++ "overrides no virtual function of " ++ @typeName(Base) ++ " or its bases, as their cpp_virtuals list them");
                for (0..i) |j| if (vtable.sameVirtual(Outer.cpp_overrides[j][0], sig))
                    @compileError(where ++ "overridden twice");
                checkMethod(where, sig, o[1]);
            }
        }

        fn checkMethod(comptime where: []const u8, comptime sig: Signature, comptime method: anytype) void {
            const shape = cpp.calleeShape(cpp.default_mangling, sig);
            const own = methodParams(shape).types;
            const info = @typeInfo(@TypeOf(method));
            if (info != .@"fn") @compileError(where ++ "the override is a " ++ @typeName(@TypeOf(method)) ++ ", not a function");
            const f = info.@"fn";
            const want = "fn (*" ++ @typeName(Outer) ++ typeList(own) ++ ") " ++ @typeName(shape.visible_ret);
            if (f.param_types.len != own.len + 1) @compileError(where ++ "the override should be " ++ want);
            const S = f.param_types[0] orelse @compileError(where ++ "the override should be " ++ want);
            if (S != *Outer and S != *const Outer) @compileError(where ++ "the override should be " ++ want);
            for (own, f.param_types[1..]) |p, q| if (q != p) @compileError(where ++ "the override should be " ++ want);
            if (f.return_type != shape.visible_ret) @compileError(where ++ "the override should be " ++ want);
        }

        fn typeList(comptime ts: []const type) []const u8 {
            var out: []const u8 = "";
            for (ts) |T| out = out ++ ", " ++ @typeName(T);
            return out;
        }
    };
}

/// `entryPoint` for a slot of `shape`. Where the hidden return pointer comes
/// in x8, an assembly entry moves it to the front, past a padding parameter
/// (see `aarch64.entryFromX8`), and the `callconv(.c)` function behind it
/// drops the padding before `Body.run` sees the arguments.
fn entryFor(comptime shape: cpp.CalleeShape, comptime Body: type) *const anyopaque {
    if (!shape.via_x8) return entryPoint(shape.params, shape.ret, Body);
    const P = shape.params;
    const Padded = struct {
        inline fn run(c: anytype) shape.ret {
            var args: @Tuple(P) = undefined;
            args[0] = c[0];
            inline for (1..P.len) |i| args[i] = c[i + 1];
            return Body.run(args);
        }
    };
    const adapter = entryPoint(P[0..1] ++ &[_]type{usize} ++ P[1..], shape.ret, Padded);
    return aarch64.entryFromX8(adapter);
}

/// A `callconv(.c)` function of `P` that hands its arguments to `Body.run`
/// as a tuple. A function body cannot take a generated parameter list, so
/// there is one entry point per arity, as `bind`'s wrappers have: up to ten
/// arguments besides `this` and a hidden return pointer.
fn entryPoint(comptime P: []const type, comptime R: type, comptime Body: type) *const anyopaque {
    const S = struct {
        fn c1(a: P[0]) callconv(.c) R {
            return Body.run(.{a});
        }
        fn c2(a: P[0], b: P[1]) callconv(.c) R {
            return Body.run(.{ a, b });
        }
        fn c3(a: P[0], b: P[1], c: P[2]) callconv(.c) R {
            return Body.run(.{ a, b, c });
        }
        fn c4(a: P[0], b: P[1], c: P[2], d: P[3]) callconv(.c) R {
            return Body.run(.{ a, b, c, d });
        }
        fn c5(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e });
        }
        fn c6(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g });
        }
        fn c7(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g, h });
        }
        fn c8(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g, h, i });
        }
        fn c9(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7], j: P[8]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g, h, i, j });
        }
        fn c10(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7], j: P[8], k: P[9]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g, h, i, j, k });
        }
        fn c11(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7], j: P[8], k: P[9], l: P[10]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g, h, i, j, k, l });
        }
        fn c12(a: P[0], b: P[1], c: P[2], d: P[3], e: P[4], g: P[5], h: P[6], i: P[7], j: P[8], k: P[9], l: P[10], m: P[11]) callconv(.c) R {
            return Body.run(.{ a, b, c, d, e, g, h, i, j, k, l, m });
        }
    };
    return switch (P.len) {
        1 => @ptrCast(&S.c1),
        2 => @ptrCast(&S.c2),
        3 => @ptrCast(&S.c3),
        4 => @ptrCast(&S.c4),
        5 => @ptrCast(&S.c5),
        6 => @ptrCast(&S.c6),
        7 => @ptrCast(&S.c7),
        8 => @ptrCast(&S.c8),
        9 => @ptrCast(&S.c9),
        10 => @ptrCast(&S.c10),
        11 => @ptrCast(&S.c11),
        12 => @ptrCast(&S.c12),
        else => @compileError("Subclass: a virtual function with more than ten parameters"),
    };
}

// Zig subclasses of the classes in test/vtable_fixture.cpp, driven from the
// C++ side, which only ever sees the C++ base.

const fx = @import("vtable_fixture.zig");
const gpa = std.testing.allocator;

test {
    // The MSVC test binary links no C++ runtime, but the RTTI of
    // test/vtable_fixture.cpp points at type_info's vftable, and its pure
    // virtuals at the runtime's handler. Nothing here calls either.
    comptime if (msvc) {
        @export(&type_info_vftable, .{ .name = "??_7type_info@@6B@" });
        @export(&purecall, .{ .name = "_purecall" });
    };
}
const type_info_vftable = [_]usize{ 0, 0 };
fn purecall() callconv(.c) void {
    @panic("pure virtual function called");
}

/// The rest of the library.
const lib = struct {
    const trace = cpp.bindFn(&.{}, c_int, "vt::read_trace");
    const begin = cpp.bindFn(&.{*fx.Cam}, c_int, "vt::drive_begin");
    const custom = cpp.bindFn(&.{*fx.Node}, c_int, "vt::drive_custom");
    const custom_r = cpp.bindFn(&.{ *const fx.Node, c_int }, c_int, "vt::drive_custom_r");
    const changed = cpp.bindFn(&.{*fx.Node}, c_int, "vt::drive_changed");
    const audio_out = cpp.bindFn(&.{ *fx.Out, c_int }, c_int, "vt::drive_audio_out");
    const mix_audio = cpp.bindFn(&.{ *fx.Mix, c_int }, c_int, "vt::drive_mix_audio");
    const update = cpp.bindFn(&.{*fx.App}, c_int, "vt::drive_update");
    const area = cpp.bindFn(&.{ *const fx.Shape, c_int, c_int }, c_int, "vt::drive_area");
    const pos_x = cpp.bindFn(&.{*const fx.Shape}, c_int, "vt::drive_pos_x");
    const a = cpp.bindFn(&.{*fx.NoDtor}, c_int, "vt::drive_a");
    const live_msgs = cpp.bindFn(&.{}, c_int, "vt::live_msgs");
    const say = cpp.bindFn(&.{ *const fx.Talker, c_int }, c_int, "vt::drive_say");
    const size = cpp.bindFn(&.{*const fx.Talker}, c_int, "vt::drive_size");
    const at = cpp.bindFn(&.{ *const fx.Talker, c_int, c_int }, c_int, "vt::drive_at");
    const have = cpp.bindFn(&.{*fx.Abstract}, c_int, "vt::drive_have");
    const need = cpp.bindFn(&.{*fx.Abstract}, c_int, "vt::drive_need");
    const po = cpp.bindFn(&.{*const fx.PureOut}, c_int, "vt::drive_po");
    const p = cpp.bindFn(&.{*fx.P}, c_int, "vt::drive_p");
    const q = cpp.bindFn(&.{*fx.Q}, c_int, "vt::drive_q");
    const g = cpp.bindFn(&.{*fx.Guarded}, c_int, "vt::drive_g");
    const delete_node = cpp.bindFn(&.{*fx.Node}, void, "vt::drive_delete_node");
    const delete_out = cpp.bindFn(&.{*fx.Out}, void, "vt::drive_delete_out");
    // Itanium only: the MSVC test binary has no C++ runtime to do these.
    const is_cam = cpp.bindFn(&.{*fx.Node}, bool, "vt::is_cam");
    const is_app = cpp.bindFn(&.{*fx.Out}, bool, "vt::is_app");
    const whole = cpp.bindFn(&.{*fx.Out}, *anyopaque, "vt::whole");
    const whole_p = cpp.bindFn(&.{*fx.P}, *anyopaque, "vt::whole_p");
    const type_name = cpp.bindFn(&.{*fx.Node}, [*c]const u8, "vt::type_name");
};

/// The header word just before slot 0: MSVC's RTTI locator, Itanium's
/// typeinfo.
fn rttiWord(obj: *const anyopaque) usize {
    const vptr: *const [*]const usize = @ptrCast(@alignCast(obj));
    return (vptr.* - 1)[0];
}

/// `rttiWord` of the table whose vtable pointer is `offset` into `obj`.
fn rttiWordAt(obj: *const anyopaque, offset: usize) usize {
    return rttiWord(@ptrFromInt(@intFromPtr(obj) + offset));
}

const ZigCam = struct {
    tag: u32 = 0xC0FFEE, // Zig state on both sides of the C++ object
    cpp: cpp.Subclass(fx.Cam, ZigCam, "cpp"),
    seen: std.ArrayList(c_int) = .empty,

    pub const cpp_overrides = .{
        .{ fx.Cam.begin_vp, beginViewport },
        .{ fx.Node.customDraw, customDraw },
    };

    fn beginViewport(self: *ZigCam, viewport: c_int) c_int {
        self.seen.append(gpa, viewport) catch @panic("out of memory");
        // "super" is the direct call bind makes.
        return cpp.bind(fx.Cam.begin_vp)(&self.cpp.base, viewport) + 1;
    }

    fn customDraw(self: *ZigCam) c_int {
        return @intCast(self.tag & 0xff);
    }

    pub fn cpp_destroy(self: *ZigCam) void {
        self.seen.deinit(gpa);
    }

    pub fn cpp_free(self: *ZigCam) void {
        gpa.destroy(self);
    }
};

test "C++ reaches the Zig overrides, and the base's own definitions stay" {
    const before = lib.trace();
    {
        var zc: ZigCam = .{ .cpp = undefined };
        zc.cpp.init();
        defer zc.cpp.deinit();
        const node = cpp.basePtr(fx.Node, &zc.cpp.base);

        // Cam::begin() calls begin(lens) virtually: the override runs, and
        // its super call reaches Cam::begin(int).
        try std.testing.expectEqual(1051, lib.begin(&zc.cpp.base));
        try std.testing.expectEqual(0xEE, lib.custom(node));
        // Not overridden: an out-of-line definition and a header-inline one.
        try std.testing.expectEqual(107, lib.custom_r(node, 7));
        try std.testing.expectEqual(400, lib.changed(node));
        // A virtual call from Zig reaches the override too.
        try std.testing.expectEqual(1005, cpp.bindVirtual(fx.Cam.begin_vp)(&zc.cpp.base, 4));
        try std.testing.expectEqualSlices(c_int, &.{ 50, 4 }, zc.seen.items);
        try std.testing.expectEqual(0xC0FFEE, zc.tag);
    }
    // deinit ran cpp_destroy (or the allocator reports the list leaked),
    // then ~Cam and ~Node.
    try std.testing.expectEqual(before + 11, lib.trace());
}

test "C++ deletes a heap object through its base" {
    const before = lib.trace();
    const zc = try gpa.create(ZigCam);
    zc.* = .{ .cpp = undefined };
    zc.cpp.init();
    _ = lib.begin(&zc.cpp.base); // gives cpp_destroy something to free
    lib.delete_node(cpp.basePtr(fx.Node, &zc.cpp.base));
    try std.testing.expectEqual(before + 11, lib.trace());
}

test "the RTTI is the base's" {
    var zc: ZigCam = .{ .cpp = undefined };
    zc.cpp.init();
    defer zc.cpp.deinit();
    var real: fx.Cam = undefined;
    cpp.bind(.{ .name = "*", .this = *fx.Cam })(&real);
    defer cpp.bind(.{ .name = "~", .this = *fx.Cam })(&real);
    try std.testing.expectEqual(rttiWord(&real), rttiWord(&zc.cpp.base));
    try std.testing.expect(rttiWord(&real) != 0);
    if (!msvc) {
        const node = cpp.basePtr(fx.Node, &zc.cpp.base);
        try std.testing.expect(lib.is_cam(node));
        try std.testing.expectEqualStrings("N2vt3CamE", std.mem.span(lib.type_name(node)));
    }
}

const ZigApp = struct {
    cpp: cpp.Subclass(fx.App, ZigApp, "cpp"),
    gain: c_int = 100,

    pub const cpp_overrides = .{
        .{ fx.Out.audioOut, audioOut },
        .{ fx.App.update, update },
    };

    fn audioOut(self: *ZigApp, v: c_int) c_int {
        return v * self.gain;
    }

    fn update(self: *ZigApp) c_int {
        return self.cpp.base.frames + 1;
    }

    pub fn cpp_free(self: *ZigApp) void {
        gpa.destroy(self);
    }
};

test "two vtables: the second receives its own `this`, and deletes through it" {
    const before = lib.trace();
    const za = try gpa.create(ZigApp);
    za.* = .{ .cpp = undefined };
    za.cpp.init();
    const out = cpp.basePtr(fx.Out, &za.cpp.base);
    try std.testing.expect(@intFromPtr(out) != @intFromPtr(&za.cpp.base));
    try std.testing.expectEqual(300, lib.audio_out(out, 3));
    try std.testing.expectEqual(8, lib.update(&za.cpp.base));

    var real: fx.App = undefined;
    cpp.bind(.{ .name = "*", .this = *fx.App })(&real);
    try std.testing.expectEqual(rttiWord(&real), rttiWord(&za.cpp.base));
    try std.testing.expectEqual(rttiWord(cpp.basePtr(fx.Out, &real)), rttiWord(out));
    cpp.bind(.{ .name = "~", .this = *fx.App })(&real);
    if (!msvc) {
        try std.testing.expect(lib.is_app(out));
        // dynamic_cast<void*> reads the second table's offset-to-top.
        try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&za.cpp.base)), lib.whole(out));
    }

    const mid = lib.trace();
    // `delete` through the Out pointer: the second table's destructor slot,
    // which has to find the whole object.
    lib.delete_out(out);
    try std.testing.expectEqual(mid + 11100, lib.trace());
    try std.testing.expectEqual(before + 2 * 11100, lib.trace());
}

/// Overrides nothing Mix inherits from Out: on Itanium, Out's table then
/// holds a thunk to Mix::audioOut, which Subclass makes itself.
const ZigMix = struct {
    cpp: cpp.Subclass(fx.Mix, ZigMix, "cpp"),
    pub const cpp_overrides = .{.{ fx.Mix.update, update }};
    fn update(_: *ZigMix) c_int {
        return 80;
    }
};

/// Overrides audioOut, which Itanium gives a slot in both tables.
const ZigMix2 = struct {
    cpp: cpp.Subclass(fx.Mix, ZigMix2, "cpp"),
    gain: c_int = 5,
    pub const cpp_overrides = .{.{ fx.Out.audioOut, audioOut }};
    fn audioOut(self: *ZigMix2, v: c_int) c_int {
        // Out's own member, through the C++ base: 3.
        return v * self.gain + cpp.basePtr(fx.Out, &self.cpp.base).gain;
    }
};

test "a slot that moves `this`, and an override with a slot in each table" {
    var m: ZigMix = .{ .cpp = undefined };
    m.cpp.init();
    defer m.cpp.deinit();
    try std.testing.expectEqual(13, lib.audio_out(cpp.basePtr(fx.Out, &m.cpp.base), 4));
    try std.testing.expectEqual(13, lib.mix_audio(&m.cpp.base, 4));
    try std.testing.expectEqual(80, cpp.bindVirtual(fx.Mix.update)(&m.cpp.base));

    var m2: ZigMix2 = .{ .cpp = undefined };
    m2.cpp.init();
    defer m2.cpp.deinit();
    try std.testing.expectEqual(23, lib.audio_out(cpp.basePtr(fx.Out, &m2.cpp.base), 4));
    try std.testing.expectEqual(23, lib.mix_audio(&m2.cpp.base, 4));
}

/// Built through a constructor with arguments. It leaves `pos` alone, which
/// keeps Shape's definition.
const ZigShape = struct {
    cpp: cpp.Subclass(fx.Shape, ZigShape, "cpp"),
    pub const cpp_overrides = .{.{ fx.Shape.area, area }};
    fn area(self: *const ZigShape, scale: *const fx.Vec2) c_int {
        return self.cpp.base.w * 1000 + scale.x * 10 + scale.y;
    }
};

test "a constructor with arguments, and a reference parameter" {
    var s: ZigShape = .{ .cpp = undefined };
    s.cpp.initWith(fx.Shape.ctor_wh, .{ 5, 6 });
    defer s.cpp.deinit();
    try std.testing.expectEqual(5023, lib.area(&s.cpp.base, 2, 3));
    try std.testing.expectEqual(5, lib.pos_x(&s.cpp.base));
}

const BadOuter = struct {
    cpp: cpp.Subclass(fx.BadNode, BadOuter, "cpp"),
};

test "a misordered cpp_virtuals is caught at construction" {
    const before = lib.trace();
    var b: BadOuter = .{ .cpp = undefined };
    try std.testing.expectError(error.VtableMismatch, b.cpp.initChecked());
    // The base was constructed, so it was destroyed again.
    try std.testing.expectEqual(before + 1, lib.trace());
}

/// vt::NoDtor, bound as if its vtable had no RTTI.
const NoRtti = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::NoDtor";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_polymorphic = true;
    pub const cpp_no_rtti = true;
    pub const a = fx.virt(*NoRtti, "a", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{a};
};

const ZigNoRtti = struct {
    cpp: cpp.Subclass(NoRtti, ZigNoRtti, "cpp"),
    pub const cpp_overrides = .{.{ NoRtti.a, a }};
    fn a(_: *ZigNoRtti) c_int {
        return 9;
    }
};

test "cpp_no_rtti leaves the RTTI word empty, and a trivial destructor alone" {
    var z: ZigNoRtti = .{ .cpp = undefined };
    z.cpp.init();
    defer z.cpp.deinit();
    try std.testing.expectEqual(9, lib.a(@ptrCast(&z.cpp.base)));
    try std.testing.expectEqual(0, rttiWord(&z.cpp.base));
}

/// Overrides one virtual of each by-value shape.
const ZigTalker = struct {
    cpp: cpp.Subclass(fx.Talker, ZigTalker, "cpp"),

    pub const cpp_overrides = .{
        .{ fx.Talker.say, say },
        .{ fx.Talker.size, size },
        .{ fx.Talker.at, at },
    };

    /// A `.managed_copy` result is built in place, as `bind` would hand it
    /// back; the argument is borrowed, and destroyed after the call.
    fn say(self: *const ZigTalker, out: *fx.Msg, m: *fx.Msg) void {
        cpp.bind(fx.Msg.ctor)(out, m.v * 2 + self.cpp.base.base);
    }

    fn size(_: *const ZigTalker) fx.Size {
        return .{ .w = 7, .h = 8 };
    }

    fn at(self: *const ZigTalker, p: fx.Vec2) fx.Vec2 {
        return .{ .x = p.x * 3, .y = p.y + self.cpp.base.base };
    }
};

test "by-value classes: results built where the caller wants them, arguments destroyed once" {
    const live = lib.live_msgs();
    var real: fx.Talker = undefined;
    cpp.bind(.{ .name = "*", .this = *fx.Talker })(&real);
    defer cpp.bind(.{ .name = "~", .this = *fx.Talker })(&real);
    try std.testing.expectEqual(6, lib.say(&real, 5));
    try std.testing.expectEqual(live, lib.live_msgs());

    var z: ZigTalker = .{ .cpp = undefined };
    z.cpp.init();
    defer z.cpp.deinit();
    // MSVC: a hidden return pointer after `this`, and the argument destroyed
    // by the adapter. Itanium: the return pointer before `this`, and the
    // argument destroyed by the caller.
    try std.testing.expectEqual(11, lib.say(&z.cpp.base, 5));
    try std.testing.expectEqual(live, lib.live_msgs());
    // `.trivial_copy`: through a hidden pointer on MSVC, in a register on Itanium.
    try std.testing.expectEqual(78, lib.size(&z.cpp.base));
    // A C struct both ways, returned through a hidden pointer on MSVC.
    try std.testing.expectEqual(604, lib.at(&z.cpp.base, 2, 3));

    // The same calls from Zig, through the vtable.
    var arg: fx.Msg = undefined;
    cpp.bind(fx.Msg.ctor)(&arg, 20);
    var out: fx.Msg = undefined;
    cpp.bindVirtual(fx.Talker.say)(&out, &z.cpp.base, &arg); // consumes `arg`
    try std.testing.expectEqual(41, out.v);
    cpp.bind(fx.Msg.dtor)(&out);
    try std.testing.expectEqual(live, lib.live_msgs());
    try std.testing.expectEqual(fx.Size{ .w = 7, .h = 8 }, cpp.bindVirtual(fx.Talker.size)(&z.cpp.base));
    try std.testing.expectEqual(fx.Vec2{ .x = 3, .y = 2 }, cpp.bindVirtual(fx.Talker.at)(&z.cpp.base, .{ .x = 1, .y = 1 }));
}

/// Overrides nothing: on Itanium, Talker's table holds a thunk to
/// Duo::say, a call with a hidden return pointer and a by-value argument,
/// which Subclass makes itself.
const ZigDuo = struct {
    cpp: cpp.Subclass(fx.Duo, ZigDuo, "cpp"),
};

test "a slot that moves `this`, for a by-value call" {
    var d: ZigDuo = .{ .cpp = undefined };
    d.cpp.init();
    defer d.cpp.deinit();
    const live = lib.live_msgs();
    const talker = cpp.basePtr(fx.Talker, &d.cpp.base);
    try std.testing.expectEqual(500, lib.say(talker, 5));
    try std.testing.expectEqual(live, lib.live_msgs());
    try std.testing.expectEqual(12, lib.size(talker));
    try std.testing.expectEqual(301, lib.at(talker, 2, 1));
}

const ZigAbstract = struct {
    cpp: cpp.Subclass(fx.Abstract, ZigAbstract, "cpp"),
    n: c_int = 60,
    pub const cpp_overrides = .{.{ fx.Abstract.need, need }};
    fn need(self: *ZigAbstract) c_int {
        return self.n;
    }
};

/// The pure function is the second base's.
const ZigPlug = struct {
    cpp: cpp.Subclass(fx.Plug, ZigPlug, "cpp"),
    pub const cpp_overrides = .{.{ fx.PureOut.po, po }};
    fn po(_: *const ZigPlug) c_int {
        return 7;
    }
};

test "pure virtuals: the Zig class supplies them" {
    const before = lib.trace();
    var z: ZigAbstract = .{ .cpp = undefined };
    // The constructor installs Abstract's own table, pure-call handler and
    // all; init checks that before replacing it.
    z.cpp.init();
    // Abstract::have() calls need() virtually.
    try std.testing.expectEqual(64, lib.have(&z.cpp.base));
    try std.testing.expectEqual(60, lib.need(&z.cpp.base));
    try std.testing.expectEqual(60, cpp.bindVirtual(fx.Abstract.need)(&z.cpp.base));
    z.cpp.deinit();
    try std.testing.expectEqual(before + 100000, lib.trace());

    var p: ZigPlug = .{ .cpp = undefined };
    p.cpp.init();
    defer p.cpp.deinit();
    try std.testing.expectEqual(7, lib.po(cpp.basePtr(fx.PureOut, &p.cpp.base)));
}

/// F's four tables were all introduced by P; MSVC names each, and its RTTI
/// locator, by the bases it came through. One override takes all four.
const ZigF = struct {
    cpp: cpp.Subclass(fx.F, ZigF, "cpp"),
    calls: c_int = 0,
    pub const cpp_overrides = .{.{ fx.P.p, p }};
    fn p(self: *ZigF) c_int {
        self.calls += 1;
        return 70 + self.calls;
    }
};

const ZigTop = struct {
    cpp: cpp.Subclass(fx.Top, ZigTop, "cpp"),
    pub const cpp_overrides = .{
        .{ fx.P.p, p },
        .{ fx.Q.q, q },
    };
    fn p(_: *ZigTop) c_int {
        return 90;
    }
    fn q(_: *ZigTop) c_int {
        return 91;
    }
};

test "nested multiple inheritance: each table carries its own RTTI, and an override reaches every one" {
    var real: fx.F = undefined;
    cpp.bind(.{ .name = "*", .this = *fx.F })(&real);
    var z: ZigF = .{ .cpp = undefined };
    z.cpp.init();
    defer z.cpp.deinit();
    const tabs = comptime vtable.tables(fx.F);
    try std.testing.expectEqual(4, tabs.len);
    inline for (tabs, 1..) |t, n| {
        try std.testing.expectEqual(rttiWordAt(&real, t.offset), rttiWordAt(&z.cpp.base, t.offset));
        const sub: *fx.P = @ptrFromInt(@intFromPtr(&z.cpp.base) + t.offset);
        try std.testing.expectEqual(70 + @as(c_int, n), lib.p(sub));
        if (!msvc) try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&z.cpp.base)), lib.whole_p(sub));
    }
    // MSVC: four locators, one per path.
    if (msvc) inline for (tabs, 0..) |a, i| inline for (tabs[i + 1 ..]) |b| {
        try std.testing.expect(rttiWordAt(&real, a.offset) != rttiWordAt(&real, b.offset));
    };

    var real_top: fx.Top = undefined;
    cpp.bind(.{ .name = "*", .this = *fx.Top })(&real_top);
    defer cpp.bind(.{ .name = "~", .this = *fx.Top })(&real_top);
    var top: ZigTop = .{ .cpp = undefined };
    top.cpp.init();
    defer top.cpp.deinit();
    inline for (comptime vtable.tables(fx.Top)) |t| {
        try std.testing.expectEqual(rttiWordAt(&real_top, t.offset), rttiWordAt(&top.cpp.base, t.offset));
    }
    try std.testing.expectEqual(90, lib.p(cpp.basePtr(fx.P, &top.cpp.base)));
    try std.testing.expectEqual(91, lib.q(cpp.basePtr(fx.Q, &top.cpp.base)));
    try std.testing.expectEqual(22, cpp.bindVirtual(fx.PQ.pq)(cpp.basePtr(fx.PQ, &top.cpp.base)));
}

/// OptLeaf's destructor is implicit and its library is optimized, so the
/// destructor is no symbol of its own; only the vtable reaches it.
const ZigOpt = struct {
    cpp: cpp.Subclass(fx.OptLeaf, ZigOpt, "cpp"),
    pub const cpp_overrides = .{.{ fx.Opt.f, f }};
    fn f(_: *ZigOpt) c_int {
        return 3;
    }
};

test "an implicit destructor in an optimized library is reached through the vtable" {
    const before = lib.trace();
    var o: ZigOpt = .{ .cpp = undefined };
    o.cpp.init();
    try std.testing.expectEqual(3, cpp.bindVirtual(fx.Opt.f)(cpp.basePtr(fx.Opt, &o.cpp.base)));
    o.cpp.deinit();
    try std.testing.expectEqual(before + 1000000, lib.trace());
}

/// Lamp's overrides are private and protected; the slots they fill hold
/// those definitions, which MSVC names with their own access.
const ZigLamp = struct {
    cpp: cpp.Subclass(fx.Lamp, ZigLamp, "cpp"),
};

/// Built through Guarded's protected constructor, and destroyed through its
/// protected destructor, by name, since Guarded is abstract.
const ZigGuarded = struct {
    cpp: cpp.Subclass(fx.Guarded, ZigGuarded, "cpp"),
    pub const cpp_overrides = .{.{ fx.Guarded.g, g }};
    fn g(self: *ZigGuarded) c_int {
        return self.cpp.base.k + 1;
    }
};

test "members that are not public: overrides, constructors and destructors" {
    var l: ZigLamp = .{ .cpp = undefined };
    l.cpp.init();
    defer l.cpp.deinit();
    const node = cpp.basePtr(fx.Node, &l.cpp.base);
    try std.testing.expectEqual(507, lib.custom_r(node, 7));
    try std.testing.expectEqual(501, lib.changed(node));

    const before = lib.trace();
    var z: ZigGuarded = .{ .cpp = undefined };
    z.cpp.initWith(fx.Guarded.ctor, .{});
    try std.testing.expectEqual(7, lib.g(&z.cpp.base));
    z.cpp.deinit();
    try std.testing.expectEqual(before + 10000000, lib.trace());
}
