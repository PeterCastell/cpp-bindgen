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
  `.c_struct`, `.trivial_copy`, and `.managed_copy`.
- `cpp_virtual_dtor` — the destructor is virtual. Only MSVC mangles the difference.
- `cpp_virtual_bases` — the class has virtual bases. MSVC mangles it; on Itanium it
  also selects the complete-object constructor and destructor, since a class without
  virtual bases binds the base-object ones.

The default `cpp_abi` is `.c_struct`. That value is correct for plain data, and wrong
for a class with a constructor, a destructor, or a virtual function. Declare the
value for every such class.

Bind a constructor as a method named `"*"`, and a destructor as `"~"`. Both run on
storage that you supply. The Zig type must have the size and the alignment of the C++
object, because the library reads no headers. `addCppGlue` checks that for you.

## Glue

`cpp-bindgen` can generate a C++ translation unit for your bindings. It does two
things no Zig code can do for itself:

- **It makes header-only definitions exist.** A class template specialization, a
  function template specialization, an inline function, an inline member: none of them
  has a symbol until some translation unit emits one, and a header alone never does.
  The glue is that translation unit.
- **It checks every layout fact your bindings assert**, in the C++ compiler, against
  the real class: size, alignment, member offsets, and `cpp_abi` category. Those are
  what a binding gets wrong, and a `static_assert` turns a silent memory corruption
  into a compile error.

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
include paths. Give it the same defines as the rest of your C++ through `flags`: the
facts it checks are only the facts that will be linked if it sees the same
declarations. The generated file goes through the cache and never lands in your
source tree.

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

- A call that needs a wrapper takes at most 10 parameters.
- A `TParam` is understood as a whole parameter, as the pointee of a reference, or as
  a template argument of another type. Nowhere else.
- On AArch64, a function that returns a class through a hidden pointer fails to
  compile.
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
no symbols of its own: it links only because the generated glue emitted them. On a
Windows x86_64 host with MSVC and the Windows SDK, `zig build test-msvc` repeats both
with the MSVC ABI.

The library needs Zig 0.17.0-dev.1683+5ceec001b or later.

## License

MIT. See [LICENSE](LICENSE).
