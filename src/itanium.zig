//! Itanium C++ ABI name mangling (GCC/Clang, including `*-windows-gnu`).
//! https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangling
const std = @import("std");
const ctype = @import("ctype.zig");
const CType = ctype.CType;
const Component = ctype.Component;

/// Substitution table (`S_`, `S0_`, ...), keyed by `CType.key` / `pathKey`.
const Subs = struct {
    keys: []const []const u8 = &.{},

    fn find(comptime s: Subs, comptime k: []const u8) ?usize {
        inline for (s.keys, 0..) |existing, i| if (std.mem.eql(u8, existing, k)) return i;
        return null;
    }

    fn add(comptime s: *Subs, comptime k: []const u8) void {
        if (s.find(k) == null) s.keys = s.keys ++ &[_][]const u8{k};
    }

    fn ref(comptime idx: usize) []const u8 {
        if (idx == 0) return "S_";
        return "S" ++ base36(idx - 1) ++ "_";
    }

    fn base36(comptime n: usize) []const u8 {
        const digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        if (n < 36) return digits[n .. n + 1];
        return base36(n / 36) ++ digits[n % 36 .. n % 36 + 1];
    }
};

pub fn mangle(comptime f: ctype.Function) []const u8 {
    @setEvalBranchQuota(1 << 20);
    comptime var subs = Subs{};
    comptime var out: []const u8 = "_Z";

    if (f.this != null and f.path.len < 2) @compileError("a member function needs a class in its name: '" ++ ctype.pathKey(f.path) ++ "'");
    if (f.path[f.path.len - 1].args.len > 0) @compileError("function templates are not supported: '" ++ ctype.pathKey(f.path) ++ "'");

    if (f.path.len == 1) {
        out = out ++ sourceName(f.path[0].name);
    } else {
        out = out ++ "N";
        if (f.this) |t| if (t.is_const) {
            out = out ++ "K";
        };
        out = out ++ switch (f.special) {
            .none => qualified(f.path, false, &subs),
            .ctor => qualified(f.path[0 .. f.path.len - 1], true, &subs) ++ ctorVariant(f),
            .dtor => qualified(f.path[0 .. f.path.len - 1], true, &subs) ++ dtorVariant(f),
        };
        out = out ++ "E";
    }

    if (f.params.len == 0) {
        out = out ++ "v";
    } else {
        inline for (f.params) |p| out = out ++ mangleType(p, &subs);
    }
    return out;
}

/// C1 is the complete-object constructor, C2 the base-object one. They differ
/// only for a class with virtual bases, and only C2 is emitted for a class
/// whose constructor is defined inline in a header: a compiler that sees no
/// virtual bases calls C2 directly and never materialises C1. C2 is therefore
/// the variant present in every translation unit that defines the class, so
/// bind it unless virtual bases make the distinction real.
fn ctorVariant(comptime f: ctype.Function) []const u8 {
    return if (f.virtual_bases) "C1" else "C2";
}

/// D1 is the complete-object destructor, D2 the base-object one. See
/// `ctorVariant`; D0, the deleting destructor, is never what a bound call wants.
fn dtorVariant(comptime f: ctype.Function) []const u8 {
    return if (f.virtual_bases) "D1" else "D2";
}

fn sourceName(comptime name: []const u8) []const u8 {
    return ctype.decimal(name.len) ++ name;
}

/// `glm::vec` for a prefix ending in `glm::vec<...>`.
fn templateNameKey(comptime path: []const Component) []const u8 {
    const last = path[path.len - 1];
    if (path.len == 1) return last.name;
    return ctype.pathKey(path[0 .. path.len - 1]) ++ "::" ++ last.name;
}

/// `<prefix>` chain, substituting the longest seen prefix. Registers each
/// prefix; the full path only when `register_last` (types, not functions).
fn qualified(comptime path: []const Component, comptime register_last: bool, comptime subs: *Subs) []const u8 {
    comptime var out: []const u8 = "";
    comptime var start: usize = 0;
    comptime var i = path.len;
    scan: inline while (i > 0) : (i -= 1) {
        if (subs.find(ctype.pathKey(path[0..i]))) |idx| {
            out = Subs.ref(idx);
            start = i;
            break :scan;
        }
        if (path[i - 1].args.len > 0) {
            if (subs.find(templateNameKey(path[0..i]))) |idx| {
                out = Subs.ref(idx) ++ templateArgs(path[i - 1].args, subs);
                if (i < path.len or register_last) subs.add(ctype.pathKey(path[0..i]));
                start = i;
                break :scan;
            }
        }
    }
    inline for (path[start..], start..) |c, j| {
        out = out ++ sourceName(c.name);
        if (c.args.len > 0) {
            subs.add(templateNameKey(path[0 .. j + 1]));
            out = out ++ templateArgs(c.args, subs);
        }
        if (j + 1 < path.len or register_last) subs.add(ctype.pathKey(path[0 .. j + 1]));
    }
    return out;
}

fn templateArgs(comptime args: []const ctype.Arg, comptime subs: *Subs) []const u8 {
    comptime var out: []const u8 = "I";
    inline for (args) |a| out = out ++ switch (a) {
        .type => |t| mangleType(t, subs),
        .integral => |v| "L" ++ mangleType(v.type, subs) ++ literal(v.value) ++ "E",
    };
    return out ++ "E";
}

fn literal(comptime v: i64) []const u8 {
    return if (v < 0) "n" ++ ctype.decimal(@intCast(-v)) else ctype.decimal(@intCast(v));
}

fn mangleType(comptime t: CType, comptime subs: *Subs) []const u8 {
    switch (t) {
        .builtin => |b| return builtinCode(b),
        .pointer => |p| return indirect("P", t, p.child, p.is_const, subs),
        .reference => |r| return indirect(if (r.rvalue) "O" else "R", t, r.child, r.is_const, subs),
        .named => |n| {
            if (subs.find(t.key())) |idx| return Subs.ref(idx);
            if (n.path.len == 1) return qualified(n.path, true, subs);
            return "N" ++ qualified(n.path, true, subs) ++ "E";
        },
    }
}

/// `<P|R|O> [K] <child>`; the const child and the whole type are candidates.
fn indirect(comptime prefix: []const u8, comptime whole: CType, comptime child: *const CType, comptime is_const: bool, comptime subs: *Subs) []const u8 {
    if (subs.find(whole.key())) |idx| return Subs.ref(idx);
    comptime var inner: []const u8 = undefined;
    if (is_const) {
        const const_key = child.key() ++ " const";
        if (subs.find(const_key)) |idx| {
            inner = Subs.ref(idx);
        } else {
            inner = "K" ++ mangleType(child.*, subs);
            subs.add(const_key);
        }
    } else {
        inner = mangleType(child.*, subs);
    }
    const out = prefix ++ inner;
    subs.add(whole.key());
    return out;
}

fn builtinCode(comptime b: ctype.Builtin) []const u8 {
    return switch (b) {
        .void => "v",
        .bool => "b",
        .char => "c",
        .schar => "a",
        .uchar => "h",
        .short => "s",
        .ushort => "t",
        .int => "i",
        .uint => "j",
        .long => "l",
        .ulong => "m",
        .longlong => "x",
        .ulonglong => "y",
        .float => "f",
        .double => "d",
        .longdouble => "e",
        .wchar_t => "w",
        .char16_t => "Ds",
        .char32_t => "Di",
    };
}

test "substitution refs" {
    try std.testing.expectEqualStrings("S_", comptime Subs.ref(0));
    try std.testing.expectEqualStrings("S0_", comptime Subs.ref(1));
    try std.testing.expectEqualStrings("S9_", comptime Subs.ref(10));
    try std.testing.expectEqualStrings("SA_", comptime Subs.ref(11));
    try std.testing.expectEqualStrings("SZ_", comptime Subs.ref(36));
    try std.testing.expectEqualStrings("S10_", comptime Subs.ref(37));
}
