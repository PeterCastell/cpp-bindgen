# cpp-bindgen

Call C++ functions from Zig without a C shim.

You write a C++ signature in Zig types. `cpp-bindgen` computes the mangled symbol
name at compile time and returns a pointer to that external function. You link the
C++ object directly, and you write no wrapper in C.

The library knows both manglings, Itanium (Linux, macOS, MinGW) and MSVC, and picks
one from the target ABI.

## Install

```bash
zig fetch --save git+https://github.com/PeterCastell/cpp-bindgen.git
```

Then add the module in `build.zig`:

```zig
const cpp_bindgen = b.dependency("cpp_bindgen", .{ .target = target });
exe_mod.addImport("cpp_bindgen", cpp_bindgen.module("cpp_bindgen"));
```

## Use

```zig
const cpp = @import("cpp_bindgen");

// int ns::add(int, int)
const add = cpp.bindFn(&.{ c_int, c_int }, c_int, "ns::add");

// namespace ns { struct Counter { int n; int get() const; void set(int); }; }
const Counter = extern struct {
    n: c_int,
    pub const cpp_name = "ns::Counter";
};
const get = cpp.bindMethod(*const Counter, &.{}, c_int, "get");
const set = cpp.bindMethod(*Counter, &.{c_int}, void, "set");

var counter: Counter = .{ .n = 0 };
set(&counter, add(2, 3));
// get(&counter) is now 5
```

`bindStatic` binds a static member function. `bind` takes a full `Signature`. Use it
for the cases that the three short forms do not cover, such as a virtual method, a
constructor, or a reference parameter. `mangledName` returns the symbol name alone.

## Parameter markers

Three markers spell a parameter or return type that a Zig type cannot. None of them
exists at run time: the bound function takes the pointer inside.

- `Ref(*const T)` is `const T&`, `Ref(*T)` is `T&`, and `RRef(*T)` is `T&&`.
- `ConstPtr([*c]const u8)` is `const char* const`, a const *pointer* rather than a
  pointer to const. Itanium drops a top-level qualifier from a parameter type, so it
  changes nothing there; MSVC spells such a pointer `Q` rather than `P`, and the MSVC
  standard library declares parameters this way, `basic_string`'s `const char* const`
  constructors among them.
- `TParam(0)` is the enclosing function template's first template parameter. See below.

## Operators

Name an operator by prefixing its C++ spelling with a colon. The colon is what keeps
`":~"` (`operator~`) apart from `"~"` (the destructor), and `":*"` from `"*"` (the
constructor).

```zig
const add = cpp.bind(.{ .name = ":+", .this = *const Vec, .args = &.{Ref(*const Vec)}, .ret = Vec });
const at  = cpp.bind(.{ .name = ":[]", .this = *Vec, .args = &.{c_int}, .ret = Ref(*f32) });
const del = cpp.bind(.{ .name = ":delete", .class = Vec, .args = &.{*anyopaque} });
```

The spellings are the C++ tokens: `:+ :- :* :& :/ :% :| :^ :<< :>> :~ :! := :+= :-=
:*= :/= :%= :&= :|= :^= :<<= :>>= :== :!= :< :> :<= :>= :&& :|| :, :++ :-- :[] :()
:-> :->* :new :delete :new[] :delete[]`, plus `:cast` for a conversion operator,
whose target is its return type — `.name = ":cast", .ret = c_int` is `operator int`.

A free operator takes a qualified name, so `ns::` followed by `:+` reads as a triple
colon:

```zig
const mul = cpp.bind(.{ .name = "ns:::*", .args = &.{ Ref(*const Vec), f32 }, .ret = Vec });
```

**Arity is inferred, and it matters.** One spelling can be unary or binary, and
Itanium gives each its own code — `operator-` is `mi` binary and `ng` unary — while
MSVC uses one code and leaves arity to the parameter list. A method with no
parameters is unary, as is a free function with one; write the parameters as C++
declares them and the right code follows. Postfix `++` and `--` are the forms that
take an unused `int`.

## Function templates

A specialization of a function template has a template-mangled symbol. Give the
arguments in `template_args`, and write `TParam(n)` wherever the template's
*declaration* named one of its own parameters:

```zig
// template<typename T> void ofDrawBitmapString(const T&, float x, float y, float z);
// template<> void ofDrawBitmapString(const std::string&, float, float, float);
const draw = cpp.bind(.{
    .name = "ofDrawBitmapString",
    .template_args = &.{.{ .type = StdString }},
    .args = &.{ Ref(*const TParam(0)), f32, f32, f32 },
});

draw(&text, 10, 20, 0);   // the Zig parameter is *const StdString
```

Both halves are needed because the two ABIs disagree about which signature to encode.
Itanium mangles the template's declared form, `RKT_`, a reference to
template-parameter 0; MSVC mangles the substituted form, `AEBV?$basic_string@...`.
`TParam` gives one spelling that satisfies both, and the Zig-visible parameter type is
the substituted one either way.

Member and static member function templates take the same fields, alongside `this` or
`class`.

## Classes

A Zig type describes its C++ class through public declarations. It must be an
`extern struct`, an `extern union`, an enum, or `opaque`: a C++ class has the field
order its declaration gives it, and Zig reorders the fields of a plain struct.

- `cpp_name` — the qualified name, such as `"ns::Counter"`.
- `cpp_template` — a `Template` value in place of `cpp_name`, for a specialization
  such as `tpl::vec<3, float, highp>`.
- `cpp_kind` — struct, class, union, or enum. Only MSVC mangles this difference.
- `cpp_abi` — how the ABI passes and returns the class by value. The three values are
  `.c_struct`, `.trivial_copy`, and `.managed_copy`. It is not the whole story for
  returns: MSVC returns a class through a hidden pointer from *any* instance method,
  whatever its size and however trivial it is, while a free or static function
  returning the same class uses a register. The binder handles that for you.
- `cpp_virtual_dtor` — the destructor is virtual. Only MSVC mangles the difference.
- `cpp_virtual_bases` — the class has virtual bases. MSVC mangles it; on Itanium it
  also selects the complete-object constructor and destructor, since a class without
  virtual bases binds the base-object ones.

- `cpp_bases` — the direct base classes, as Zig types, in C++ source order. See
  [Base classes](#base-classes).
- `cpp_polymorphic` — the class has virtual functions. `cpp_virtual_dtor` implies
  it; declare it only for a class whose destructor is not virtual but something
  else is.
- `cpp_virtuals` — the virtual functions the class declares, in header order. See
  [Virtual functions](#virtual-functions).

The default `cpp_abi` is `.c_struct`. That value is correct for plain data, and wrong
for a class with a constructor, a destructor, or a virtual function. Declare the
value for every such class.

Bind a constructor as a method named `"*"`, and a destructor as `"~"`. Both run on
storage that you supply. The Zig type must have the size and the alignment of the C++
object, because the library reads no headers. `addCppGlue` checks that for you.

### Base classes

A derived class names its bases and spells the space they take as its first field.
Everything else is computed: where each base sits on the target's ABI, whether the
class's own vtable pointer comes first, and how far `this` moves to reach a base's
method.

```zig
pub const Node = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),   // its vtable pointer
    x: c_int,
    pub const cpp_name = "ofNode";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
};

pub const Camera = extern struct {
    _bases: cpp.BaseSpan(@This()) align(cpp.baseAlign(@This())),   // Node, wherever it goes
    lens: f64,                                                      // Camera's own members follow
    pub const cpp_name = "ofCamera";
    pub const cpp_abi: cpp.ClassAbi = .managed_copy;
    pub const cpp_bases: []const type = &.{Node};

    pub fn node(self: *Camera) *Node {
        return cpp.basePtr(Node, self);
    }
};

// A base method through a derived pointer: `.class` names the base.
const set_x = cpp.bind(.{ .name = "setX", .class = Node, .args = &.{c_int}, .this = *Camera });
```

`_bases` must be the first field and must be spelled exactly so: a bare array with
the alignment on the field. Wrapping it in a struct would round its length up to its
alignment, and Itanium lays a derived class's members into the tail padding of a
non-POD base, which needs the unpadded length. The class's own members follow, named
or opaque, exactly as in a class without bases.

`cpp.basePtr(Base, ptr)` is the upcast, and a compile error when `Base` is not a base
of the pointee. `cpp.baseOffset(Derived, Base)` is the offset it adds, or null. A
`Signature` whose `.class` is a base of what `this` points at is checked the same way
and has `this` moved before the call, which matters when the base is not at offset 0:
the second of two polymorphic bases, say. A *qualified* name (`"ofNode::setX"`) names
no Zig class and is passed through unchecked, as before.

The rules, measured against clang on both ABIs: a base goes at the next offset
aligned for it; the next offset is where the previous base *ends*, which on MSVC is
its whole `sizeof` and on Itanium only its data unless it is POD; the first polymorphic
base is primary and goes first whatever the declaration order; a class with virtual
functions and no polymorphic base gets its own vtable pointer ahead of every base.
Virtual bases have no fixed offset and are refused. The glue asserts that each base is
a base of the class and that each is polymorphic exactly when the binding says, and
the derived class's own member offsets — which sit where the bases end — are checked
as they always were.

### Virtual functions

A polymorphic class can list the virtual functions it declares. From those lists,
`cpp.vtable.tables(T)` computes every vtable of `T`: where each one sits, and which
function each slot holds.

```zig
pub const Node = extern struct {
    // ...
    pub const customDraw_renderer: cpp.Signature = .{ .name = "customDraw", .this = *const Node, .args = &.{*const BaseRenderer}, .virtual = true };
    pub const customDraw: cpp.Signature = .{ .name = "customDraw", .this = *Node, .virtual = true };
    pub const cpp_virtuals: []const cpp.Signature = &.{
        .{ .name = "~", .this = *Node },
        customDraw_renderer,
        customDraw,
    };
};
```

The list is the order the header declares them in. It includes the destructor and
every override, and leaves out what the class only inherits. A class that declares
no virtual function of its own writes `&.{}`. Each entry is spelled as you would bind
it, with `.virtual = true` (a destructor takes that from `cpp_virtual_dtor`). A pure
virtual function (`= 0`) is `.pure = true` instead; the glue then forces no
definition for it, since it usually has none.

One list is correct on both ABIs. Itanium lays out new virtuals in declaration
order. MSVC groups overloads, puts each group where its *name* is first declared,
and reverses each group. The first declaration of a name may be something the list
does not hold, such as a non-virtual method or a using-declaration. If it comes
before the name's first entry, put `cpp.firstNamed("name")` in the list at that
point. The marker takes no slot, and Itanium ignores it:

```zig
// struct D : B { void g(int); virtual void h(); virtual void g(); };
pub const cpp_virtuals: []const cpp.Signature = &.{ cpp.firstNamed("g"), h, g };
```

A missing or misplaced entry moves every slot after it. `cpp.verifyVtable(T)` finds
that: it reads the vtables the C++ compiler emitted for `T` and checks that every
method slot holds the function the computed layout says. Call it from a test, once
per class:

```zig
test "vtables" {
    try cpp.verifyVtable(of.Camera);
    try cpp.verifyVtable(of.BaseApp);
}
```

It needs no object, only the class's vtable linked in. A pure virtual's slot must
hold the C++ runtime's pure-call handler. It cannot check destructor slots or
thunks, which hold compiler-generated code. Nor can it see an entry missing from the
very end of a table: MSVC records no table's length, and Itanium records one only
through the next table's header. Run it in a build
without identical code folding, which can merge two functions whose bodies match.

#### Virtual calls

`bind` calls one class's definition directly, as a qualified call would in C++. On a
`Camera` that is really an `EasyCam`, `cpp.bind(Camera.begin)` runs
`ofCamera::begin` and skips the override. `cpp.bindVirtual` makes the virtual call: it
loads the function from the object's vtable, so the override runs, whichever class
defines it.

```zig
cpp.bindVirtual(Camera.begin)(camera);   // EasyCam::begin, if that is what camera is
```

It takes the signature `bind` takes and returns a function of the same type, so a
wrapper switches by name alone. With `.class` naming a base of what `this` points
at, the call goes through that base's vtable, with `this` moved to it. The class
that `this` points at needs `cpp_virtuals` all the way down.

#### Subclassing from Zig

`cpp.Subclass(Base, Outer, "field")` makes a Zig type a `Base` to C++, overrides
and all, with no C++ of its own. It is a field with exactly `Base`'s layout, and the
Zig type around it is any struct:

```zig
const OrbitCam = struct {
    cpp: cpp.Subclass(of.Camera, OrbitCam, "cpp"),
    angle: f32 = 0,
    trail: std.ArrayList(of.Vec3) = .empty,

    pub const cpp_overrides = .{
        .{ of.Camera.begin_viewport, beginViewport },
        .{ of.Node.onPositionChanged, positionChanged },
    };

    fn beginViewport(self: *OrbitCam, viewport: *const of.Rectangle) void {
        self.angle += 0.01;
        cpp.bind(of.Camera.begin_viewport)(&self.cpp.base, viewport); // "super"
    }

    fn positionChanged(self: *OrbitCam) void { ... }

    /// Runs before ~ofCamera(), as a C++ destructor body would.
    pub fn cpp_destroy(self: *OrbitCam) void {
        self.trail.deinit(gpa);
    }
};

var orbit: OrbitCam = .{ .cpp = undefined };
orbit.cpp.init();          // ofCamera(), then OrbitCam's vtables
defer orbit.cpp.deinit();  // cpp_destroy, then ~ofCamera()
```

- `cpp_overrides` pairs each override with the signature it overrides, from any
  class in the chain. It is a list rather than a naming convention because C++
  overloads virtual functions and Zig cannot. The method takes `*Outer`, then the
  parameters of `bind`'s function other than `this`, and returns what it returns.
  So a `.managed_copy` result arrives as an out-pointer to construct it in, and a
  `.managed_copy` argument as a pointer the method borrows. The argument is
  destroyed after the method returns, by whichever side the ABI makes responsible.
- `cpp_destroy` is the destructor body. `cpp_free` releases the memory when C++
  deletes the object; without it, a `delete` from C++ panics, because C++ cannot
  know how Zig allocated it.
- `init` runs the base's default constructor, `initWith(ctor, args)` another one.
  In a safe build, either checks the vtables the constructor installed against the
  computed layout first, and panics naming the slot if a `cpp_virtuals` list is
  wrong. `initChecked` returns the mismatch instead, in any build.

The vtables are `const` arrays built at comptime. A slot holds an adapter for an
override, a generated destructor, or the base's own definition. C++ never names
the Zig type, only the base, so the RTTI is the base's: `dynamic_cast` to the base
or above works, and `typeid` names the base. A base whose vtable was compiled
without RTTI declares `cpp_no_rtti = true`.

A base with pure virtual functions is abstract, and a `Subclass` of it must
override every one, as in C++; one it leaves out is a compile error.

The base destructor runs through the base's own vtable, not by name. An implicit
destructor often has no symbol of its own: in an optimized build, MSVC folds it into
the deleting destructor, and Itanium points the vtable at the base's destructor
instead. An abstract base is the exception. Clang emits all of an abstract class's
destructors except the base-object one as traps, the ones in its vtable included,
because C++ never calls them. So an abstract base is destroyed by name, and if its
destructor is implicit, declare its `Signature` so that the glue emits it. A base
whose destructor is not virtual has no slot, and is taken to have a trivial one.

A virtual call from inside the base constructor or destructor reaches the base, as
in C++. An object that registers its own address somewhere cannot move; one that
does not can, since its vtables are static.

## Glue

`cpp-bindgen` can generate a C++ translation unit for your bindings. It does two
things no Zig code can do for itself:

- **It makes header-only definitions exist.** A class template specialization, a
  function template specialization, an inline function, an inline member: none of them
  has a symbol until some translation unit emits one, and a header alone never does.
  The glue is that translation unit.
- **It checks every layout fact your bindings assert**, in the C++ compiler, against
  the real class: size, alignment, member offsets, `cpp_abi` category, and for a
  class with bases, that each base is one and that it and each base are polymorphic
  exactly as declared. Those are what a binding gets wrong, and a `static_assert`
  turns a silent memory corruption into a compile error.

Your bindings file holds types and signatures and nothing else. The headers and
the wiring go in `build.zig`:

```zig
const cpp_bindgen = @import("cpp_bindgen");            // in build.zig
const dep = b.dependency("cpp_bindgen", .{ .target = target });

const bindings = b.createModule(.{ .root_source_file = b.path("src/bindings.zig"), .target = target });
bindings.addImport("cpp_bindgen", dep.module("cpp_bindgen"));
exe_mod.addImport("bindings", bindings);               // your code needs this anyway

cpp_bindgen.addCppGlue(b, dep, .{
    .attach_to = exe_mod,
    .binding_module = bindings,
    .headers = &.{"counter.hpp"},
    .target = target,
});
```

`addCppGlue` compiles the glue into `attach_to`, so it inherits that module's
include paths. The generated file goes through the cache and never lands in your
source tree.

Everything the glue needs to be *correct* it carries in its own source, so the only
thing left to get right is matching the rest of your C++. That is what `std` and
`flags` are for:

- `std` is the C++ language version, `"c++17"` by default. It has to be the one the
  rest of your C++ is built with. A header that gates a member, an operator, or a
  layout on `__cplusplus` describes a *different class* at a different version, and
  then the facts the glue checks and the definitions it emits are not the ones that
  will be linked. Pass `null` to name no `-std` at all.
- `flags` is everything else, appended after `std`, so a later flag wins if you would
  rather spell the version there. Give it the same defines as the rest of your C++:
  the facts it checks are only the facts that will be linked if it sees the same
  declarations.

To place the glue yourself instead, `generateCppGlue` takes the same options minus
`attach_to`, `std`, and `flags`, and returns the path:

```zig
const glue = cpp_bindgen.generateCppGlue(b, dep, .{
    .binding_module = bindings,
    .headers = &.{"counter.hpp"},
    .target = target,
});
lib_mod.addCSourceFile(.{ .file = glue, .flags = &.{ "-std=c++17", "-DNDEBUG" } });
```

That is the way to compile the glue into a library of its own, into more than one
module, or to install it with `addInstallFile` and read what your bindings actually
asked the C++ compiler. The file needs no particular flags to be correct: the stubs
that would otherwise be optimized away carry `[[clang::optnone]]`, and the one
warning it provokes is suppressed in the file. On a compiler with no
`[[clang::optnone]]`, it says so with an `#error` rather than failing at link time.

## What the scan finds

Starting from `binding_module`, every public declaration is examined:

- A **type** carrying `cpp_name` or `cpp_template` gets the layout checks, and a
  `cpp_template` also gets an explicit instantiation.
- A **`Signature` constant** gets a forced definition.
- A **namespace** — a struct with no fields that is not itself a C++ class — is
  walked in turn. That is what a `pub const string = @import("string.zig");` is, so
  a bindings set split across files needs no extra build wiring.

Then each type found is walked the same way, so a class's methods can be declared on
the class. The same function reached twice is emitted once.

```zig
pub const Counter = extern struct {
    n: c_int,
    pub const cpp_name = "inl::Counter";

    // Declare a Signature for anything header-only, and bind that same value:
    // the glue and the call can then never describe different functions.
    pub const get: cpp.Signature = .{ .name = "get", .ret = c_int, .this = *const @This() };
};

// A free function's signature goes at file scope.
pub const add: cpp.Signature = .{ .name = "inl::add", .args = &.{ c_int, c_int }, .ret = c_int };

// A second binding file, reached by being re-exported.
pub const string = @import("string.zig");
```

Bind through the constant, `cpp.bind(Counter.get)`, rather than calling `bindMethod`
directly: a bound function pointer cannot yield back the signature that produced it,
so a `bindMethod` call site is invisible to the scan.

Only *public* declarations are visible, so a private `const std = @import("std")`
cannot drag the standard library into the walk. A public one would.

Two declarations steer the glue, both on the Zig type:

- `cpp_no_instantiate` — do not explicitly instantiate this specialization.
  Instantiating a class template instantiates *every* member, including ones that do
  not compile for these arguments, which is a real hazard for a standard-library
  container.
- `cpp_no_offsets` — check the size and the alignment but not the member offsets.

A field whose name starts with `_` is skipped: that is how a binding spells a vtable
pointer, a virtual base, or tail padding, none of which is a member `offsetof` can
name.

## Limits

- A call that needs a wrapper takes its arguments as a tuple past ten parameters:
  `f(.{ a, b, ... })` rather than `f(a, b, ...)`. Ten or fewer is a plain call.
- A binding that needs a wrapper is a Zig function, so it has Zig's calling
  convention rather than `callconv(.c)`. Whether a signature needs one depends on
  the ABI, so write `const f = cpp.bind(...)` and let the type be inferred.
- A `TParam` is understood as a whole parameter, as the pointee of a reference, or as
  a template argument of another type. Nowhere else.
- On AArch64, a function that returns a class through a hidden pointer fails to
  compile.
- A class with a virtual base cannot declare `cpp_bases`: the base has no fixed
  offset. Spell its layout by hand, and reach the base through a C++ thunk.
- `Subclass` does not support virtual bases, or `delete[]` from C++.
- The library reads no headers. You write each signature, and you keep it correct
  when the C++ changes. The glue checks the types; it cannot check a signature.
- The glue generator runs on the build machine, so it needs a target the build
  machine can execute. It is built for the target rather than for the host because
  the sizes it checks are the target's.

## Tests

```bash
zig build test
```

The tests compile `test/fixture.cpp` into the test binary, so a wrong mangled name
fails at link time. They also compare every name to a golden name from clang. A second
test binary binds `test/inline_fixture.hpp`, which defines everything inline and so has
no symbols of its own: it links only because the generated glue emitted them. Both
bind base-class methods through derived pointers, including one whose base is not at
offset 0, and `src/inherit.zig` checks the computed base placement against numbers
read from clang's `-fdump-record-layouts` for the same C++. `src/vtable.zig` checks
its computed slot layouts against `-fdump-vtable-layouts`, then against the real
vtables of `test/vtable_fixture.cpp`, and makes virtual calls through them;
`src/subclass.zig` subclasses those classes from Zig and drives the subclasses from
the C++ side. `test/vtable_optimized.cpp` is compiled with `-O2`, as a release build
of a C++ library would be. On a Windows x86_64 host
with MSVC and the Windows SDK, `zig build test-msvc` repeats all of it with the MSVC
ABI, where those numbers differ.

The library needs Zig 0.17.0-dev.1683+5ceec001b or later.

## License

MIT. See [LICENSE](LICENSE).
