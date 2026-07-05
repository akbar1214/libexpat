# Migration Plan: libexpat C → Zig

## Overview

**Total scope:** ~40,689 lines of C across 38 source files + 36 headers
**Strategy:** Incremental module-by-module, keeping the C API via `export fn`
**Approach:** Convert leaf modules first, maintain the same `expat.h` public interface

---

## Key Concepts: Zig's C Interop

Zig can call C functions natively and export functions with C calling convention. This enables incremental migration — you can mix C and Zig in the same build.

### Exporting Zig to C

```zig
// Export a function with C ABI
export fn my_function(arg: c_int) c_int {
    return arg + 1;
}
```

C consumers call it like any normal C function:
```c
extern int my_function(int arg);
```

### Calling C from Zig

```zig
const c = @cImport({
    @cInclude("stdlib.h");
});

const result = c.malloc(1024);
```

### Extern Structs (C-compatible layout)

```zig
// Regular Zig struct — compiler controls layout
const ZigPoint = struct { x: f64, y: f64, label: u8 };

// C-compatible struct — guaranteed C layout (field order, padding)
const CPoint = extern struct { x: f64, y: f64, label: u8 };
```

### Replacing #ifdef with comptime

```zig
// C: #ifdef XML_DTD ... #endif
// Zig:
fn parse(config: Config) void {
    if (config.dtd) {
        // DTD code — compiled out when dtd = false
    }
}
```

### Error Handling Across C Boundary

Zig error unions can't cross the C boundary. Use C-style return codes:
```zig
export fn XML_Parse(...) c_int {
    // Return 1 for success, 0 for error (matching expat convention)
}
```

### Zig 0.16.0 Random API

`std.crypto.random` was removed in Zig 0.16.0. Use platform-specific alternatives:
```zig
const c = std.c;

// For arc4random_buf (macOS, BSD, glibc ≥2.36)
pub export fn writeRandomBytes_arc4random_buf(target: ?*anyopaque, count: usize) void {
    c.arc4random_buf(@ptrCast(target), count);
}

// For getentropy (macOS, BSD, glibc ≥2.17)
pub export fn writeRandomBytes_getentropy(target: ?*anyopaque, count: usize) c_int {
    return c.getentropy(@ptrCast(target), count);
}
```

### Symbol Emission with Lazy Compilation

Zig uses lazy compilation — unreferenced imports are discarded. Force symbol emission:
```zig
// In the root file (lib.zig)
const random_module = @import("random.zig");
comptime {
    _ = &random_module;  // Forces all pub exports in the module to be emitted
}
```

---

## Codebase Analysis

### File Sizes and Complexity

| Module | Files | Lines | Notes |
|---|---|---|---|
| Core library (`lib/`) | 12 .c + 18 .h | ~13,586 + ~3,150 | 4 compilation units |
| xmlwf tool (`xmlwf/`) | 8 .c + 6 .h | ~2,414 + ~310 | 3-4 compilation units |
| Tests (`tests/`) | 15 .c + 12 .h | ~19,022 + ~1,726 | 1 test runner binary |
| Examples (`examples/`) | 3 .c | ~481 | 3 example binaries |
| **Grand Total** | **38 .c + 36 .h** | **~40,689 lines** | |

### Dependency Graph

```
                expat.h  (public API — 55 functions)
                    |
                xmlparse.c  (9,319 lines — the monolithic parser)
               /    |    \
              /     |     \
      xmltok.h  xmlrole.h  siphash.h
         |        |           |
      xmltok.c  xmlrole.c   (hash table impl)
       /    \
xmltok_impl.c  xmltok_ns.c   (textual #includes)
      |
nametab.h, asciitab.h, utf8tab.h, iascitab.h, latin1tab.h
```

### Public API (expat.h)

55 public functions + 1 function-like macro. Key categories:
- **Parser Lifecycle (5):** XML_ParserCreate, XML_ParserFree, etc.
- **Parsing (3):** XML_Parse, XML_GetBuffer, XML_ParseBuffer
- **Handler Setters (26):** XML_SetElementHandler, XML_SetCharacterDataHandler, etc.
- **Configuration (9):** XML_SetEncoding, XML_SetBase, etc.
- **Query/Info (9):** XML_GetErrorCode, XML_GetCurrentLineNumber, etc.
- **Memory (3):** XML_MemMalloc, XML_MemRealloc, XML_MemFree
- **Attack Protection (4):** Billion laughs protection (conditional on XML_DTD/XML_GE)

### Platform-Specific Code

| Component | Windows | Unix/macOS | Notes |
|---|---|---|---|
| `random_rand_s.c` | `rand_s()` | — | Windows only |
| `random_getrandom.c` | — | `getrandom()`/syscall | Linux ≥3.17 |
| `random_getentropy.c` | — | `getentropy()` | BSD/macOS/glibc ≥2.17 |
| `random_arc4random_buf.zig` | — | `arc4random_buf()` | BSD/macOS/glibc ≥2.36 (Zig) |
| `random_dev_urandom.c` | — | `/dev/urandom` | All non-Windows |
| `unixfilemap.c` | — | `mmap()` | Unix file mapping |
| `win32filemap.c` | `CreateFileMapping()` | — | Windows file mapping |
| `codepage.c` | `MultiByteToWideChar()` | — | Windows codepage |

### Compile-Time Feature Flags

| Flag | Occurrences in xmlparse.c | Purpose |
|---|---|---|
| `XML_DTD` | 82 | Parameter entity parsing, DTD support |
| `XML_NS` | 2 | Namespace processing |
| `XML_UNICODE` | many | UTF-16 vs UTF-8 mode |
| `XML_LARGE_SIZE` | several | 64-bit line/column numbers |
| `_WIN32` | 3 | Windows-specific code |

---

## Migration Phases

### Phase 1: Leaf Modules (1-2 days)

**Goal:** Learn Zig patterns by converting the simplest, most isolated files.

| Order | File | Lines | Difficulty | Status |
|---|---|---|---|---|
| 1a | `lib/random_arc4random_buf.c` + `.h` | 47 | Easy | **Done** |
| 1b | `lib/random_arc4random.c` + `.h` | 56 | Easy | **Done** |
| 1c | `lib/random_getentropy.c` | 60 | Easy | |
| 1d | `lib/random_dev_urandom.c` | 72 | Easy | |
| 1e | `lib/random_getrandom.c` | 95 | Medium | |
| 1f | `lib/random_rand_s.c` | 88 | Easy | |

**Approach for each:**
1. Write a `.zig` file that `export fn`s the same C symbol
2. Use `std.c` or `std.os` for system calls, or `@cImport` for C headers
3. Remove the C file from `build.zig` sources, add the `.zig` file
4. Run `zig build test` to verify

**Example — converting `random_arc4random_buf.c`:**

The C version:
```c
#include "random_arc4random_buf.h"
#include <stdlib.h>
void writeRandomBytes_arc4random_buf(void *target, size_t count) {
    arc4random_buf(target, count);
}
```

The Zig version (what we actually wrote):
```zig
const std = @import("std");
const c = std.c;

pub export fn writeRandomBytes_arc4random_buf(target: ?*anyopaque, count: usize) void {
    c.arc4random_buf(@ptrCast(target), count);
}
```

The root file that imports it:
```zig
// expat/lib/lib.zig
const random_arc4random_buf = @import("random_arc4random_buf.zig");
comptime {
    _ = &random_arc4random_buf;  // Force symbol emission
}
```

**Build change in `build.zig`:**
```zig
// 1. Set root_source_file on the library module
const expat = b.addLibrary(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("expat/lib/lib.zig"),  // <-- NEW
        // ...
    }),
});

// 2. Remove the C file from random_srcs
// random_arc4random_buf.c is replaced by random_arc4random_buf.zig (imported via lib.zig)

// 3. For test exe that compiles C sources directly, build a small Zig library and link it
const expat_random = b.addLibrary(.{
    .linkage = .static,
    .name = "expat_random",
    .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("expat/lib/lib.zig"),
    }),
});
test_exe.root_module.linkLibrary(expat_random);

// 4. In the C source that used the header, replace #include with extern declaration
// #if defined(HAVE_ARC4RANDOM_BUF)
//   extern void writeRandomBytes_arc4random_buf(void *target, size_t count);
// #endif
```

**What you'll learn:**
- `export fn` for C ABI exports — must use `pub` and C-compatible types (`?*anyopaque` not `[*]u8`)
- Zig's standard library: `std.c.arc4random_buf` (NOT `std.crypto.random` which doesn't exist in 0.16.0)
- How to mix C and Zig sources in build.zig via `root_source_file`
- `comptime { _ = &module; }` to force lazy compilation to emit symbols
- Zig executables with C `main` can't use `root_source_file` pointing to Zig — build a small Zig library and link it via `root_module.linkLibrary()`
- `linkLibrary()` on `Build.Step.Compile` was removed in Zig 0.16.0 — use `root_module.linkLibrary()` instead
- C header files can be replaced with inline `extern` declarations in the C source

**Phase 1a completed: 2026-07-05. All 4824 tests pass. C file and header fully removed; Zig replacement used by both library and test builds.**

---

### Phase 2: xmlrole.c (2-3 days)

**Goal:** Port a medium-complexity module with internal dependencies.

| File | Lines | Dependencies |
|---|---|---|
| `lib/xmlrole.c` | 1,255 | `xmltok.h` (ENCODING type), `internal.h`, `ascii.h` |
| `lib/xmlrole.h` | 62 | `xmltok.h` |

**Approach:**
1. Port `xmlrole.h` to `xmlrole.zig` — define the ENCODING type as extern
2. Port `xmlrole.c` state machine to Zig `switch` statements
3. Export the same C functions (XmlPrologStateInit, XmlTokenRole, etc.)
4. Keep importing `xmltok.h` via `@cImport` for the ENCODING type

**What you'll learn:**
- Zig's `switch` replacing C state machines
- C interop types (`extern` structs, function pointers)
- Working with C headers from Zig

---

### Phase 3: xmltok.c + xmltok_impl.c + xmltok_ns.c (1-2 weeks)

**Goal:** Port the tokenizer — the hardest module due to `#include` tricks.

| File | Effective Lines | Complexity |
|---|---|---|
| `lib/xmltok.c` | 1,674 | High — includes impl files multiple times |
| `lib/xmltok_impl.c` | 1,820 | High — tokenizer implementation |
| `lib/xmltok_ns.c` | 123 | Low — namespace wrappers |

**Challenge:** `xmltok_impl.c` is `#include`d 2-3 times with different `#define` configurations to generate UTF-8, UTF-16, and Latin-1 variants.

**Zig solution:** Use `comptime` to generate the variants:
```zig
fn XmlTokImpl(comptime encoding: Encoding) type {
    return struct {
        // Single implementation, parameterized by encoding
        fn contentTok(...) ... { ... }
    };
}
```

**Approach:**
1. Port the encoding types and lookup tables (pure data)
2. Port one encoding variant using comptime generics
3. Generate all variants from the single implementation
4. Export the same C API

**What you'll learn:**
- Zig's `comptime` replacing C's `#include`-with-macros pattern
- Lookup table generation
- Encoding handling

---

### Phase 4: xmlparse.c (3-4 weeks)

**Goal:** Port the core parser — the largest and most complex file (9,319 lines).

| Component | Lines | Complexity |
|---|---|---|
| Hash table (siphash) | ~200 | Medium |
| Internal data structures | ~500 | Medium |
| Parsing core | ~3,000 | High |
| DTD/entity handling | ~2,500 | High (conditional on XML_DTD) |
| Namespace processing | ~500 | Medium (conditional on XML_NS) |
| Public API (55 functions) | ~2,000 | Medium |
| Memory management | ~500 | Medium |
| Error handling | ~500 | Low |

**Approach:**
1. Port `siphash.h` first (self-contained hash function)
2. Port internal data structures as `extern struct`
3. Use comptime config to replace `#ifdef XML_DTD` / `#ifdef XML_NS`
4. Port hash table functions
5. Port parsing core incrementally
6. Port public API as `export fn`

**What you'll learn:**
- Large-scale Zig code organization
- `comptime` for feature flags
- Complex struct relationships
- Memory management patterns

---

### Phase 5: xmlwf CLI Tool (1 week)

**Goal:** Port the command-line tool using Zig's cross-platform abstractions.

| File | Lines | Notes |
|---|---|---|
| `xmlwf/xmlwf.c` | 1,371 | Main CLI |
| `xmlwf/xmlfile.c` | 301 | File reading |
| `xmlwf/readfilemap.c` | 147 | Portable file mapping |
| `xmlwf/unixfilemap.c` | 108 | Unix mmap |
| `xmlwf/win32filemap.c` | 121 | Windows mapping |
| `xmlwf/xmlmime.c` | 193 | MIME handling |
| `xmlwf/codepage.c` | 98 | Windows codepage |

**Approach:**
1. Use `std.fs` for file I/O (eliminates platform-specific file mapping)
2. Use `std.process` for CLI argument parsing
3. Use `std.encoding` for codepage handling

**What you'll learn:**
- Zig's cross-platform standard library
- CLI tool development
- Eliminating `#ifdef` with platform abstractions

---

### Phase 6: Tests (1-2 weeks)

**Goal:** Port the 19,022-line test suite.

**Approach:**
1. Port `minicheck.c` (test framework) first
2. Port shared utilities (`common.c`, `chardata.c`, `handlers.c`)
3. Port test files starting with `basic_tests.c` (largest)
4. Option A: Keep C-style test runner (faster migration)
5. Option B: Convert to Zig `test "name" { ... }` blocks (cleaner long-term)

**What you'll learn:**
- Zig's testing patterns
- Test organization

---

### Phase 7: Examples & Benchmark (1 day)

Port the 3 example programs and benchmark tool. Straightforward translation.

---

## Realistic Timeline

| Phase | Effort | Complexity | Prerequisites |
|---|---|---|---|
| Phase 1: Random sources | 1-2 days | Low | None |
| Phase 2: xmlrole | 2-3 days | Low-Medium | Phase 1 |
| Phase 3: xmltok | 1-2 weeks | High | Phase 2 |
| Phase 4: xmlparse | 3-4 weeks | Very High | Phase 3 |
| Phase 5: xmlwf | 1 week | Medium | Phase 4 |
| Phase 6: Tests | 1-2 weeks | Medium | Phase 4 |
| Phase 7: Examples | 1 day | Low | Phase 4 |
| **Total** | **~2-3 months part-time** | | |

---

## Recommended Starting Point

Start with **Phase 1a** (`random_arc4random_buf.c` — 47 lines). This teaches:
1. Writing `.zig` files that export C symbols — use `pub export fn` with C-compatible types
2. Using Zig's build system to mix C and Zig — set `root_source_file` on `createModule()`
3. `comptime { _ = &module; }` to force symbol emission from unreferenced imports
4. Zig 0.16.0 random API: `std.c.arc4random_buf`, NOT `std.crypto.random` (removed)
5. For test executables with C `main`: build a small Zig library and link it via `root_module.linkLibrary()`
6. Replace C headers with inline `extern` declarations when removing header files

---

## Build System Strategy

As each module is converted, update `build.zig`:
1. Create `expat/lib/lib.zig` as the Zig entry point (or update it if it already exists)
2. Import the new `.zig` module in `lib.zig` with `comptime { _ = &module; }`
3. Set `root_source_file = b.path("expat/lib/lib.zig")` on the library module
4. Remove the C source file from `addCSourceFiles()`
5. Keep `link_libc = true` for system API access during transition
6. For test executables that compile C sources directly, build a small Zig library and link it via `root_module.linkLibrary()`
7. Replace C header includes with inline `extern` declarations in the C source
8. Once all C is gone, `link_libc` can be removed if no C stdlib is needed

---

## Risk Mitigation

1. **Test after every module conversion** — the existing 4,824 tests provide excellent coverage
2. **Keep the C API identical** — `export fn` ensures binary compatibility
3. **Don't rush xmlparse.c** — it's 69% of the library; convert it last among core modules
4. **Use comptime for feature flags** — cleaner than maintaining `#ifdef` equivalents
5. **Keep expat.h as the contract** — both C and Zig code conform to it
