// Header-only C++: nothing here has a symbol until a translation unit emits
// one. The generated glue is that translation unit, so a binding to anything
// in this file fails at link time if the glue is wrong.
#pragma once
#include <stddef.h>

namespace inl {

inline int add(int a, int b) { return a * 100 + b; }

struct Counter {
    int n;
    int get() const { return n; }
    void set(int v) { n = v; }
    static int magic() { return 4242; }
};

struct Box {
    int v;
    Box(int x) : v(x) {}
    ~Box() { v = -1; }
    int get() const { return v; }
};

// Polymorphic: its vtable, and therefore its virtual members, exist only in a
// translation unit that constructs one.
struct Shape {
    int k;
    Shape(int x) : k(x) {}
    virtual ~Shape() {}
    virtual int area() const { return k * k; }
};

template <typename T, int N>
struct Array {
    T v[N];
    T sum() const {
        T s = T();
        for (int i = 0; i < N; i++) s += v[i];
        return s;
    }
    static int size() { return N; }
};

// A function template with no explicit specialization anywhere: its symbol
// exists only if the glue explicitly instantiates it.
template <typename T>
int tpl_sum(const T& a, const T& b) { return (int)(a + b); }

// Bound from inline_extra.zig, which build.zig never names.
struct Pair {
    int a, b;
    int sum() const { return a + b; }
};
inline Pair pair_make(int a, int b) { return Pair{a, b}; }

// A class with a constructor, so a copy is still a memcpy but MSVC returns it
// through a hidden pointer.
struct Rgb {
    unsigned char r, g, b;
    Rgb(int r_, int g_, int b_) : r((unsigned char)r_), g((unsigned char)g_), b((unsigned char)b_) {}
    int total() const { return r + g + b; }
};
inline Rgb rgb_make(int r, int g, int b) { return Rgb(r, g, b); }
inline int rgb_total(Rgb c) { return c.total(); }

// Base classes. The glue asserts the relation and the polymorphism, and each
// derived class's own named member sits where the bases end, so its
// `offsetof` check is a check of the placement too.
struct Base {
    int b;
    Base(int x) : b(x) {}
    virtual ~Base() {}
    int baseGet() const { return b; }
};
struct Derived : Base {
    int d;
    Derived(int x, int y) : Base(x), d(y) {}
    int derivedGet() const { return d * 10 + b; }
};
struct Side {
    int s;
    Side(int x) : s(x) {}
    virtual ~Side() {}
    int sideGet() const { return s; }
};
struct Multi : Base, Side {
    int m;
    Multi(int x, int y, int z) : Base(x), Side(y), m(z) {}
};

} // namespace inl
