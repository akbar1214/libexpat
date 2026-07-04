# AGENTS.md

## Build System

This project uses Zig as its build system (in addition to existing Autotools and CMake).

### Prerequisites

- **Zig 0.16.0** — managed via mise. Install with `mise use zig@0.16.0` or ensure `zig` is available on PATH.
- The `.mise.toml` at the repo root pins the Zig version for this project.

### Build Commands

```sh
zig build                      # Build static library (libexpat.a) in Debug
zig build -Doptimize=ReleaseFast  # Build optimized (production)
zig build -Dlinkage=shared     # Build shared library
zig build test                 # Run all tests (4824 checks)
zig build xmlwf                # Build the xmlwf CLI tool (to zig-out/bin/)
zig build examples             # Build example programs
zig build benchmark            # Run the benchmark (needs testdata/benchmark.xml)
```

### Build Options

| Option | Default | Description |
|---|---|---|
| `-Dlinkage=static\|shared` | `static` | Library link mode |
| `-Dns=true\|false` | `true` | XML Namespaces support |
| `-Ddtd=true\|false` | `true` | Parameter entity parsing |
| `-Dge=true\|false` | `true` | General entity parsing |
| `-Dchar-type=char\|wchar_t` | `char` | Character type |
| `-Dcontext-bytes=N` | `1024` | Context bytes around parse point |
| `-Dattr-info=true\|false` | `false` | Attribute byte offset info |
| `-Dlarge-size=true\|false` | `false` | 64-bit line/column numbers |
| `-Dmin-size=true\|false` | `false` | Smaller but slower parser |
| `-Dstrip=true\|false` | — | Omit debug information |
| `-Dpie=true\|false` | — | Position Independent Code |

### Zig Build System Notes

- The `build.zig` is adapted from the [allyourcodebase/libexpat](https://github.com/allyourcodebase/libexpat) reference packaging.
- This is the upstream source repo, so `b.path()` is used instead of `b.dependency()` for local paths.
- Random entropy source files (`lib/random_*.c`) must be conditionally compiled per target platform:
  - `random_arc4random_buf.c` — macOS, BSD, DragonFly
  - `random_getentropy.c` — macOS, BSD, glibc ≥2.17
  - `random_getrandom.c` — Linux with glibc ≥2.25 or musl, FreeBSD ≥12, NetBSD ≥10
  - `random_dev_urandom.c` — All non-Windows platforms
  - `random_rand_s.c` — Windows only
- The config header `expat_config.h` is generated from `expat/expat_config.h.cmake` using `addConfigHeader`.
- C++ test wrappers (`tests/*_cxx.cpp`) do not exist in version 2.8.2 — only C tests are built.
- `addPassthruArgs()` was removed in Zig 0.16.0; run steps no longer use it.
- The fingerprint in `build.zig.zon` must match Zig's computed value; use the suggested value from the compiler error on first build.
- The benchmark step passes default arguments (`testdata/benchmark.xml 4096 100`). Override by running the built binary directly.
- The xmlwf step only builds the tool (to `zig-out/bin/xmlwf`); it does not auto-run. Run it manually with a file argument.

### Key Files

- `build.zig` — Main Zig build script
- `build.zig.zon` — Project manifest
- `.mise.toml` — Zig version pin
- `expat/lib/` — Core library sources
- `expat/xmlwf/` — XML well-formedness checker
- `expat/tests/` — Test suite (C only, no C++ wrappers in 2.8.2)
- `expat/examples/` — Example programs
- `expat/expat_config.h.cmake` — Config header template used by Zig's `addConfigHeader`
