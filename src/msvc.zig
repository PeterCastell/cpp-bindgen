//! MSVC name mangling. No official spec; follows Clang's MicrosoftMangle.cpp
//! and was checked against clang and cl.exe output for every fixture case.
const std = @import("std");
const builtin = @import("builtin");
const ctype = @import("ctype.zig");
const CType = ctype.CType;
const Component = ctype.Component;

const ptr64 = @sizeOf(usize) == 8;

/// Back-reference tables: the first ten names (a template-id counts as one)
/// and the first ten multi-character parameter types.
const State = struct {
    names: []const []const u8 = &.{},
    types: []const []const u8 = &.{},

    fn emitName(comptime s: *State, comptime name: []const u8, comptime spelled: []const u8) []const u8 {
        inline for (s.names, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) return ctype.decimal(i);
        }
        if (s.names.len < 10) s.names = s.names ++ &[_][]const u8{name};
        return spelled;
    }

    fn findType(comptime s: State, comptime k: []const u8) ?usize {
        inline for (s.types, 0..) |existing, i| if (std.mem.eql(u8, existing, k)) return i;
        return null;
    }
};

pub fn mangle(comptime f: ctype.Function) []const u8 {
    @setEvalBranchQuota(1 << 20);
    comptime var st = State{};
    if (f.this != null and f.path.len < 2) @compileError("a member function needs a class in its name: '" ++ ctype.pathKey(f.path) ++ "'");
    // MSVC writes a function template's signature with its template arguments
    // substituted in, unlike Itanium; `qualifiedName` already spells the
    // `?$name@args@` part, which the leading `?` turns into `??$`.
    const targs = f.path[f.path.len - 1].args;

    // Special names: ?0 ctor, ?1 dtor, ?_D complete dtor with virtual bases.
    const vbase_dtor = f.special == .dtor and f.virtual_bases;
    const special_name: ?[]const u8 = switch (f.special) {
        .none => null,
        .ctor => "?0",
        .dtor => if (vbase_dtor) "?_D" else "?1",
    };
    comptime var out: []const u8 = "?";
    if (special_name) |s| {
        out = out ++ s ++ qualifiedName(f.path[0 .. f.path.len - 1], &st);
    } else {
        out = out ++ functionName(f.path, &st);
    }

    if (f.this) |t| {
        // Q/U: public non-virtual/virtual; then __ptr64, this-cv, callconv
        // (__thiscall on x86, __cdecl elsewhere).
        const virt = f.is_virtual and !vbase_dtor;
        out = out ++ (if (virt) "U" else "Q") ++ (if (ptr64) "E" else "") ++ (if (t.is_const) "B" else "A");
        out = out ++ (if (builtin.cpu.arch == .x86) "E" else "A");
    } else if (f.is_static) {
        out = out ++ "SA";
    } else {
        out = out ++ "YA";
    }

    // Return slot: `@` for ctors/dtors, `?A` prefix for classes by value.
    const ret = comptime ctype.substitute(f.ret, targs);
    out = out ++ if (f.special != .none and !vbase_dtor)
        "@"
    else
        (if (ret == .named) "?A" else "") ++ mangleType(ret, &st, false);

    if (f.params.len == 0) {
        out = out ++ "X";
    } else {
        inline for (f.params) |p| out = out ++ mangleParam(ctype.substitute(p, targs), &st);
        out = out ++ "@";
    }
    return out ++ "Z";
}

/// `name@scope@outer@@`, innermost first.
fn qualifiedName(comptime path: []const Component, comptime st: *State) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i = path.len;
    inline while (i > 0) : (i -= 1) out = out ++ component(path[i - 1], st);
    return out ++ "@";
}

/// The name of the function being mangled. It differs from `qualifiedName` in
/// one place: when the function is a template, its own template-id takes no
/// slot in the name table, though a class template-id in an enclosing scope
/// still does. Clang mangles a template-id in a swapped-out back-reference
/// context, and for the leaf there is no outer name left to record.
fn functionName(comptime path: []const Component, comptime st: *State) []const u8 {
    const leaf = path[path.len - 1];
    if (leaf.args.len == 0) return qualifiedName(path, st);
    comptime var out: []const u8 = templateId(leaf);
    comptime var i = path.len - 1;
    inline while (i > 0) : (i -= 1) out = out ++ component(path[i - 1], st);
    return out ++ "@";
}

fn component(comptime c: Component, comptime st: *State) []const u8 {
    if (c.args.len == 0) return st.emitName(c.name, c.name ++ "@");
    // A template-id has its own back-ref scope and is one name outside it.
    const id = templateId(c);
    return st.emitName(id, id);
}

fn templateId(comptime c: Component) []const u8 {
    comptime var inner = State{};
    comptime var out: []const u8 = "?$" ++ inner.emitName(c.name, c.name ++ "@");
    inline for (c.args) |a| out = out ++ switch (a) {
        .type => |t| mangleType(t, &inner, false),
        .integral => |v| "$0" ++ number(v.value),
    };
    return out ++ "@";
}

/// 0 -> `A@`, 1..10 -> `0`..`9`, else hex `A`..`P` + `@`; negatives `?`-prefixed.
fn number(comptime v: i64) []const u8 {
    if (v < 0) return "?" ++ number(-v);
    if (v == 0) return "A@";
    if (v <= 10) return ctype.decimal(@intCast(v - 1));
    return hexDigits(@intCast(v)) ++ "@";
}

fn hexDigits(comptime v: u64) []const u8 {
    const d = &[_]u8{'A' + @as(u8, @intCast(v % 16))};
    return if (v < 16) d else hexDigits(v / 16) ++ d;
}

fn mangleParam(comptime t: CType, comptime st: *State) []const u8 {
    if (st.findType(t.key())) |idx| return ctype.decimal(idx);
    const enc = mangleType(t, st, false);
    if (enc.len > 1 and st.types.len < 10) st.types = st.types ++ &[_][]const u8{t.key()};
    return enc;
}

/// `self_const`: the enclosing pointer/reference is to const, so a pointer
/// type here is itself const and spelled `Q` rather than `P`.
fn mangleType(comptime t: CType, comptime st: *State, comptime self_const: bool) []const u8 {
    return switch (t) {
        .builtin => |b| builtinCode(b),
        .pointer => |p| (if (self_const or p.top_const) "Q" else "P") ++ indirectSuffix(p.child, p.is_const, st),
        .reference => |r| (if (r.rvalue) "$$Q" else "A") ++ indirectSuffix(r.child, r.is_const, st),
        .named => |n| kindCode(n.kind) ++ qualifiedName(n.path, st),
        // `substitute` runs before mangling, so none can reach here.
        .template_param => |i| @compileError("template parameter T" ++ ctype.decimal(i) ++ " has no template argument to substitute"),
    };
}

fn indirectSuffix(comptime child: *const CType, comptime is_const: bool, comptime st: *State) []const u8 {
    return (if (ptr64) "E" else "") ++ (if (is_const) "B" else "A") ++ mangleType(child.*, st, is_const);
}

fn kindCode(comptime k: ctype.Kind) []const u8 {
    return switch (k) {
        .@"struct" => "U",
        .class => "V",
        .@"union" => "T",
        .@"enum" => "W4",
    };
}

fn builtinCode(comptime b: ctype.Builtin) []const u8 {
    return switch (b) {
        .void => "X",
        .bool => "_N",
        .char => "D",
        .schar => "C",
        .uchar => "E",
        .short => "F",
        .ushort => "G",
        .int => "H",
        .uint => "I",
        .long => "J",
        .ulong => "K",
        .longlong => "_J",
        .ulonglong => "_K",
        .float => "M",
        .double => "N",
        .longdouble => "O",
        .wchar_t => "_W",
        .char16_t => "_S",
        .char32_t => "_U",
    };
}

test "msvc numbers" {
    try std.testing.expectEqualStrings("A@", comptime number(0));
    try std.testing.expectEqualStrings("0", comptime number(1));
    try std.testing.expectEqualStrings("2", comptime number(3));
    try std.testing.expectEqualStrings("9", comptime number(10));
    try std.testing.expectEqualStrings("L@", comptime number(11));
    try std.testing.expectEqualStrings("BA@", comptime number(16));
    try std.testing.expectEqualStrings("?0", comptime number(-1));
}
