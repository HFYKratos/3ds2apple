# darwin-stubs — minimal ISO C headers for the no-SDK GamePack cross-build

Part of 3ds2apple (Apache-2.0).

These headers let **upstream Clang cross-compile 3dsrecomp-generated C for iOS**
without any Apple SDK, iPhoneOS `.sdk`, `.tbd` stub library or Apple header.
They are hand-written from the ISO C standard (C99/C11) — no Apple file was
copied, and none may be: Apple's SDK is not redistributable.

## Why this works

`tools/winbuild/build-gamepack.sh` compiles every generated `.c` with:

```sh
clang -target arm64-apple-ios16.0 -O2 -fPIC -fvisibility=hidden \
      -nostdinc \
      -isystem "<llvm>/lib/clang/21/include" \
      -isystem "tools/winbuild/darwin-stubs/include" \
      -I <generated-C-dir> -c codeNNN.c -o codeNNN.o
```

* `-nostdinc` removes the host C library headers entirely.
* `<llvm>/lib/clang/21/include` is Clang's own freestanding resource-header set
  (that is where the working `<stdint.h>`, `<stddef.h>`, `<stdarg.h>`,
  `<stdbool.h>`, `<limits.h>`, `<float.h>` come from) — part of the LLVM
  release, not Apple.
* This directory supplies the few hosted headers the 3dsrecomp output uses.
  Every libc/math function stays **declared but undefined**; the dylib links
  with `-undefined dynamic_lookup`, so the call is resolved from libSystem when
  the signed shell app calls `dlopen()`. That is how the Xcode-built GamePack
  already behaves: the shipped 0.2.0-beta1 pack has only `_zk_register_gamepack`
  and `dyld_stub_binder` as undefined imports.

## What the real Pokemon Y generated C needs (verified 2026-11-14)

Survey over all 489 generated `.c` files (637 MB):

| system header | why | calls |
|---|---|---|
| `<string.h>` | `recomp.h` memory helpers (`memcpy`) | inlined or emitted per use |
| `<math.h>` | VFP `sqrt` emulation | `sqrtf` x362 |
| `<stdint.h>` | fixed-width types throughout | Clang resource header, no stub needed |

Nothing calls `printf`/`malloc` in this game's AOT output, but the stubs cover
the C99 hosted set anyway so other 3dsrecomp games and future codegen work
without a Mac.

## Files

| File | Notes |
|---|---|
| `string.h` | mem*/str* incl. `strdup`, `strtok_r`, `strerror` |
| `math.h` | full C99/C11 double/float/long double math set + `M_PI`-style constants + classification macros via `__builtin_*` |
| `stdlib.h` | malloc/free/abort/exit/strto*/qsort/bsearch/abs/div |
| `stdio.h` | `FILE` opaque, printf family, file I/O (future codegen; not used by Pokemon Y) |
| `assert.h` | `assert` via libSystem's `__assert_rtn` |

## Rules when extending a stub

1. **Declarations only** — never define a libc function in a stub: a definition
   would be linked into the pack and silently shadow libSystem's version.
2. **ABI-correct prototypes** — a wrong or implicit declaration corrupts 64-bit
   pointers or float returns. Keep `float`/`double` return types exact.
3. **Standard ISO C names only** — Darwin-only private APIs are not part of the
   stable iOS ABI; do not declare them because they exist on macOS.
4. Add the file name + reason to the table above, and re-run
   `tools/winbuild/build-gamepack.sh --selfcheck` plus a real generated-C build.

The fallback when something is missing: check whether the call survives at
`-O2` (many are inlined); if it does, the symbol appears as an undefined import
and `tools/winbuild/check-gamepack.py` lists it as an "unexpected undefined
import" so it cannot be missed.
