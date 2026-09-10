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

## Classes

A Zig type describes its C++ class through public declarations:

- `cpp_name` — the qualified name, such as `"ns::Counter"`.
- `cpp_template` — a `Template` value in place of `cpp_name`, for a specialization
  such as `tpl::vec<3, float, highp>`.
- `cpp_kind` — struct, class, union, or enum. Only MSVC mangles this difference.
- `cpp_abi` — how the ABI passes and returns the class by value. The three values are
  `.c_struct`, `.trivial_copy`, and `.managed_copy`.
- `cpp_virtual_dtor` and `cpp_virtual_bases` — two more facts that MSVC mangles.

The default `cpp_abi` is `.c_struct`. That value is correct for plain data, and wrong
for a class with a constructor, a destructor, or a virtual function. Declare the
value for every such class.

Bind a constructor as a method named `"*"`, and a destructor as `"~"`. Both run on
storage that you supply. The Zig type must have the size and the alignment of the C++
object, because the library reads no headers.

## Limits

- A call that needs a wrapper takes at most 10 parameters.
- On AArch64, a function that returns a class through a hidden pointer fails to
  compile.
- The library reads no headers. You write each signature, and you keep it correct
  when the C++ changes.

## Tests

```bash
zig build test
```

The tests compile `test/fixture.cpp` into the test binary, so a wrong mangled name
fails at link time. They also compare every name to a golden name from clang. On a
Windows x86_64 host with MSVC and the Windows SDK, `zig build test-msvc` repeats the
tests with the MSVC ABI.

The library needs Zig 0.17.0-dev.1683+5ceec001b or later.

## License

MIT. See [LICENSE](LICENSE).
