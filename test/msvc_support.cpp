// The MSVC-ABI test binaries link no C++ runtime: the MSVC one lives in
// `VC\Tools\MSVC\<ver>\lib\x64`, which Zig does not put on the library search
// path, and naming it would pin the test suite to one machine.
//
// A virtual destructor needs the deleting form, which calls `operator delete`.
// Nothing else here uses the heap.
#include <stddef.h>

void operator delete(void*, size_t) noexcept {}
