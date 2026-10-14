// Linked into the Zig test binary for src/vtable.zig: `verifyVtable` reads the
// vtables clang emits for these classes, and `bindVirtual` calls through them.
// Every class has an out-of-line constructor, which is what makes MSVC emit
// its vftable. Each virtual returns a value no other one does, so a call that
// lands in the wrong slot shows.
//
// src/subclass.zig subclasses them from Zig. The functions at the end are the
// rest of a library using those objects: they only ever see the C++ classes.
//
// On MSVC this file is compiled with RTTI, so that a Zig subclass's RTTI can
// be compared with the C++ class's, though the test binary links no C++
// runtime to dynamic_cast with.
#ifndef _MSC_VER
#include <typeinfo>
#endif

namespace vt {

// What the destructors ran, a digit each.
int trace = 0;

struct Node { Node(); virtual ~Node(); virtual int customDraw(int r) const; virtual int customDraw();
              virtual int draw() const; virtual int onChanged() { return 400; } int x; };
Node::Node() : x(1) {}
Node::~Node() { trace += 1; }
int Node::customDraw(int r) const { return 100 + r; }
int Node::customDraw() { return 200; }
int Node::draw() const { return 300; }

struct Cam : Node { Cam(); ~Cam() override; virtual int begin(); virtual int begin(int viewport); virtual int end(); int lens; };
Cam::Cam() : lens(50) {}
Cam::~Cam() { trace += 10; }
int Cam::begin() { return begin(lens); }  // a virtual call, as ofCamera::begin() makes
int Cam::begin(int viewport) { return 1000 + viewport; }
int Cam::end() { return 1100; }

struct Mid : Cam { Mid(); int extra; };
Mid::Mid() : extra(0) {}
struct Leaf : Mid { Leaf(); int begin(int viewport) override; virtual int zoom(); };
Leaf::Leaf() {}
int Leaf::begin(int viewport) { return 2000 + viewport; }
int Leaf::zoom() { return 2100; }

struct In { In(); virtual ~In(); virtual int audioIn(int v); };
In::In() {}
In::~In() { trace += 100; }
int In::audioIn(int v) { return v * 2; }
struct Out { Out(); virtual ~Out(); virtual int audioOut(int v); int gain; };
Out::Out() : gain(3) {}
Out::~Out() { trace += 1000; }
int Out::audioOut(int v) { return v * gain; }
struct App : In, Out { App(); ~App() override; virtual int update(); int frames; };
App::App() : frames(7) {}
App::~App() { trace += 10000; }
int App::update() { return frames; }
struct Mix : In, Out { Mix(); int audioOut(int v) override; virtual int update(); };
Mix::Mix() {}
int Mix::audioOut(int v) { return v * gain + 1; }  // reads a member: a wrong `this` shows
int Mix::update() { return 8; }

struct NoDtor { NoDtor(); virtual int a(); };
NoDtor::NoDtor() {}
int NoDtor::a() { return 1; }
struct Mix2 : NoDtor, Out { Mix2(); ~Mix2() override; virtual int u(); };
Mix2::Mix2() {}
Mix2::~Mix2() {}
int Mix2::u() { return 2; }
struct Mix3 : NoDtor, Out { Mix3(); virtual int u(); };
Mix3::Mix3() {}
int Mix3::u() { return 3; }

struct B { B(); virtual ~B(); virtual void f(); };
B::B() {}
B::~B() {}
void B::f() {}
struct D1 : B { D1(); void g(int); virtual void h(); virtual void g(); };
D1::D1() {}
void D1::g(int) {}
void D1::h() {}
void D1::g() {}
struct D2 : B { D2(); void f() override; virtual void k(); virtual void f(int); };
D2::D2() {}
void D2::f() {}
void D2::k() {}
void D2::f(int) {}
struct D3 : B { D3(); using B::f; virtual void k(); virtual void f(int); };
D3::D3() {}
void D3::k() {}
void D3::f(int) {}

struct G { G(); virtual void a(int); virtual ~G(); virtual void b(); virtual void a(); };
G::G() {}
void G::a(int) {}
G::~G() {}
void G::b() {}
void G::a() {}

struct Conv { Conv(); virtual operator int() const; virtual int v(); virtual operator float() const; };
Conv::Conv() {}
Conv::operator int() const { return 1; }
int Conv::v() { return 2; }
Conv::operator float() const { return 3.0f; }

struct Pod { int a; char c; };
struct P1 : Pod { P1(); virtual ~P1(); virtual int f(); char d; };
P1::P1() : d('d') {}
P1::~P1() {}
int P1::f() { return 1; }
struct P3 : Pod, Node { P3(); int own(); virtual int extra(); };
P3::P3() {}
int P3::own() { return 0; }
int P3::extra() { return 5; }

struct P { P(); virtual int p(); };
P::P() {}
int P::p() { return 10; }
struct Q { Q(); virtual int q(); };
Q::Q() {}
int Q::q() { return 20; }
struct PQ : P, Q { PQ(); int q() override; virtual int pq(); };
PQ::PQ() {}
int PQ::q() { return 21; }
int PQ::pq() { return 22; }
struct Top : In, PQ { Top(); int q() override; int p() override; virtual int t(); };
Top::Top() {}
int Top::q() { return 31; }
int Top::p() { return 30; }
int Top::t() { return 32; }

// Two tables both introduced by P: MSVC names them by the bases they came
// through, one level (Dia) and two (F).
struct L1 : P { L1(); };
L1::L1() {}
struct L2 : P { L2(); };
L2::L2() {}
struct Dia : L1, L2 { Dia(); };
Dia::Dia() {}
struct E1 : Dia { E1(); };
E1::E1() {}
struct E2 : Dia { E2(); };
E2::E2() {}
struct F : E1, E2 { F(); };
F::F() {}

// Call shapes other than the C one: MSVC returns a class from a member
// function through a hidden pointer, and a reference arrives as a pointer.
struct Vec2 { int x, y; };
struct Shape { Shape(); Shape(int w, int h); virtual ~Shape(); virtual Vec2 pos() const; virtual int area(const Vec2& scale) const; int w, h; };
Shape::Shape() : w(2), h(3) {}
Shape::Shape(int w, int h) : w(w), h(h) {}
Shape::~Shape() {}
Vec2 Shape::pos() const { return {w, h}; }
int Shape::area(const Vec2& s) const { return w * s.x * h * s.y; }
struct Square : Shape { Square(); Vec2 pos() const override; int area(const Vec2& scale) const override; };
Square::Square() { w = 4; h = 4; }
Vec2 Square::pos() const { return {w * 10, h * 10}; }
int Square::area(const Vec2& s) const { return w * w * s.x * s.y + 1; }

// Every by-value shape at once. Msg has a user-provided copy constructor and
// destructor (`.managed_copy`): passed as a pointer to a temporary, returned
// through a hidden pointer, and destroyed by the callee on MSVC but by the
// caller on Itanium; `msgs` counts the live ones, so a copy destroyed twice or
// never shows. Size is trivially copyable with a constructor
// (`.trivial_copy`): MSVC returns it through a hidden pointer, Itanium in
// registers. Vec2 is plain C, but MSVC returns any class from a member
// function through a hidden pointer.
int msgs = 0;
struct Msg { Msg(int v); Msg(const Msg& o); ~Msg(); int v; };
Msg::Msg(int v) : v(v) { ++msgs; }
Msg::Msg(const Msg& o) : v(o.v) { ++msgs; }
Msg::~Msg() { --msgs; }
struct Size { Size(int w, int h) : w(w), h(h) {} int w, h; };
struct Talker { Talker(); virtual ~Talker(); virtual Msg say(Msg m) const; virtual Size size() const;
                virtual Vec2 at(Vec2 p) const; int base; };
Talker::Talker() : base(1) {}
Talker::~Talker() {}
Msg Talker::say(Msg m) const { return Msg(m.v + base); }
Size Talker::size() const { return Size(1, 2); }
Vec2 Talker::at(Vec2 p) const { return {p.x + base, p.y}; }
// Talker is a second base here, so on Itanium its table's `say` slot holds a
// thunk to Duo::say.
struct Duo : In, Talker { Duo(); Msg say(Msg m) const override; };
Duo::Duo() {}
Msg Duo::say(Msg m) const { return Msg(m.v * 100); }

// Pure virtuals: Abstract's own slot holds the pure-call handler, and it
// calls the function virtually from a function it does define. PureOut is a
// second base whose only virtual is pure.
struct Abstract { Abstract(); virtual ~Abstract(); virtual int need() = 0; virtual int have(); int k; };
Abstract::Abstract() : k(4) {}
Abstract::~Abstract() { trace += 100000; }
int Abstract::have() { return need() + k; }
struct Concrete : Abstract { Concrete(); int need() override; };
Concrete::Concrete() {}
int Concrete::need() { return 40; }
struct PureOut { PureOut(); virtual int po() const = 0; };
PureOut::PureOut() {}
// Plug declares its destructor: Plug is abstract, so a Zig subclass destroys
// it by name, and nothing here would make an implicit one exist (in a real
// build, the glue does).
struct Plug : In, PureOut { Plug(); ~Plug() override; virtual int own(); };
Plug::Plug() {}
Plug::~Plug() {}
int Plug::own() { return 5; }

// The library's side.
int read_trace() { return trace; }
int drive_begin(Cam* c) { return c->begin(); }
int drive_custom(Node* n) { return n->customDraw(); }
int drive_custom_r(const Node* n, int r) { return n->customDraw(r); }
int drive_changed(Node* n) { return n->onChanged(); }
int drive_audio_out(Out* o, int v) { return o->audioOut(v); }
int drive_mix_audio(Mix* m, int v) { return m->audioOut(v); }
int drive_update(App* a) { return a->update(); }
int drive_area(const Shape* s, int x, int y) { return s->area(Vec2{x, y}); }
int drive_pos_x(const Shape* s) { return s->pos().x; }
int drive_a(NoDtor* n) { return n->a(); }
int live_msgs() { return msgs; }
int drive_say(const Talker* t, int v) { return t->say(Msg(v)).v; }
int drive_size(const Talker* t) { Size s = t->size(); return s.w * 10 + s.h; }
int drive_at(const Talker* t, int x, int y) { Vec2 r = t->at({x, y}); return r.x * 100 + r.y; }
int drive_have(Abstract* a) { return a->have(); }
int drive_need(Abstract* a) { return a->need(); }
int drive_po(const PureOut* p) { return p->po(); }
int drive_p(P* p) { return p->p(); }
int drive_q(Q* q) { return q->q(); }
void drive_delete_node(Node* n) { delete n; }
void drive_delete_out(Out* o) { delete o; }

#ifndef _MSC_VER
bool is_cam(Node* n) { return dynamic_cast<Cam*>(n) != nullptr; }
bool is_app(Out* o) { return dynamic_cast<App*>(o) != nullptr; }
void* whole(Out* o) { return dynamic_cast<void*>(o); }
void* whole_p(P* p) { return dynamic_cast<void*>(p); }
const char* type_name(Node* n) { return typeid(*n).name(); }
#endif

}
