//! Zig bindings for test/vtable_fixture.cpp, shared by the tests of
//! vtable.zig and subclass.zig. Each class is spelled as a binding author
//! would spell it, `cpp_virtuals` included; the C++ it stands for is in the
//! comment above it.
const cpp = @import("root.zig");

const Signature = cpp.Signature;

pub fn virt(comptime This: type, comptime name: []const u8, comptime args: []const type, comptime Ret: type) Signature {
    return .{ .name = name, .this = This, .args = args, .ret = Ret, .virtual = true };
}

pub fn dtorOf(comptime T: type) Signature {
    return .{ .name = "~", .this = *T };
}

// struct Node { virtual ~Node(); virtual int customDraw(int) const; virtual int customDraw();
//               virtual int draw() const; virtual int onChanged(); int x; };
// struct Cam : Node { ~Cam() override; virtual int begin(); virtual int begin(int); virtual int end(); int lens; };
pub const Node = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    x: c_int,
    pub const cpp_name = "vt::Node";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const customDraw_r = virt(*const Node, "customDraw", &.{c_int}, c_int);
    pub const customDraw = virt(*Node, "customDraw", &.{}, c_int);
    pub const draw = virt(*const Node, "draw", &.{}, c_int);
    pub const onChanged = virt(*Node, "onChanged", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Node), customDraw_r, customDraw, draw, onChanged };
};
pub const Cam = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    lens: c_int,
    pub const cpp_name = "vt::Cam";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Node};
    pub const cpp_virtual_dtor = true;
    pub const begin = virt(*Cam, "begin", &.{}, c_int);
    pub const begin_vp = virt(*Cam, "begin", &.{c_int}, c_int);
    pub const end = virt(*Cam, "end", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Cam), begin, begin_vp, end };
};

// struct Mid : Cam { int extra; };                      declares no virtual function
// struct Leaf : Mid { int begin(int) override; virtual int zoom(); };
pub const Mid = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    extra: c_int,
    pub const cpp_name = "vt::Mid";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Cam};
    pub const cpp_virtual_dtor = true;
    pub const cpp_virtuals: []const Signature = &.{};
};
pub const Leaf = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Leaf";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Mid};
    pub const cpp_virtual_dtor = true;
    pub const begin_vp = virt(*Leaf, "begin", &.{c_int}, c_int);
    pub const zoom = virt(*Leaf, "zoom", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ begin_vp, zoom };
};

// struct In { virtual ~In(); virtual int audioIn(int); };
// struct Out { virtual ~Out(); virtual int audioOut(int); int gain; };
// struct App : In, Out { ~App() override; virtual int update(); int frames; };
pub const In = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::In";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const audioIn = virt(*In, "audioIn", &.{c_int}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(In), audioIn };
};
pub const Out = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    gain: c_int,
    pub const cpp_name = "vt::Out";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const audioOut = virt(*Out, "audioOut", &.{c_int}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Out), audioOut };
};
pub const App = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    frames: c_int,
    pub const cpp_name = "vt::App";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ In, Out };
    pub const cpp_virtual_dtor = true;
    pub const update = virt(*App, "update", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(App), update };
};

// struct Mix : In, Out { int audioOut(int) override; virtual int update(); };
pub const Mix = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Mix";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ In, Out };
    pub const cpp_virtual_dtor = true;
    pub const audioOut = virt(*Mix, "audioOut", &.{c_int}, c_int);
    pub const update = virt(*Mix, "update", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ audioOut, update };
};

// struct NoDtor { virtual int a(); };
// struct Mix2 : NoDtor, Out { ~Mix2() override; virtual int u(); };
// struct Mix3 : NoDtor, Out { virtual int u(); };      implicit ~Mix3
pub const NoDtor = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::NoDtor";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_polymorphic = true;
    pub const a = virt(*NoDtor, "a", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{a};
};
pub const Mix2 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Mix2";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ NoDtor, Out };
    pub const cpp_virtual_dtor = true;
    pub const u = virt(*Mix2, "u", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Mix2), u };
};
pub const Mix3 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Mix3";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ NoDtor, Out };
    pub const cpp_virtual_dtor = true;
    pub const u = virt(*Mix3, "u", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{u};
};

// struct B { virtual ~B(); virtual void f(); };
// struct D1 : B { void g(int); virtual void h(); virtual void g(); };          non-virtual g first
// struct D2 : B { void f() override; virtual void k(); virtual void f(int); }; an override first
// struct D3 : B { using B::f; virtual void k(); virtual void f(int); };        a using-declaration first
pub const B = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::B";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const f = virt(*B, "f", &.{}, void);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(B), f };
};
pub const D1 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::D1";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{B};
    pub const cpp_virtual_dtor = true;
    pub const h = virt(*D1, "h", &.{}, void);
    pub const g = virt(*D1, "g", &.{}, void);
    pub const cpp_virtuals: []const Signature = &.{ cpp.firstNamed("g"), h, g };
};
pub const D2 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::D2";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{B};
    pub const cpp_virtual_dtor = true;
    pub const f = virt(*D2, "f", &.{}, void);
    pub const k = virt(*D2, "k", &.{}, void);
    pub const f_int = virt(*D2, "f", &.{c_int}, void);
    pub const cpp_virtuals: []const Signature = &.{ f, k, f_int };
};
pub const D3 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::D3";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{B};
    pub const cpp_virtual_dtor = true;
    pub const k = virt(*D3, "k", &.{}, void);
    pub const f_int = virt(*D3, "f", &.{c_int}, void);
    pub const cpp_virtuals: []const Signature = &.{ cpp.firstNamed("f"), k, f_int };
};

// struct G { virtual void a(int); virtual ~G(); virtual void b(); virtual void a(); };
pub const G = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::G";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const a_int = virt(*G, "a", &.{c_int}, void);
    pub const b = virt(*G, "b", &.{}, void);
    pub const a = virt(*G, "a", &.{}, void);
    pub const cpp_virtuals: []const Signature = &.{ a_int, dtorOf(G), b, a };
};

// struct Conv { virtual operator int() const; virtual int v(); virtual operator float() const; };
pub const Conv = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Conv";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_polymorphic = true;
    pub const to_int = virt(*const Conv, ":cast", &.{}, c_int);
    pub const v = virt(*Conv, "v", &.{}, c_int);
    pub const to_float = virt(*const Conv, ":cast", &.{}, f32);
    pub const cpp_virtuals: []const Signature = &.{ to_int, v, to_float };
};

// struct Pod { int a; char c; };
// struct P1 : Pod { virtual ~P1(); virtual int f(); char d; };   vfptr@0, Pod@8
// struct P3 : Pod, Node { int own(); virtual int extra(); };     Node@0, primary though declared second
pub const Pod = extern struct {
    a: c_int,
    c: u8,
    pub const cpp_name = "vt::Pod";
};
pub const P1 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    d: u8,
    pub const cpp_name = "vt::P1";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Pod};
    pub const cpp_virtual_dtor = true;
    pub const f = virt(*P1, "f", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(P1), f };
};
pub const P3 = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::P3";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ Pod, Node };
    pub const cpp_virtual_dtor = true;
    pub const extra = virt(*P3, "extra", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{extra};
};

// struct P { virtual int p(); };  struct Q { virtual int q(); };
// struct PQ : P, Q { int q() override; virtual int pq(); };
// struct Top : In, PQ { int q() override; int p() override; virtual int t(); };   In@0, PQ@8, Q@16
pub const P = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::P";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_polymorphic = true;
    pub const p = virt(*P, "p", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{p};
};
pub const Q = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Q";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_polymorphic = true;
    pub const q = virt(*Q, "q", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{q};
};
pub const PQ = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::PQ";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ P, Q };
    pub const q = virt(*PQ, "q", &.{}, c_int);
    pub const pq = virt(*PQ, "pq", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ q, pq };
};
pub const Top = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Top";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ In, PQ };
    pub const cpp_virtual_dtor = true;
    pub const q = virt(*Top, "q", &.{}, c_int);
    pub const p = virt(*Top, "p", &.{}, c_int);
    pub const t = virt(*Top, "t", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ q, p, t };
};

// struct L1 : P {};  struct L2 : P {};  struct Dia : L1, L2 {};
// struct E1 : Dia {};  struct E2 : Dia {};  struct F : E1, E2 {};
// Every table here was introduced by P, so MSVC tells them apart by path.
pub fn PolyShell(comptime name: []const u8, comptime bases: []const type) type {
    return extern struct {
        _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
        pub const cpp_name = name;
        pub const cpp_abi: cpp.ClassAbi = .managed_copy;
        pub const cpp_bases: []const type = bases;
        pub const cpp_virtuals: []const Signature = &.{};
    };
}
pub const L1 = PolyShell("vt::L1", &.{P});
pub const L2 = PolyShell("vt::L2", &.{P});
pub const Dia = PolyShell("vt::Dia", &.{ L1, L2 });
pub const E1 = PolyShell("vt::E1", &.{Dia});
pub const E2 = PolyShell("vt::E2", &.{Dia});
pub const F = PolyShell("vt::F", &.{ E1, E2 });

// struct Vec2 { int x, y; };
// struct Shape { virtual ~Shape(); virtual Vec2 pos() const; virtual int area(const Vec2&) const; int w, h; };
// struct Square : Shape { Vec2 pos() const override; int area(const Vec2&) const override; };
pub const Vec2 = extern struct {
    x: c_int,
    y: c_int,
    pub const cpp_name = "vt::Vec2";
};
pub const Shape = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    w: c_int,
    h: c_int,
    pub const cpp_name = "vt::Shape";
    pub const ctor_wh: Signature = .{ .name = "*", .this = *Shape, .args = &.{ c_int, c_int } };
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const pos = virt(*const Shape, "pos", &.{}, Vec2);
    pub const area = virt(*const Shape, "area", &.{cpp.Ref(*const Vec2)}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Shape), pos, area };
};
// struct Msg { Msg(int); Msg(const Msg&); ~Msg(); int v; };
// struct Size { Size(int, int); int w, h; };
// struct Talker { virtual ~Talker(); virtual Msg say(Msg) const; virtual Size size() const;
//                 virtual Vec2 at(Vec2) const; int base; };
// struct Duo : In, Talker { Msg say(Msg) const override; };
pub const Msg = extern struct {
    v: c_int,
    pub const cpp_name = "vt::Msg";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const ctor: Signature = .{ .name = "*", .this = *Msg, .args = &.{c_int} };
    pub const dtor: Signature = .{ .name = "~", .this = *Msg };
};
pub const Size = extern struct {
    w: c_int,
    h: c_int,
    pub const cpp_name = "vt::Size";
    pub const cpp_abi: cpp.ClassAbi = .trivial_copy;
};
pub const Talker = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    base: c_int,
    pub const cpp_name = "vt::Talker";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const say = virt(*const Talker, "say", &.{Msg}, Msg);
    pub const size = virt(*const Talker, "size", &.{}, Size);
    pub const at = virt(*const Talker, "at", &.{Vec2}, Vec2);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Talker), say, size, at };
};
pub const Duo = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Duo";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ In, Talker };
    pub const cpp_virtual_dtor = true;
    pub const say = virt(*const Duo, "say", &.{Msg}, Msg);
    pub const cpp_virtuals: []const Signature = &.{say};
};

// struct Abstract { virtual ~Abstract(); virtual int need() = 0; virtual int have(); int k; };
// struct Concrete : Abstract { int need() override; };
// struct PureOut { virtual int po() const = 0; };
// struct Plug : In, PureOut { ~Plug() override; virtual int own(); };
pub const Abstract = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    k: c_int,
    pub const cpp_name = "vt::Abstract";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const need: Signature = .{ .name = "need", .this = *Abstract, .ret = c_int, .pure = true };
    pub const have = virt(*Abstract, "have", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Abstract), need, have };
};
pub const Concrete = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Concrete";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Abstract};
    pub const cpp_virtual_dtor = true;
    pub const need = virt(*Concrete, "need", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{need};
};
pub const PureOut = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::PureOut";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_polymorphic = true;
    pub const po: Signature = .{ .name = "po", .this = *const PureOut, .ret = c_int, .pure = true };
    pub const cpp_virtuals: []const Signature = &.{po};
};
pub const Plug = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Plug";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ In, PureOut };
    pub const cpp_virtual_dtor = true;
    pub const own = virt(*Plug, "own", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Plug), own };
};

// test/vtable_optimized.cpp, compiled with -O2:
// struct Opt { virtual ~Opt(); virtual int f(); };
// struct OptLeaf : Opt { int f() override; };     implicit ~OptLeaf
pub const Opt = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Opt";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const f = virt(*Opt, "f", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(Opt), f };
};
pub const OptLeaf = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::OptLeaf";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Opt};
    pub const cpp_virtual_dtor = true;
    pub const f = virt(*OptLeaf, "f", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{f};
};

// struct Lamp : Node { private: int customDraw(int) const override; protected: int onChanged() override; };
// struct Guarded { virtual int g() = 0; protected: Guarded(); virtual ~Guarded(); int k; };
pub const Lamp = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Lamp";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Node};
    pub const cpp_virtual_dtor = true;
    pub const customDraw_r: Signature = .{ .name = "customDraw", .this = *const Lamp, .args = &.{c_int}, .ret = c_int, .virtual = true, .access = .private };
    pub const onChanged: Signature = .{ .name = "onChanged", .this = *Lamp, .ret = c_int, .virtual = true, .access = .protected };
    pub const cpp_virtuals: []const Signature = &.{ customDraw_r, onChanged };
};
pub const Guarded = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    k: c_int,
    pub const cpp_name = "vt::Guarded";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const ctor: Signature = .{ .name = "*", .this = *Guarded, .access = .protected };
    pub const g: Signature = .{ .name = "g", .this = *Guarded, .ret = c_int, .pure = true };
    pub const dtor: Signature = .{ .name = "~", .this = *Guarded, .access = .protected };
    pub const cpp_virtuals: []const Signature = &.{ g, dtor };
};

pub const Square = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    pub const cpp_name = "vt::Square";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Shape};
    pub const cpp_virtual_dtor = true;
    pub const pos = virt(*const Square, "pos", &.{}, Vec2);
    pub const area = virt(*const Square, "area", &.{cpp.Ref(*const Vec2)}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ pos, area };
};

/// `vt::Node` with its two `customDraw` overloads listed the wrong way round.
pub const BadNode = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    x: c_int,
    pub const cpp_name = "vt::Node";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const customDraw_r = virt(*const BadNode, "customDraw", &.{c_int}, c_int);
    pub const customDraw = virt(*BadNode, "customDraw", &.{}, c_int);
    pub const draw = virt(*const BadNode, "draw", &.{}, c_int);
    pub const onChanged = virt(*BadNode, "onChanged", &.{}, c_int);
    pub const cpp_virtuals: []const Signature = &.{ dtorOf(BadNode), customDraw, customDraw_r, draw, onChanged };
};

/// `vt::App` without `update`, the last slot of its first table.
pub const ShortApp = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),
    frames: c_int,
    pub const cpp_name = "vt::App";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{ In, Out };
    pub const cpp_virtual_dtor = true;
    pub const cpp_virtuals: []const Signature = &.{dtorOf(ShortApp)};
};
