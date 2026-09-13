// Linked into the Zig test binary; a wrong mangling fails at link time.
#include <stdint.h>
#include <stddef.h>

#ifdef _MSC_VER
// The MSVC build links no C++ runtime; deleting destructors need this.
void operator delete(void*, size_t) noexcept {}
#endif

int add(int a, int b) { return a + b; }
void nothing() {}
unsigned mix(char c, signed char sc, unsigned char uc, short s, unsigned short us,
             unsigned u, long l, unsigned long ul, long long ll, unsigned long long ull) {
    return (unsigned)(c + sc + uc + s + us + u + l + ul + ll + ull);
}
double fp(float f, double d) { return f + d; }
bool flip(bool b) { return !b; }
size_t strlen_(const char* s) { size_t n = 0; while (s[n]) n++; return n; }
void* identity(void* p) { return p; }
int* first(int* p, int* q) { return p ? p : q; }          // repeated pointer type
const int* firstc(const int* p, const int* q) { return p ? p : q; }
wchar_t wide(wchar_t w, char16_t c16, char32_t c32) { return (wchar_t)(w + c16 + c32); }

namespace ns {
    int add(int a, int b) { return a * 10 + b; }
    namespace inner { long long sub(long long a, long long b) { return a - b; } }

    struct Vec2 { int x, y; };
    // Members are defined out of line so they are emitted as symbols.
    struct Counter {
        int n;
        int get() const;
        void set(int v);
        int addTo(const Counter* other) const;
        Counter* self();
        int assign(const Counter& other);
        // MSVC returns this through a hidden pointer because it is an
        // instance method; the same type from a free function goes in a
        // register.
        Vec2 asVec() const;
        static Vec2 origin();
    };
    int Counter::get() const { return n; }
    void Counter::set(int v) { n = v; }
    int Counter::addTo(const Counter* other) const { return n + other->n; }
    Vec2 Counter::asVec() const { return Vec2{n, n * 2}; }
    Vec2 Counter::origin() { return Vec2{0, 0}; }
    Counter* Counter::self() { return this; }
    Vec2* make_vec(Vec2* out, int x, int y) { out->x = x; out->y = y; return out; }
    int vec_sum(const Vec2* v) { return v->x + v->y; }
    Counter* counter_new(Counter* storage, int n) { storage->n = n; return storage; }
}

// References.
int& ref_inc(int& x) { return ++x; }
int ref_sum(const int& a, const int& b) { return a + b; }
int take_rvalue(int&& x) { return x * 2; }
namespace ns {
    int vec_sum_ref(const Vec2& v) { return v.x + v.y; }
    Vec2& vec_scale(Vec2& v, int k) { v.x *= k; v.y *= k; return v; }
    int vec_take(Vec2&& v) { return v.x - v.y; }
    int Counter::assign(const Counter& other) { n = other.n; return n; }
    int* const& ptr_ref(int* const& p) { return p; }
    int ptr_ptr(int* const* pp, const int* const* cpp) { return **pp + **cpp; }
}

// Const pointers. Itanium drops the top-level qualifier; MSVC mangles it.
namespace ns {
    int cptr_w(char* const p) { return p ? *p : 0; }
    int cptr_r(const char* const p) { return p ? *p : 0; }
    int cptr_mix(char* const a, char* b) { return (a ? *a : 0) + (b ? *b : 0); }
    int cptr_both(const char* const a, const char* const b) { return (a ? *a : 0) + (b ? *b : 0); }
}

// Class-template specializations, explicitly instantiated.
template<class T> struct Pair { T a, b; };
int pair_sum(const Pair<int>& p) { return p.a + p.b; }
template<bool B, int N> struct Flags { int v; };
int flags(Flags<true, -1>* f, Flags<false, 11>* g) { return f->v + g->v; }
namespace tpl {
    enum qualifier { lowp, highp };
    template<int L, typename T, qualifier Q = highp> struct vec {
        T v[L];
        int len() const;
        T first() const;
        void fill(T x);
        static int dim();
    };
    template<int L, typename T, qualifier Q> int vec<L, T, Q>::len() const { return L; }
    template<int L, typename T, qualifier Q> T vec<L, T, Q>::first() const { return v[0]; }
    template<int L, typename T, qualifier Q> void vec<L, T, Q>::fill(T x) { for (int i = 0; i < L; i++) v[i] = x; }
    template<int L, typename T, qualifier Q> int vec<L, T, Q>::dim() { return L * 10 + (int)Q; }
    template struct vec<3, float, highp>;
    template struct vec<2, int, lowp>;
    using vec3 = vec<3, float>;
    float sum3(const vec3& a, const vec3& b) { return a.v[0] + b.v[0]; }
    int dims(vec3* a, vec<2, int, lowp>* b) { return a->len() * 100 + b->len(); }

    template<class T> struct Alloc { int tag; };
    template<class T, class A = Alloc<T>> class List { public: int n; A alloc; int count() const; };
    template<class T, class A> int List<T, A>::count() const { return n + alloc.tag; }
    template class List<vec3>;
    int list_count(const List<vec3>& l) { return l.count(); }

    template<class T> struct Box { T val; T get() const; };
    template<class T> T Box<T>::get() const { return val; }
    template struct Box<vec3*>;
    template struct Box<char>;
}

// Operator overloads. One spelling can be unary or binary, and only Itanium
// gives each its own code; MSVC leaves arity to the parameter list.
namespace ns {
    struct Ops {
        int x;
        Ops operator+(const Ops& o) const;   // binary
        Ops operator-() const;               // unary
        Ops operator~() const;
        Ops& operator+=(const Ops& o);
        bool operator==(const Ops& o) const;
        int& operator[](int i);
        int operator()(int a, int b) const;
        Ops operator++(int);                 // postfix
        operator int() const;                // conversion
        static void operator delete(void* p);
    };
    Ops Ops::operator+(const Ops& o) const { return Ops{x + o.x}; }
    Ops Ops::operator-() const { return Ops{-x}; }
    Ops Ops::operator~() const { return Ops{~x}; }
    Ops& Ops::operator+=(const Ops& o) { x += o.x; return *this; }
    bool Ops::operator==(const Ops& o) const { return x == o.x; }
    int& Ops::operator[](int i) { (void)i; return x; }
    int Ops::operator()(int a, int b) const { return a * 100 + b * 10 + x; }
    Ops Ops::operator++(int) { Ops t = *this; x++; return t; }
    Ops::operator int() const { return x; }
    void Ops::operator delete(void* p) { (void)p; }

    // Free operators: the same arity rule, one parameter fewer.
    Ops operator*(const Ops& a, int k);
    Ops operator*(const Ops& a, int k) { return Ops{a.x * k}; }
    bool operator!(const Ops& a);
    bool operator!(const Ops& a) { return !a.x; }
}

// Function templates. Itanium encodes the template's declared signature
// (`RKT_`) plus the return type; MSVC encodes the substituted types.
namespace ns {
    template<typename T> int tpl_id(const T& v);
    template<> int tpl_id(const int& v) { return v + 1; }
    template<> int tpl_id(const Vec2& v) { return v.x * 10 + v.y; }

    // Uses T twice, so Itanium back-references the second one.
    template<typename T> T tpl_echo(T v) { return v; }
    template int tpl_echo<int>(int);

    struct Tpl {
        int n;
        template<typename T> int take(const T& v) const;
        template<typename T> static int make(const T& v);
    };
    template<> int Tpl::take(const int& v) const { return n * 100 + v; }
    template<> int Tpl::make(const int& v) { return v * 3; }
}

// Constructors and destructors: plain, polymorphic, and with a virtual base.
namespace ns {
    static int dtor_calls_ = 0;
    int dtor_calls() { return dtor_calls_; }
    struct Plain { int n; Plain(int x); ~Plain(); };
    Plain::Plain(int x) : n(x) {}
    Plain::~Plain() { n = -1; dtor_calls_++; }
    struct Poly { int n; Poly(); virtual ~Poly(); virtual int f(); };
    Poly::Poly() : n(1) {}
    Poly::~Poly() { n = -2; dtor_calls_++; }
    int Poly::f() { return n * 10; }
    struct VBase { int a; VBase(); virtual ~VBase(); };
    VBase::VBase() : a(2) {}
    VBase::~VBase() { dtor_calls_++; }
    struct Derived : virtual VBase { int b; Derived(int x); ~Derived(); };
    Derived::Derived(int x) : b(x) {}
    Derived::~Derived() { dtor_calls_++; }
    int derived_sum(const Derived& d) { return d.a * 100 + d.b; }
    size_t sizeof_derived() { return sizeof(Derived); }
}
namespace tpl {
    template<class T> struct Cell { T val; Cell(T x); ~Cell(); T get() const; };
    template<class T> Cell<T>::Cell(T x) : val(x) {}
    template<class T> Cell<T>::~Cell() { val = T(); }
    template<class T> T Cell<T>::get() const { return val; }
    template struct Cell<int>;
}

// Classes by value, one per cpp_abi category.
namespace ns {
    Vec2 vec_make(int x, int y) { return Vec2{x, y}; }
    int vec_dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
    struct Big { int a, b, c, d, e; };
    Big big_make(int k) { return Big{k, k + 1, k + 2, k + 3, k + 4}; }
    int big_sum(Big b) { return b.a + b.b + b.c + b.d + b.e; }

    // trivial_copy
    struct Color {
        unsigned char r, g, b, a;
        Color() : r(0), g(0), b(0), a(255) {}
        Color(int r_, int g_, int b_, int a_) : r(r_), g(g_), b(b_), a(a_) {}
        int sum() const { return r + g + b + a; }
    };
    Color color_make(int r, int g, int b, int a) { return Color(r, g, b, a); }
    int color_sum(Color c) { return c.sum(); }
    struct Rect {
        float x, y, w, h;
        Rect(float x_, float y_, float w_, float h_) : x(x_), y(y_), w(w_), h(h_) {}
        float area() const { return w * h; }
    };
    Rect rect_make(float x, float y, float w, float h) { return Rect(x, y, w, h); }
    float rect_area(Rect r) { return r.area(); }
    struct Palette {
        Color c[2];
        Color at(int i) const;
        Rect bounds() const;
        int mix(Color a, Color b) const;
    };
    Color Palette::at(int i) const { return c[i]; }
    Rect Palette::bounds() const { return Rect(0, 0, (float)c[0].r, (float)c[1].r); }
    int Palette::mix(Color a, Color b) const { return a.sum() * 1000 + b.sum() + c[0].r; }

    // managed_copy, with a live-object counter.
    static int live_strs_ = 0;
    int live_strs() { return live_strs_; }
    struct Str {
        char buf[24];
        size_t len;
        Str(const char* s);
        Str(const Str& o);
        ~Str();
    };
    Str::Str(const char* s) : len(0) { while (s[len] && len < 23) { buf[len] = s[len]; len++; } buf[len] = 0; live_strs_++; }
    Str::Str(const Str& o) : len(o.len) { for (size_t i = 0; i <= len; i++) buf[i] = o.buf[i]; live_strs_++; }
    Str::~Str() { len = 0; buf[0] = 0; live_strs_--; }
    Str str_make(const char* s) { return Str(s); }
    size_t str_len(Str s) { return s.len; }
    size_t str_len2(Str a, Str b) { return a.len * 100 + b.len; }
    struct Holder {
        Str s;
        Holder(const char* v);
        ~Holder();
        Str get() const;
        size_t take(Str t);
    };
    Holder::Holder(const char* v) : s(v) {}
    Holder::~Holder() {}
    Str Holder::get() const { return Str(s); }
    size_t Holder::take(Str t) { return s.len * 100 + t.len; }
}

// One visible parameter per by-value Str, plus the out-pointer and `this`.
// A method returning a managed class needs a wrapper on both ABIs, so these
// reach the trampoline and pick its entry point by arity.
namespace ns {
    struct Sink {
        int pick;
        Str none() const;
        Str eight(Str a, Str b, Str c, Str d, Str e, Str f, Str g, Str h) const;
        Str nine(Str a, Str b, Str c, Str d, Str e, Str f, Str g, Str h, Str i) const;
    };
    Str Sink::none() const { return Str("none"); }
    Str Sink::eight(Str a, Str b, Str c, Str d, Str e, Str f, Str g, Str h) const {
        const Str* v[8] = {&a, &b, &c, &d, &e, &f, &g, &h};
        return *v[pick % 8];
    }
    Str Sink::nine(Str a, Str b, Str c, Str d, Str e, Str f, Str g, Str h, Str i) const {
        const Str* v[9] = {&a, &b, &c, &d, &e, &f, &g, &h, &i};
        return *v[pick % 9];
    }
}
