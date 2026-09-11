//! Calls into `test/inline_fixture.hpp`, which defines everything inline and
//! so has no symbols of its own. Every test here links only because the glue
//! generated from `inline_fixture.zig` emitted a definition for what it binds.
const std = @import("std");
const cpp = @import("cpp_bindgen");
const inl = @import("inline_fixture");

test "inline free function and inline members" {
    const add = cpp.bind(inl.add);
    try std.testing.expectEqual(304, add(3, 4));

    const magic = cpp.bind(inl.Counter.magic);
    try std.testing.expectEqual(4242, magic());

    const get = cpp.bind(inl.Counter.get);
    const set = cpp.bind(inl.Counter.set);
    var c: inl.Counter = .{ .n = 0 };
    set(&c, 17);
    try std.testing.expectEqual(17, get(&c));
}

test "inline constructor and destructor" {
    const ctor = cpp.bind(inl.Box.ctor);
    const dtor = cpp.bind(inl.Box.dtor);
    const get = cpp.bind(inl.Box.get);
    var b: inl.Box = undefined;
    ctor(&b, 21);
    try std.testing.expectEqual(21, get(&b));
    dtor(&b);
    try std.testing.expectEqual(-1, b.v);
}

test "inline polymorphic class" {
    const ctor = cpp.bind(inl.shape_ctor);
    const area = cpp.bind(inl.shape_area);
    var s: inl.Shape = undefined;
    ctor(&s, 5);
    try std.testing.expectEqual(5, s.k);
    try std.testing.expectEqual(25, area(&s));
    cpp.bind(inl.shape_dtor)(&s);
}

test "explicitly instantiated template" {
    const sum = cpp.bind(inl.array_sum);
    const size = cpp.bind(inl.array_size);
    const a = inl.Array3{ .v = .{ 1, 2, 3 } };
    try std.testing.expectEqual(6, sum(&a));
    try std.testing.expectEqual(3, size());
}

test "explicitly instantiated function template" {
    const sum = cpp.bind(inl.tpl_sum);
    var a: c_int = 20;
    var b: c_int = 3;
    try std.testing.expectEqual(23, sum(&a, &b));
}

test "inline class returned by value" {
    const make = cpp.bind(inl.rgb_make);
    const total = cpp.bind(inl.rgb_total);
    const c = make(1, 2, 3);
    try std.testing.expectEqual(inl.Rgb{ .r = 1, .g = 2, .b = 3 }, c);
    try std.testing.expectEqual(6, total(c));
}
