// Compiled optimized, unlike vtable_fixture.cpp, as a release build of a C++
// library would be. OptLeaf's destructor is implicit, and here it never
// becomes a symbol of its own: MSVC folds it into the deleting destructor,
// and Itanium points the vtable's complete-object slot at Opt's destructor.
// A Zig subclass has to reach it through the vtable.
namespace vt {

extern int trace;

struct Opt { Opt(); virtual ~Opt(); virtual int f(); };
Opt::Opt() {}
Opt::~Opt() { trace += 1000000; }
int Opt::f() { return 1; }

struct OptLeaf : Opt { OptLeaf(); int f() override; };
OptLeaf::OptLeaf() {}
int OptLeaf::f() { return 2; }

}
