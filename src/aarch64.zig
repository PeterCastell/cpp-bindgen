//! Calls whose result pointer travels in x8. AAPCS64 passes the address a
//! function constructs its result in through x8 (`XR`), outside the argument
//! registers, and Itanium C++ takes that path for every class it returns
//! through a hidden pointer. No calling convention Zig can declare puts an
//! argument there, so such a call goes through `x8Call`.
//!
//! AAPCS64: https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst
//! ("Result return", and the parameter passing rules in stage C).
const std = @import("std");

/// Called as `fn (callee, ret, a0, a1, ...) callconv(.c)`, it moves `ret` to
/// x8, shifts the next six argument registers down by two, and branches to
/// `callee`. The branch is a tail call: the callee returns straight to the
/// caller of `x8Call`, which never touched the link register.
///
/// Floating-point and SIMD arguments sit in v0-v7, which nothing here moves,
/// and need not. A shift by two keeps an argument's register parity, which
/// AAPCS64 rule C.9 fixes for a 16-byte-aligned argument (an even register
/// first). The real call can therefore use at most six general registers,
/// `this` included: `checkFits` enforces it. x16 is the scratch register a
/// branch to a BTI landing pad may come from.
pub fn x8Call() callconv(.naked) void {
    asm volatile (
        \\mov x16, x0
        \\mov x8, x1
        \\mov x0, x2
        \\mov x1, x3
        \\mov x2, x4
        \\mov x3, x5
        \\mov x4, x6
        \\mov x5, x7
        \\br x16
    );
}

/// `callee(args...)`, with `args[0]`, the result pointer, moved to x8.
pub inline fn call(comptime Params: []const type, callee: *const anyopaque, args: @Tuple(Params)) void {
    const X8 = @Fn(&[_]type{*const anyopaque} ++ Params, &@splat(.{}), void, .{ .@"callconv" = .c });
    const f: *const X8 = @ptrCast(&x8Call);
    @call(.auto, f, .{callee} ++ args);
}

/// The other direction: an entry point for C++ to call, which takes the
/// result pointer from x8 and branches to `adapter`, a `callconv(.c)`
/// function of `(ret, pad, rest...)` whose second parameter it leaves
/// undefined. The padding keeps the shift at two, for the register parity
/// `x8Call` keeps too, so the same `max_gprs` bounds `rest`.
pub fn entryFromX8(comptime adapter: *const anyopaque) *const anyopaque {
    const S = struct {
        fn entry() callconv(.naked) void {
            asm volatile (
                \\mov x7, x5
                \\mov x6, x4
                \\mov x5, x3
                \\mov x4, x2
                \\mov x3, x1
                \\mov x2, x0
                \\mov x0, x8
                \\b %[adapter]
                :
                : [adapter] "X" (adapter),
            );
        }
    };
    return @ptrCast(&S.entry);
}

/// The most general registers the real call may use through `x8Call` or
/// `entryFromX8`.
pub const max_gprs = 6;

/// Rejects a call `x8Call` cannot forward: one whose arguments, as the C++
/// callee receives them, need more than `max_gprs` general registers, after
/// which they would spill to the stack, which shifting registers cannot fix.
pub fn checkFits(comptime name: []const u8, comptime params: []const type) void {
    comptime var n: usize = 0;
    inline for (params) |P| n += gprs(P);
    if (n > max_gprs) @compileError(name ++ ": returning a class through a hidden pointer on AArch64 allows " ++
        std.fmt.comptimePrint("{d}", .{max_gprs}) ++ " general-register arguments (`this` included), and this call needs " ++
        std.fmt.comptimePrint("{d}", .{n}));
}

/// The general registers one argument of type `T` takes under AAPCS64 stage
/// C: none for a float or a homogeneous floating-point aggregate (HFA),
/// which go in v registers; a pointer, in place of a composite over 16 bytes
/// (B.4); one or two for the rest.
fn gprs(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .float => 0,
        .int => |i| if (i.bits > 64) 2 else 1,
        .bool, .pointer, .optional, .@"enum" => 1,
        .@"struct", .@"union" => if (isHfa(T)) 0 else if (@sizeOf(T) > 16) 1 else (@sizeOf(T) + 7) / 8,
        else => @compileError(@typeName(T) ++ ": no AAPCS64 register count for this argument type"),
    };
}

/// One to four members, all the same floating-point type, nested or not.
fn isHfa(comptime T: type) bool {
    const leaves = floatLeaves(T) orelse return false;
    return leaves.count >= 1 and leaves.count <= 4;
}

const Leaves = struct { F: type, count: usize };

fn floatLeaves(comptime T: type) ?Leaves {
    switch (@typeInfo(T)) {
        .float => return .{ .F = T, .count = 1 },
        .array => |a| {
            const inner = floatLeaves(a.child) orelse return null;
            return .{ .F = inner.F, .count = inner.count * a.len };
        },
        .@"struct" => |s| {
            comptime var out: ?Leaves = null;
            inline for (s.field_types) |FT| {
                const inner = floatLeaves(FT) orelse return null;
                if (out) |o| {
                    if (o.F != inner.F) return null;
                    out = .{ .F = o.F, .count = o.count + inner.count };
                } else out = inner;
            }
            return out;
        },
        else => return null,
    }
}

test "register counts" {
    try std.testing.expectEqual(1, gprs(*anyopaque));
    try std.testing.expectEqual(0, gprs(f32));
    try std.testing.expectEqual(2, gprs(u128));
    try std.testing.expectEqual(0, gprs(extern struct { x: f32, y: f32, z: f32, w: f32 }));
    try std.testing.expectEqual(1, gprs(extern struct { x: f32, y: f32, z: f32, w: f32, v: f32 }));
    try std.testing.expectEqual(1, gprs(extern struct { a: [5]f32 }));
    try std.testing.expectEqual(2, gprs(extern struct { a: c_int, b: f64 }));
    try std.testing.expectEqual(1, gprs(extern struct { a: [3]u64 }));
}
