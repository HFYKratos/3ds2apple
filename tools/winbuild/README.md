# winbuild — local GamePack cross-build with open-source LLVM + LLD (no macOS SDK)

Part of 3ds2apple (Apache-2.0). Status: **prototype proven on a Linux/WSL host
(2026-11-14, task-22)**; the Windows equivalents use the same official LLVM
release and the same command lines (see below). Not wired into the launcher yet.

This directory is the no-Apple-SDK answer to: *can a Windows launcher compile a
3dsrecomp-generated C game into an arm64 iOS GamePack dylib without a Mac?*

**Yes, technically and legally** — but it is not a drop-in replacement for the
macOS/Xcode path yet. It replaces the iPhoneOS SDK with hand-written ISO C stub
headers and `-undefined dynamic_lookup`, and Apple's `ld64` with LLVM's
`ld64.lld`. No Apple file is used, copied or redistributed.

## Result at a glance (measured on the prototype host, 2026-11-14)

Host: WSL2 Ubuntu 26.04 x86_64, 16 logical CPUs, LLVM 21.1.8 from Ubuntu debs
(clang + ld64.lld + llvm-ar + llvm-nm + llvm-objdump), no Apple SDK, no Xcode.
Input: the real Pokemon Y 3dsrecomp output (`build/game/pokemon-y`, 637 MB,
489 `.c` + 136 `.h`, gitignored).

| Artifact | Command | Result |
|---|---|---|
| device GamePack | `tools/winbuild/build-gamepack.sh pokemon-y --code-dir build/game/pokemon-y --title-id 0004000000055E00 --target device --out build/winbuild --jobs 16` | **230,000,000-ish bytes Mach-O arm64 dylib**, `platform ios`, `minos 16.0`, install name `@rpath/GamePack-0004000000055E00.dylib`, 11 exports (GamePack ABI + recomp tables), **1** undefined import (`_zk_register_gamepack`), sha256 `8c03c33882189f810cbce2089ee20176a21900dab431402020e085d3327fbce2` |
| simulator GamePack | same with `--target sim` | **270,093,816 B** x86_64 Mach-O, `platform iossimulator`, sha256 `41a470ea4471c77868786391301311aeb7249cf29666cf1a4491e92506303162`; **dlopen-tested in the iOS Simulator** (10 min 16 s wall / 148 min 49 s CPU with `--jobs 16`) |
| toolchain selfcheck | `tools/winbuild/build-gamepack.sh --selfcheck` | 30 checks, 0 failures (both targets: compile, link, ABI exports, undefined host symbol, Mach-O validation) |

Full build wall time: **9 min 10 s** with `--jobs 16` (135 min 51 s user CPU; the
compile is CPU-bound, about 6 s of CPU per 1.1-1.3 MB generated file).

### Compared with the Xcode-built 0.2.0-beta1 pack (same game)

The shipped `GamePack-0004000000055E00.dylib` from the macOS/Xcode pipeline
(218,224,144 bytes, extracted for comparison from the local test IPA) and this
LLVM/LLD build are structurally identical:

| Property | Xcode pipeline | winbuild (LLVM 21.1.8 + ld64.lld) |
|---|---|---|
| Mach-O | arm64 dylib, `NOUNDEFS DYLDLINK TWOLEVEL NO_REEXPORTED_DYLIBS` | identical flags |
| platform/minos | `ios` / `16.0` | `ios` / `16.0` (`sdk` 16.0 vs 26.5 — informational only) |
| install name | `@rpath/GamePack-0004000000055E00.dylib` | identical |
| exports | 11: `zk_gamepack_{title_id,abi_version,register}`, `recomp_{abi,generation,entry_count,entries,module_count,modules,origins,natives}` | identical set |
| undefined imports | `_zk_register_gamepack`, `dyld_stub_binder` | `_zk_register_gamepack` only (lld uses chained fixups, no stub binder) |
| size | 218,224,144 B | 229,999,112 B (+5.4%, upstream vs Apple codegen) |
| UUID | present | present |

Both dylibs resolve everything but `zk_register_gamepack` from the host app /
libSystem at `dlopen()` time. The runtime risk of the LLVM path is therefore
code generation quality, not the Mach-O format or ABI.

## Why this is legal and shippable (with the right packaging)

* **LLVM/Clang/lld** are open source under **Apache-2.0 WITH LLVM-exception**,
  i.e. redistributable in a Windows launcher when the official binaries are
  kept unmodified and the licence text + copyright notices are shipped (the
  same policy this repo already uses for official Impactor, MIT/MPL-2.0).
* **No Apple SDK** is used: `-nostdinc` + `tools/winbuild/darwin-stubs/include`
  (hand-written ISO C declarations) replace every SDK header; there is no
  `.tbd`, no stub library, no Xcode component on the build machine.
* **libSystem stays on the phone.** `-undefined dynamic_lookup` leaves libc /
  math / `__stack_chk_*` calls and `zk_register_gamepack` undefined; dyld
  resolves them from libSystem and the signed app when the shell loads the
  pack. This is not a new mechanism: the Xcode-built pack already relies on
  the same flag and the same undefined `zk_register_gamepack`.
* The generated C is *user-derived* game code; it is never committed and never
  distributed by the project (already the rule for `build/game/`).

Not redistributable, still required on the user side: Xcode/iOS SDK only if the
user chooses the macOS path, and the user's own ROM.

## Quick start

### Linux / WSL2 (what was tested)

```sh
# 1. toolchain: official LLVM 21.1.8 (release pins + sha256 in llvm-manifest.json).
#    No root needed on Ubuntu: unpack the distro packages into a private prefix.
tools/winbuild/fetch-llvm-ubuntu.sh --prefix "$HOME/.local/llvm-21"
export WINBUILD_LLVM_DIR="$HOME/.local/llvm-21/usr/lib/llvm-21/bin"

# 2. prove the toolchain works in 10 seconds on a fresh machine:
tools/winbuild/build-gamepack.sh --selfcheck

# 3. build one game from 3dsrecomp-generated C (same inputs as
#    scripts/build-game-pack.sh --code-dir on macOS):
scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00 --jobs 16
# -> build/winbuild/packages/0004000000055E00/GamePack-0004000000055E00.dylib

# other targets:
scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00 --target sim
```

`scripts/build-game-pack-llvm.sh` is the repo-facing wrapper: it defaults
`--code-dir` to `build/game/<name>` and `--out` to `build/winbuild` (gitignored);
everything else (title id, jobs, target, `--llvm-dir`, `--pack-bin`, `--dry-run`,
`--force`, `--no-record`) is passed to `tools/winbuild/build-gamepack.sh`.

### Windows 10/11

1. Install official LLVM 21.1.8 (SHA-256 pinned in `llvm-manifest.json`):
   `winget install LLVM.LLVM` or the NSIS installer
   `LLVM-21.1.8-win64.exe` -> `C:\Program Files\LLVM\bin`.
   No Visual Studio, Windows SDK, iTunes or Apple files are needed.
2. Get a POSIX shell for the script: Git for Windows (its bundled MinGit/Bash
   is enough; the launcher already bundles one) or use WSL2 (tested path).
   From Git Bash:

   ```sh
   export WINBUILD_LLVM_DIR="$(cygpath -u 'C:\Program Files\LLVM\bin')"
   tools/winbuild/build-gamepack.sh --selfcheck
   scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00 --jobs 8
   ```

   The launcher can instead run the same tools directly (no POSIX shell), see
   **Native Windows command lines** below.
3. `python3`/`py` is optional: `check-gamepack.py` gives the full Mach-O report;
   without Python the script falls back to `llvm-nm`/`llvm-objdump` checks.

## Native Windows command lines (for the C#/.NET launcher)

These are exactly what the script does; the launcher can spawn them directly
with `Process.Start` and pipe logs. `<LLVM>` = `C:\Program Files\LLVM\bin`.

```bat
rem 1. compile each generated .c (parallel across cores)
%LLVM%\clang.exe -target arm64-apple-ios16.0 -O2 -ffp-contract=off -fno-math-errno -w ^
  -fPIC -fvisibility=hidden -nostdinc ^
  -isystem "%LLVM%\..\lib\clang\21\include" ^
  -isystem "<repo>\tools\winbuild\darwin-stubs\include" ^
  -I "<code-dir>" -c "<code-dir>\codeNNN.c" -o "<obj-dir>\codeNNN.o"

rem 2. archive + compile the shim (not hidden: it exports the GamePack ABI)
%LLVM%\llvm-ar.exe rcs "<obj-dir>\librecomp.a" "<obj-dir>\*.o"
%LLVM%\clang.exe -target arm64-apple-ios16.0 -O2 -fPIC -nostdinc ^
  -isystem "%LLVM%\..\lib\clang\21\include" ^
  -isystem "<repo>\tools\winbuild\darwin-stubs\include" ^
  -I "<repo>\ios\zakuro-ios\include" -DZK_GAMEPACK_TITLE_ID=0x0004000000055E00ULL ^
  -c "<repo>\ios\zakuro-ios\gamepack\zk_gamepack_shim.c" -o "<work>\zk_gamepack_shim.o"

rem 3. link the Mach-O dylib with lld's ld64 (Apple ld64 is not needed)
%LLVM%\clang.exe -target arm64-apple-ios16.0 -dynamiclib -nostdlib -fuse-ld=lld ^
  -Wl,-undefined,dynamic_lookup -Wl,-dead_strip ^
  -Wl,-install_name,@rpath/GamePack-0004000000055E00.dylib ^
  -o "<out>\GamePack-0004000000055E00.dylib" "<work>\zk_gamepack_shim.o" "<obj-dir>\librecomp.a"

rem 4. validate (or: py -3 tools\winbuild\check-gamepack.py <dylib> --target device)
%LLVM%\llvm-nm.exe -gU "<out>\GamePack-0004000000055E00.dylib"
%LLVM%\llvm-objdump.exe --macho --private-headers "<out>\GamePack-0004000000055E00.dylib"
```

For the simulator target replace the triple with
`x86_64-apple-ios16.0-simulator` and the platform flags with
`ld64.lld -arch x86_64 -platform_version ios-simulator 16.0.0 16.0.0` (the
script handles this automatically).

## Validation

`tools/winbuild/check-gamepack.py` is a pure-Python Mach-O checker (no Apple
tools): thin 64-bit dylib, expected arch, `LC_BUILD_VERSION` platform
`ios`/`iossimulator` with minos >= 16.0, install name `@rpath/GamePack-<TITLE>.dylib`,
the 10 required GamePack ABI exports, `zk_register_gamepack` still undefined,
no Zakuro runtime symbol defined in the pack, and a JSON report that also lists
every other undefined import. The build script runs it automatically (or falls
back to llvm-nm/llvm-objdump checks). A failing check fails the build.

## Simulator proof (reference VM only)

`tools/winbuild/sim-probe/` is a tiny loader app that `dlopen()`s a
cross-built simulator GamePack inside the iOS Simulator, `dlsym()`s the GamePack
ABI, calls `zk_gamepack_register(1)` and asserts the host registration callback
receives the real recomp tables. It is the end-to-end proof that the Mach-O is
loadable on iOS's dyld and that `-undefined dynamic_lookup` resolves from the
host process.

**Result (2026-11-14, iPhone 17 Pro / iOS 26.5 simulator on the Intel build VM):**
PASS for the **full 270 MB Pokemon Y simulator pack built by this Linux toolchain**
- `dlopen` ok, `zk_gamepack_title_id` = `0004000000055e00`, `zk_gamepack_abi_version` = 1,
  `zk_gamepack_register(1)` = 0, host callback saw title ID, recomp ABI 5,
  generation 5, **entry_count=173131, module_count=133** and non-null entries/origins tables
  (the real Pokemon Y tables); a mismatched host ABI is rejected; `result: summary
  failures=0`, probe exit status 0. The same probe also passed on a 13 KB stand-in pack
  first (machinery check). The 270 MB sim dylib reached the VM as a 58 MB xz (sha256
  verified after decompression) because the dev-host -> build-host link is ~0.4 MB/s.

Run it on the macOS build VM (the probe host app is built with Xcode; the
GamePack under test is not):

```sh
# on the host that built the pack:
tools/winbuild/build-gamepack.sh pokemon-y --code-dir build/game/pokemon-y \
  --title-id 0004000000055E00 --target sim --out build/winbuild
# copy the sim dylib to the VM, then on the VM:
tools/winbuild/sim-probe/run-sim-probe.sh /path/to/GamePack-0004000000055E00.dylib
```

## Limits / open questions

* **Codegen is upstream LLVM, not Apple clang.** The Mach-O/ABI is identical and
  the undefined-symbol set matches, but the emitted machine code is not the
  same bytes. AOT correctness/performance must be validated by loading a pack
  in the simulator/device (the probe proves loading/registration, the game run
  proves execution semantics).
* **C only.** The generated code is C; no C++/Objective-C/Swift is involved and
  stubs cover ISO C only. A future C++ component would need libc++ headers and
  `-lc++` from the SDK — do not go there without a shipping review.
* **Stub coverage is demand-driven.** The real Pokemon Y output needs only
  `<stdint.h>` (Clang), `<string.h>` and `<math.h>`. Other games/future codegen
  may add calls; `check-gamepack.py` flags new undefined imports, and each new
  import must be either a libSystem symbol (fine, add the declaration) or a
  missing runtime dependency (not fine).
* **No code signature / no entitlement edits.** The dylib is unsigned, exactly
  like the macOS path before `scripts/package-ipa.sh`; the IPA signer
  (Impactor/Xcode) re-signs nested dylibs. Verify nested-framework re-signing on
  a real device (still an open product task, independent of this toolchain).
* **Platform metadata:** `sdk` in `LC_BUILD_VERSION` is set to 16.0 (we do not
  know the phone's SDK); dyld only checks `minos`/platform at load. `arm64e` is
  not emitted (device packs are plain `arm64`).
* **Windows-native run not executed in this session:** the Windows procedure is
  the same LLVM release + same commands, verified here through the official
  Ubuntu LLVM 21.1.8 build of the same compiler; run `--selfcheck` on the first
  Windows machine to confirm (it needs only the installer, no SDK).
* **Runtime symbol availability:** a symbol only resolved at `dlopen` because a
  libSystem exports it. Anything not in iOS's libSystem would make the pack fail
  to load; the probe catches this for the pack actually built.

## Licensing / redistribution checklist

* Bundle the **official unmodified LLVM release** (or install it on the user's
  machine); pin SHA-256 from `llvm-manifest.json` and verify before use.
* Ship `https://llvm.org/LICENSE.txt` (Apache-2.0 WITH LLVM-exception) and the
  LLVM copyright notice; add the component to `THIRD_PARTY.md`/`NOTICE` when the
  launcher starts bundling it (not done by this prototype because it bundles
  nothing).
* Never ship ROMs, generated C, GamePacks or IPAs; never ship Apple SDK files,
  `.tbd` stubs or Xcode components.
* `3dsrecomp` is run as a build tool only (no LICENSE upstream, do not vendor);
  generated C stays under the user's gitignored `build/`.

## Files

| Path | Role |
|---|---|
| `build-gamepack.sh` | main cross-build driver (compile, archive, link, validate, optional `--pack-bin` record) |
| `check-gamepack.py` | pure-Python Mach-O/GamePack ABI validator + JSON report |
| `darwin-stubs/include/*.h` | hand-written ISO C headers replacing the SDK headers (see its README) |
| `fetch-llvm-ubuntu.sh` | no-root LLVM install for Ubuntu/WSL from apt packages, SHA512-verified |
| `llvm-manifest.json` | pinned LLVM 21.1.8 release URLs + SHA-256 + licence facts + tool requirements |
| `sim-probe/` | iOS Simulator dlopen probe (host app built with Xcode on the reference VM) |
| `../../scripts/build-game-pack-llvm.sh` | repo-facing wrapper with the desktop AOT conventions |

## Next steps (for the Windows launcher, task-19/task-21)

1. Add a `LocalPackBuildProvider` that stages the ROM through 3dsrecomp (already
   Windows-runnable Rust) and calls this build path with bundled LLVM + MinGit,
   or directly spawns `clang.exe`/`ld64.lld.exe` (command lines above).
2. Wire `--pack-bin` so `3ds2apple-pack packages record` writes `GameInfo.json`
   (single schema writer, same as the macOS path).
3. Run the built pack in the simulator/device before enabling the provider for
   users; gate it behind a feature flag until AOT correctness is validated.
4. Add the LLVM component to `THIRD_PARTY.md`/`NOTICE` with the pinned SHA-256.
