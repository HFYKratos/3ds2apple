# Building iOS game code on Windows — investigation and recommendation

> Status: investigation complete for the MVP, 2026-11-14 · task-19 ·
> companion to [windows-launcher.md](windows-launcher.md),
> [launcher-architecture.md](launcher-architecture.md) and
> [desktop-aot.md](desktop-aot.md).
>
> Question: can the Windows launcher compile a per-game AOT GamePack locally, the way S2Arm's
> Windows launcher does, or must it drive a macOS build host? Short answer (§§1-6, task-19):
> **the MVP pipeline uses a macOS toolchain; the Windows launcher drives the existing
> builder-windows Build Agent.** §7 (task-22) then proves a *phase-2* local no-Apple-SDK
> compile with open-source LLVM/LLD is technically feasible and legal; keep the MVP answer,
> see §7.7 for the recommendation update. No Apple SDK/binaries are redistributed by this
> project.
> use a macOS toolchain for the real compile; the Windows launcher drives the existing
> builder-windows Build Agent.** A Windows-side recomp split is a legal phase-2 optimization, not
> an MVP requirement. No Apple SDK/binaries are redistributed by this project.

## 1. What S2Arm does on Windows (studied from /mnt/f/project/S2Arm-study, Apache-2.0)

S2Arm is a **native port, not an emulator**: the game's own ARM64 code is rewritten at build time
and runs directly on the Apple ARM64 processor (README.md, "A native port, not an emulator"). Its
Windows launcher therefore never has to compile C or link a Mach-O dylib with Apple tooling.

Evidence read for this study:

| S2Arm path | What it shows |
|---|---|
| launchers/windows/launcher/README.md | Windows launcher is Avalonia/.NET 10, not WinUI; it drives a bundled jobs layer over JSON/NDJSON, plus winenv self-check, package export and sign/install pages |
| launchers/windows/bundle_win.py | distribution layout: Engine/ (pinned engine snapshot + prebuilt Binaries/Prepare), Runtime/ (bundled Python, .NET runtime, Git Bash/MinGit, zstd, licences), Shell/ (prebuilt shell), Fonts/, ThirdParty/Impactor/ (official Impactor + plumesign, SHA-256 pinned, MIT + MPL-2.0) |
| launchers/windows/bundle_prepare_win.py | prebuilt tools compiled once on the Windows packaging machine (C# tools, Rust devpush, C rewriter, shader tools) and shipped; player machines run no compiler |
| docs/windows_orch.md | the whole pack pipeline runs **on the Windows build machine**: unpack, rewrite, RomFS index, light stages, direct-profile, using MSVC/CMake/.NET/Git Bash and prebuilt components |
| pack/orch/oneclick_win.py | one-command Windows pipeline: source -> unpack -> eight light stages -> extraction + "direct library" -> iPhone/iPad package, all local |
| pack/jobs/WINDOWS_ENV.md | readiness contract: bundled .NET runtime, prebuilt tools, prebuilt shell, Metal Developer Tools for Windows (shader compiler), Apple Devices/iTunes, iCloud, Impactor; no Xcode required |
| pack/jobs/impactor.py, pack/orch/install_win.py | sign/install = official Impactor v2.7.2 GUI for the Apple ID sign-in, then the official plumesign CLI (same release, SHA-256 pinned) with --register-and-install; errors mapped to shared codes (9120, 9401, 1100, anisette, 2FA...) |
| pack/jobs/install.py (Windows branch) | push stage uses house_arrest + AFC on the app container; resources are copied into the installed container, not into the IPA |
| README.md (Windows row) | "Graphical launcher that builds and installs games for iPhone / iPad" on Windows |

Key property: **Switch games are AArch64**, and Apple devices are AArch64. S2Arm rewrites
NSO/NRO binaries into loadable native code and assembles a prebuilt iOS shell; the only
"compilers" involved on Windows are for their own C/C#/Rust tooling and for shaders (glslang,
spirv-cross, Apple Metal Developer Tools for Windows). They do not run Apple's clang and do not
need an iPhoneOS SDK on Windows. That is why one-click local Windows building is viable for them.

## 2. Why that model does not transfer to 3ds2apple

3DS games are **32-bit ARM11 (ARMv6K)** code. Apple ARM64 devices cannot execute that directly,
and iOS forbids JIT, so this project statically recompiles the game ahead of time:

    3dsrecomp (ROM -> generated C) -> Apple clang -target arm64-apple-ios -> libgame.a
      -> link GamePack.dylib (Mach-O arm64) against the Zakuro runtime
      -> one ROM-free shell app + per-game packs pushed into its container

The compile/link steps need Apple's iOS SDK and clang, which ship only with Xcode and may only be
used on Apple-branded hardware under Apple's licence. The SDK is not redistributable, so a
"bundled self-contained Windows cross toolchain" cannot be shipped legally by this project. That
is the hard constraint behind the recommendation below; it is a licensing and platform boundary,
not an engineering preference.

Existing infrastructure we already have:

| Piece | Where | Role for Windows |
|---|---|---|
| 3ds2apple-pack CLI | builder/pack (Rust) | runs on Windows: ROM header detection, packages, GameInfo.json, catalogue. Already used by the launcher. |
| Build Agent + builder-windows CLI | builder/agent, builder/core, builder/windows (Rust) | runs on macOS; uploads the user's ROM over SSH, runs scripts/ as a isolated job, streams logs, downloads the IPA, deletes inputs afterwards. Already run on Windows 11 by the earlier Builder slice. |
| AOT scripts | scripts/build-recomp-ios.sh, build-linked-ios-lib.sh, build-game-pack.sh, build-game-ipa.sh | macOS-only real compile; generate the per-game IPA/GamePack. |
| Device bridge | tools/devpush (task-16) | Windows-side install ABI: JSON/NDJSON CLI over usbmuxd + house_arrest + AFC, with progress and a 90 s stall watchdog. |
| Signing | official Impactor v2.7.2 + plumesign, bundled | Windows signing/install path; no custom signing, no Apple ID handling in our code. |

## 3. Viable options and licensing

| # | Option | How it would work | Licensing / practical verdict |
|---|---|---|---|
| A | **macOS Build Agent (recommended)** | Windows launcher calls builder-windows (or zkb) with --rom/--host; the user's Mac/VM runs the existing scripts; launcher downloads the result and extracts GamePack.dylib | Project code is Apache-2.0/MIT; Xcode/iOS SDK stay on the user's Mac under Apple's licence; nothing Apple is redistributed. Works today via the existing per-game IPA path (MVP), and is the base for a dedicated packbuild stage (below). |
| B | macOS host paired directly | same as A without SSH (local Mac) | Not applicable to a Windows PC; same licence story. |
| C | Rented/remote Mac | same as A, host is a cloud Mac the user controls | Same as A; the user is responsible for the host and its Apple licence. Launcher needs no change beyond host configuration. |
| D | Bundle a Windows cross toolchain (osxcross/LLVM + iPhoneOS SDK + libc++ headers) | compile generated C for arm64-apple-ios on the user's PC | **Not recommended / not shippable.** Apple SDK and Xcode components are not redistributable, and Apple's licence limits their use to Apple-branded hardware. Even when a hobbyist supplies their own SDK, the project cannot ship or support this path; it also multiplies toolchain support cost and makes signing/linking behaviour untestable here. |
| E | **Windows-side recomp, macOS-side compile (phase-2 optimization)** | build 3dsrecomp on Windows (Rust), run the ROM -> C translation locally, upload/stream only the generated C tree to the macOS Agent, compile/link there with Apple clang | Fully legal: 3dsrecomp has no LICENSE, so the project only runs it as a build tool and never vendors/redistributes its source (same rule as docs/desktop-aot.md). Generated C is game-derived and stays on the user's machines, never committed. Saves the expensive recomp time on the Mac, at the cost of a large C transfer (hundreds of MB) and a new "generate only" mode in scripts/build-recomp-ios.sh. Good follow-up, not needed for the MVP. |
| F | Ship prebuilt packs with the launcher | download a ready GamePack per game | Rejected: that is distributing compiled game code / ROM data. The product only ships tools; the user's own ROM is processed locally. |

Licence summary for the chosen path: Windows launcher + tools (this repo, Apache-2.0; MIT/Apache
components), Xcode/iOS SDK (user-provided, Apple licence, never redistributed), 3dsrecomp (no
licence: build tool only, not vendored), Impactor (MIT) + embedded apple-codesign (MPL-2.0,
unmodified official binary + licence text + source link in vendor/impactor/), devpush
(project code), Avalonia/.NET (MIT). No GPL/AGPL code is used or copied.

## 4. What the MVP implements (option A, today's Agent)

The Windows launcher already drives the existing builder-windows flow:

    builder-windows build --host <host profile> --rom <ROM> --name <slug> --display-name <name> --out <dir> --json
    # exit codes: 0 ok, 1 build failed, 2 usage/config, 3 transport, 4 canceled, 5 local I/O
    # streams protocol JSON events; the launcher shows them as build progress/log lines

The Agent builds the project's existing **per-game IPA** (3dsrecomp -> iOS clang -> link ->
xcodebuild/package). The launcher then:

1. finds the downloaded .ipa (newest *.ipa in the requested --out directory),
2. opens it as a zip, locates Payload/<app>.app/Frameworks/GamePack-<TITLEID>.dylib and
   GameCatalog.json, verifies the Mach-O magic (a --fake placeholder is rejected),
3. records the dylib into the local package with 3ds2apple-pack packages record, so the Rust
   CLI stays the single manifest/catalogue writer,
4. composes the installable app IPA on Windows: pinned ROM-free shell template +
   Frameworks/GamePack-<TITLEID>.dylib for every built game + generated GameCatalog.json
   (schema v2), then signs and installs that whole IPA with the bundled official plumesign.
   IPA signing covers the nested Frameworks dylibs, which is why the pack must NOT be pushed
   into Documents (iOS refuses to dlopen a loose unsigned dylib there),
5. pushes only the user's GameRom.cci + GameInfo.json into Documents/Games/<TITLEID>/ via
   devpush; those data files are expected to persist across an app recompose/overwrite
install (a clean uninstall clears them; verify on device).

This is explicitly labelled a transitional build path: it builds a whole per-game IPA just to
extract one GamePack. The phone never installs that per-game IPA; it installs the composed app
IPA (shell template + all packs), and only ROM data goes to Documents.

## 5. Recommended next step: a dedicated pod2packbuild Agent stage

Implement one new job type in builder/agent + builder/core (build-infra task), so the Windows
launcher stops building full IPAs:

Request (JSON uploaded with the job, paths are host-relative):

    {
      "schema": "packbuild/1",
      "romFile": "<uploaded ROM file name>",
      "titleID": "0004000000055E00",
      "displayName": "Pokemon Y",
      "productCode": "CTR-P-EK2A",
      "buildName": "pokemon-y-00055e00",
      "aotVersion": 1,
      "target": "device"
    }

Host steps (all inside the Agent's isolated per-job directory):

    scripts/build-recomp-ios.sh <buildName> --rom <romFile>
    scripts/build-linked-ios-lib.sh <buildName>
    scripts/build-game-pack.sh <buildName> --title-id <titleID> --display-name <displayName>         --product-code <productCode> --target device --out <jobDir>/out

Artifacts streamed back (NDJSON events, same style as the existing job protocol):

    stage/progress/log events with seq numbers
    artifact 0004000000055E00/GamePack.dylib   size + sha256
    artifact 0004000000055E00/GameInfo.json   size + sha256 (written by the Rust CLI)
    done { artifacts: [...], log, cancelled: false }

Failure semantics: non-zero exit + stage name + hint; the ROM and generated C are deleted at job
end by default (same cleanup rule as the existing Builder). The launcher then downloads the pack
dylib, records it, and includes it in the next composed app IPA; only game ROM data is pushed to
Documents. Launcher side is already prepared:
Core/BuildPipeline/BuildProviders.cs contains MacAgentPackBuildProvider, which currently refuses with a
clear "not implemented" message (no fake success); switching the default provider is a one-line
change once the Agent stage exists.

Optional phase-2: run 3dsrecomp on Windows (option E) and make the Agent stage accept a
pre-generated C tree (scripts/build-recomp-ios.sh --code-dir, which already exists on the macOS
side), cutting Mac wall time roughly to compile+link only.

## 6. Verification and evidence

Verified in this checkout (WSL, .NET 10 SDK 10.0.403, Rust):

- Launcher solution builds (0 errors); 35/35 unit tests pass; --self-test passes with only
  optional-tool warnings (see docs/windows-launcher.md for exact commands/results).
- The app-IPA composer is unit-tested with a synthetic template IPA + fake pack CLI: it injects
  Frameworks/GamePack-<TITLEID>.dylib, replaces GameCatalog.json with the generated catalogue
  (registrationSymbol/packABIVersion filled, bundle-relative packFile checked), preserves the
  template app entries, refuses a template containing Roms/, and rejects a catalogue whose
  packFile is not Frameworks/GamePack-<TITLEID>.dylib. It never writes game data into the IPA.
- The real device bridge tools/devpush (task-16) was built and exercised with its mock backend
  using the launcher's exact command shapes: capabilities (devpush/1, 16 commands, stallSeconds
  90), devices, app-attr, mkdir/put/ls/stat with begin/progress/done{remotePath,bytes,sha256} and
  an app_missing error carrying exitCode 5 + hint. No real USB/AFC transfer was run.
- The real desktop CLI was exercised end-to-end for the import contract: 3ds2apple-pack 0.1.0
  rom inspect and packages add/list on the local Pokemon Y.cci produced titleID
  0004000000055E00, productCode CTR-P-EK2A, ncsd container, 1,807,118,336 bytes, status
  queued/imported. The launcher parses exactly that JSON (unit test fixture is the real output).
- The official Impactor v2.7.2 asset digests returned by the GitHub REST API match the pinned
  SHA-256 values used by the launcher and PINS.json (checked 2026-11-14):
  Impactor-windows-x86_64-portable.exe f493cd99...e88ef (18,213,888 B),
  plumesign-windows-x86_64.exe b965e51a...a2fe0 (10,718,720 B).
- S2Arm study claims above are based on reading the files listed in section 1; no S2Arm code was
  copied (reference only, Apache-2.0; our license/notice obligations are unaffected).

Not verified here (explicit gaps, no success claimed):

- No real Windows machine in this environment: the Avalonia executable was not run on Windows,
  the self-contained win-x64 publish was not produced/run, and no installer/SmartScreen flow was
  tested.
- No real Apple ID signing or Impactor/plumesign run (no device here). The 9120/9401/1100 error
  mapping is unit-tested against tool text, not against a live Apple server.
- No real iPhone/iPad: devpush calls are compiled against the frozen contract and tested with a
  fake process layer; no AFC transfer was executed.
- No shell template IPA exists yet in this checkout; Shell/manifest.json + the ROM-free template
  IPA are supplied by the packaging step (shell/README.md) after a macOS build. The shell-side
  bundle-catalogue + Documents contract was agreed with task-17.
- The signed composed IPA was never installed on a real iPhone: that plumesign's IPA signature
  covers the nested Frameworks/GamePack dylibs is the architecture's key assumption and the first
  thing to verify on hardware (manual test plan item 9 in docs/windows-launcher.md).
- The Agent packbuild stage of section 5 is a design proposal; the existing per-game IPA path is
  the only implemented real build path.

## 7. Phase-2 prototype (task-22, 2026-11-14): local open-source LLVM/LLD GamePack build, no Apple SDK

> Status: **prototype proven on Linux/WSL** for the real Pokemon Y generated C, plus a
> simulator dlopen proof; not yet wired into the launcher and not yet runtime-validated
> with a running game. Full commands/evidence: [tools/winbuild/README.md](../tools/winbuild/README.md),
> [tools/winbuild/build-gamepack.sh](../tools/winbuild/build-gamepack.sh),
> [tools/winbuild/llvm-manifest.json](../tools/winbuild/llvm-manifest.json).

This section corrects the earlier option table: option D above rejected *bundling the iPhoneOS
SDK* (still correct — Apple's SDK/licence cannot be redistributed). It turns out the SDK is not
strictly needed for **3dsrecomp-generated C**: an official open-source LLVM release can compile
that C for arm64 iOS if the handful of ISO C headers it uses are supplied by us and libSystem
calls are left undefined with `-undefined dynamic_lookup` (which the Xcode pipeline already
uses for `zk_register_gamepack`). No Apple header, `.tbd`, stub library or Xcode file is used.

### 7.1 Result at a glance

| Check | Result (2026-11-14) |
|---|---|
| Toolchain | official LLVM **21.1.8** clang + `ld64.lld` + `llvm-ar`/`llvm-nm`/`llvm-objdump`; no Apple SDK, no Xcode |
| Input | real Pokemon Y 3dsrecomp output: `build/game/pokemon-y`, 637 MB, 489 `.c` + 136 `.h` (gitignored) |
| device pack | `arm64` Mach-O dylib, 229,999,112 B, sha256 `8c03c33882189f810cbce2089ee20176a21900dab431402020e085d3327fbce2`, `platform ios`, `minos 16.0`, install name `@rpath/GamePack-0004000000055E00.dylib`, 11 exports, 1 undefined import (`_zk_register_gamepack`) |
| build cost | 9 min 10 s wall / 135 min 51 s user CPU on 16 logical CPUs (`--jobs 16`); about 6 s CPU per 1.1-1.3 MB generated file |
| simulator pack | `x86_64-apple-ios16.0-simulator` Mach-O, 270,093,816 B, sha256 `41a470ea4471c77868786391301311aeb7249cf29666cf1a4491e92506303162`, `platform iossimulator`; **dlopen PASS in the iOS Simulator** (7.5), 10 min 16 s wall / 148 min 49 s CPU (`--jobs 16`) |
| selfcheck | `tools/winbuild/build-gamepack.sh --selfcheck` -> 30 checks, 0 failures (both targets) |
| Apple SDK use | **none**; only `tools/winbuild/darwin-stubs/include` (hand-written ISO C declarations) |

### 7.2 Compared with the Xcode-built pack from the shipping pipeline

The macOS/Xcode pipeline's 0.2.0-beta1 `GamePack-0004000000055E00.dylib` (218,224,144 B, extracted
locally for comparison) and the LLVM/LLD build are structurally identical:

| Property | Xcode pipeline | LLVM/LLD build |
|---|---|---|
| Mach-O type/flags | arm64 dylib, `NOUNDEFS DYLDLINK TWOLEVEL NO_REEXPORTED_DYLIBS` | identical |
| platform/minos | `ios` / `16.0` | `ios` / `16.0` (`sdk` 16.0 vs 26.5; informational only) |
| install name | `@rpath/GamePack-0004000000055E00.dylib` | identical |
| exports (11) | `zk_gamepack_title_id/abi_version/register` + `recomp_abi/generation/entry_count/entries/module_count/modules/origins/natives` | identical set |
| undefined imports | `_zk_register_gamepack`, `dyld_stub_binder` | `_zk_register_gamepack` only (LLD chained fixups need no stub binder) |
| size | 218,224,144 B | 229,999,112 B (+5.4%, upstream vs Apple codegen) |

So the Mach-O format, GamePack ABI and host-symbol contract match the macOS build; the remaining
difference is code generation (upstream LLVM vs Apple clang), which is a runtime-validation
question, not a linking/ABI question.

### 7.3 How it works (the exact replaceable pieces)

| macOS/Xcode step | no-SDK replacement |
|---|---|
| `clang -target arm64-apple-ios16.0 -isysroot <iphoneos.sdk>` | same clang target, `-nostdinc` + Clang builtin headers + `tools/winbuild/darwin-stubs/include` |
| SDK libc headers (`string.h`, `math.h`, ...) | hand-written ISO C declarations; functions stay undefined |
| Apple `ld64` via clang driver | `clang -dynamiclib -nostdlib -fuse-ld=lld` (LLVM `ld64.lld`, also usable directly) |
| `-lSystem` / SDK stub libs | not linked at all: `-Wl,-undefined,dynamic_lookup` (already used by the macOS build for `zk_register_gamepack`) |
| ad-hoc/Xcode code signing | not done; the IPA signer (Impactor/Xcode) re-signs nested dylibs |

The generated code contains no OS calls beyond `memcpy`/`memset`-style helpers and `sqrtf`
(survey: `<string.h>` from `recomp.h`, 362 `sqrtf` calls, `<stdint.h>`; no `printf`/`malloc` in
Pokemon Y's AOT output), so the stub surface is small and auditable. Every function that survives
`-O2` appears as an undefined import and `tools/winbuild/check-gamepack.py` flags anything outside
the expected libSystem set.

### 7.4 Reproduce (Linux/WSL prototype; Windows commands in tools/winbuild/README.md)

```sh
tools/winbuild/fetch-llvm-ubuntu.sh --prefix "$HOME/.local/llvm-21"   # no root; .debs SHA512-checked
export WINBUILD_LLVM_DIR="$HOME/.local/llvm-21/usr/lib/llvm-21/bin"
tools/winbuild/build-gamepack.sh --selfcheck                          # 30 checks, no ROM needed
scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00 --jobs 16
# -> build/winbuild/packages/0004000000055E00/GamePack-0004000000055E00.dylib
scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00 --target sim
python3 tools/winbuild/check-gamepack.py <dylib> --target device --title-id 0004000000055E00
```

Windows equivalent: install official LLVM 21.1.8
(`winget install LLVM.LLVM` or `LLVM-21.1.8-win64.exe`, SHA-256
`7a5386c26497db1691f320121e5b113364dd0274b98e55f15f4dbc00c0450113`, 374,129,373 B), then run
the same `scripts/build-game-pack-llvm.sh` from Git Bash/WSL, or spawn the
`clang.exe`/`ld64.lld.exe` commands directly from the launcher (documented in
tools/winbuild/README.md).

### 7.5 Simulator dlopen proof

`tools/winbuild/sim-probe/` builds a tiny host app **on the reference macOS VM** (Xcode is used
only for that host app), embeds the cross-built simulator GamePack in its bundle, boots the iPhone
17 Pro simulator, `dlopen()`s the pack, `dlsym()`s the GamePack ABI and asserts that
`zk_gamepack_register(1)` forwards the real recomp tables to a host-provided
`zk_register_gamepack`. This exercises the two risky assumptions end to end: iOS's dyld accepts
the LLD-produced Mach-O and `-undefined dynamic_lookup` resolves the host symbol from the app.

**Result: PASS (2026-11-14, iPhone 17 Pro / iOS 26.5 simulator, Intel VM).** The full 270 MB
Pokemon Y simulator pack built by the Linux LLVM/LLD toolchain was transferred to the VM
(sha256 verified `41a470ea...03162`), embedded in the probe app and loaded. Probe output:

```text
result: ok   dlopen
result: info pack title_id=0004000000055e00 pack_abi=1
result: info register title=0004000000055e00 recomp_abi=5 generation=5 entries=173131 modules=133
             entries_ptr=0x134540010 origins_ptr=0x1347e5560
result: info zk_gamepack_register(1) = 0
result: ok   host zk_register_gamepack called exactly once
result: ok   host saw the pack title ID / recomp ABI / generation / tables
result: ok   a mismatched host ABI is rejected
result: summary failures=0
== probe exit status: 0
```

The same probe first passed on a 13 KB stand-in pack (machinery check), then on the 270 MB
real pack; the simulator was shut down afterwards. This proves the Mach-O/ABI/dyld/dynamic_lookup
half of the no-SDK path; it does not yet prove that the LLVM-generated AOT machine code runs a
game correctly (the pack registers tables, but no game frame was executed under it).

### 7.6 Licensing, redistribution and limits

* LLVM/clang/lld are **Apache-2.0 WITH LLVM-exception** and redistributable; when the launcher
  bundles them keep the official unmodified binaries, pin SHA-256 (llvm-manifest.json), ship
  `https://llvm.org/LICENSE.txt` + copyright notice, and add the component to
  `THIRD_PARTY.md`/`NOTICE`. No Apple SDK file may ever be bundled; this path needs none.
* The generated C is user-derived; it stays in the user's gitignored `build/` and is never
  committed or distributed. 3dsrecomp is still run as a build tool only (no LICENSE upstream).
* **Not runtime-validated yet:** the pack loads and registers, but a full game run on this codegen
  is not part of this prototype. Before enabling a local-build provider for users, run the pack in
  the simulator harness/shell and on a device (AOT active, 0% interpreted) and compare frame
  behaviour against the macOS-built pack.
* **C only, demand-driven stubs:** no C++/ObjC/Swift; other games or future codegen may need more
  libc declarations (extend `darwin-stubs`, never define libc functions).
* **Unsigned output:** signing stays with the existing Impactor/Xcode IPA step; nested-dylib
  re-signing on device is still the open product item from task-19/launcher-architecture.
* **`sdk` metadata is 16.0** (we do not know the phone SDK); dyld only enforces platform/minos.
  Plain `arm64` (not `arm64e`).
* **Not yet run on a real Windows host:** the Windows procedure uses the same official LLVM
  release/commands; the prototype executed the Ubuntu LLVM 21.1.8 build of the same compiler.
  `--selfcheck` is the intended first-run gate on Windows (installer only, no SDK).

### 7.7 Recommendation update

Keep **option A (macOS Build Agent) as the MVP default**; the S2Arm-style local build is not a
drop-in replacement yet because its codegen/runtime has not been validated with a running game.
Add this as **option D2, a phase-2 optional local build backend** behind a launcher feature flag:
it removes the Mac from the loop for users who need it, is fully legal (open-source LLVM, no Apple
files), and reuses the existing GamePack ABI, `zk_gamepack_register`, catalogue and signing flow.
Evidence for this section is reproducible from the gitignored artifacts under `build/winbuild/`
(dylib + `GamePack-check.json` + build logs); nothing game-derived was committed.
## 8. End-to-end proof (task-26, 2026-11-15): ROM → C on the PC → LLVM GamePack → real shell AOT run

> Status: **passed in this environment** (Linux/WSL host + the reference macOS VM simulator).
> The Windows launcher provider is implemented, unit-tested and feature-flagged; Windows-native
> execution of 3dsrecomp/LLVM still needs a first-run smoke test on a real Windows PC.
> Commands: [tools/winbuild/README.md](../tools/winbuild/README.md) §"3dsrecomp on the same PC".

§7 proved the *link* half (generated C → Mach-O with LLVM/LLD, no Apple SDK) and that the Mach-O
loads/registers in the iOS Simulator. This section proves the two halves the product needs: the
**recompiler on the PC** and **LLVM-generated GamePack code running in the real shell**, not just a
dlopen probe.

### 8.1 3dsrecomp on the host (ROM → generated C)

3dsrecomp is a Rust CLI; upstream documents Linux and Windows support ("You need Rust and a C
compiler … gcc from MinGW-w64 … works" on Windows). The only iOS-specific piece is its compile step:
it runs `$CC` with `-O2 -ffp-contract=off -fno-math-errno -w -fPIC -fvisibility=hidden -c`, so we set
`CC` to our arm64-iOS clang + Darwin stubs and `AR` to `llvm-ar` (new helper
`tools/winbuild/recomp-port.sh` + `tools/winbuild/darwin-cc.sh`):

```sh
git clone https://github.com/fearkov/3dsrecomp third_party/3dsrecomp   # pinned df82e6e
(cd third_party/3dsrecomp && cargo build --release)                    # 6.7 s on the host
tools/winbuild/recomp-port.sh "ROM/Pokemon Y.cci" build/game/pokemon-y-host
# -> 489 .c + 136 .h (635 MiB) and arm64 objects, no Apple SDK
```

**Evidence (host, 2026-11-15):**

* 3dsrecomp `df82e6e` generated **624 files / 635 MiB of C** from the user's own Pokémon Y ROM
  (gitignored `build/game/pokemon-y-host/`).
* Combined SHA-256 over all generated `.c/.h` files:
  `4a58182e96c6557a39f018152faed113fe495adeb0d24ac611eb12e130e80363`, **identical** to the tree
  the same revision generated on the macOS VM — deterministic across hosts.
* `recomp.h` reports `RECOMP_ABI 5`, the interface version the runtime accepts.

**Windows recipe** (what the launcher does, no bash): 3dsrecomp splits `CC` on spaces and runs the
first word as the compiler program, so the launcher sets
`CC=clang.exe --target=arm64-apple-ios16.0`, `AR=<llvm>\llvm-ar.exe`,
`CPATH=<repo>\tools\winbuild\darwin-stubs\include`, `PATH=<llvm>\bin;%PATH%` and runs
`3dsrecomp.exe port <rom> <work>\recomp --name <slug>`. Building 3dsrecomp on Windows needs the Rust
toolchain (upstream: MinGW-w64 gcc/clang for its compile step; rustup's MSVC target needs the Visual
Studio C++ build tools). That recipe is documented and its command construction unit-tested, but it
has **not been executed on a real Windows host** in this environment.

### 8.2 GamePacks from the host-generated C (byte-identical to the VM path)

| Artifact | Command | Result |
|---|---|---|
| device pack | `tools/winbuild/build-gamepack.sh pokemon-y --code-dir build/game/pokemon-y-host/code --target device` | 229,999,112 B arm64, sha256 `8c03c33882189f810cbce2089ee20176a21900dab431402020e085d3327fbce2` — **byte-identical** to the task-22 pack built from VM-generated C; 9 min 9 s with `--jobs 16` |
| simulator pack | same with `--target sim` | 270,093,816 B x86_64, sha256 `61a1d89bafb7c92cb7fa59033821d0ca5e51d2ba5cc42217ca665d22617ae943`; 9 min 21 s |

The simulator pack differs from the task-22 sim pack (sha `41a470ea…`) in exactly **8 bytes: the
`LC_UUID`**; `cmp` finds 8 differing bytes and the only load-command difference is the UUID, while
code/data/symbols/exports are identical (`diff` of `llvm-objdump --private-headers`/`llvm-nm`).
ld64.lld chooses that UUID; it has no runtime meaning.

### 8.3 Runtime correctness in the real shell and harness (iOS Simulator, fresh pack)

The fresh simulator pack (`61a1d89b…`) was embedded in both Simulator apps
(`scripts/build-ios-app-sim.sh --game-pack … --game-title-id 0004000000055E00`), the user's own ROM
was placed in the app container (fixture), and both apps ran on iPhone 17 Pro / iOS 26.5 x86_64
(software PICA200; the VM has no Metal):

**Harness** (`ios/sim`, drives the runtime headlessly and now logs the runtime's own AOT accounting
*after 60 frames*; the log line is test-only evidence, it is not shown to users):

```text
gamepack: GamePack-0004000000055E00.dylib: dlopen OK
gamepack: title id 0004000000055E00 / pack ABI 1 (host ABI 1)
gamepack: registered with the runtime; AOT code is active
zk_recompiled: 1 (1 = Zakuro is running AOT code)
zk_linked_code: 1 (1 = AOT code is available to this build)
zk_recompiled_status: AOT active: linked code for title 0004000000055E00, 173131 entry points,
  133 modules, 0 instruction fallbacks, interpreted 0.00% of 19294073 instructions
```

**Shipping shell** (`ios/app`, the real SwiftUI shell, launched with the debug hooks
`-gamesRoot Documents/GamesFixtures -openAOTTitleID 0004000000055E00`):

```text
[3ds2apple] game catalog: GameCatalog.json · schemaVersion 2 · 1 game(s), 1 built
[runtime] zk_register_gamepack: accepted title 0004000000055E00
[runtime] zk_create: AOT active: linked code, 173131 entry points, 133 modules, 0 instruction fallbacks
[3ds2apple] AOT linked=1 recompiled=1 program=0x0004000000055E00 status=AOT · package
[3ds2apple] starting Pokemon Y from …/GamesFixtures/0004000000055E00/GameRom.cci
```

The shell has no interpreter fallback, so AOT-active + running frames is the LLVM-codegen
correctness gate at load/registration/first-frames level; the harness reports the runtime's own
instruction accounting: **0.00% interpreted of 19,294,073 instructions, 0 fallbacks**, matching the
Xcode-built pack's expectations (software renderer ~4-5 fps, no Metal). The simulator was shut down
afterwards (`simctl shutdown all`; verified no booted device). Raw logs are kept in the gitignored
`build/winbuild-host/evidence/` (`sim-harness-fresh-pack.log`, `sim-shell-fresh-pack.log`).

### 8.4 Windows launcher: feature-flagged LocalPackBuildProvider

`launcher/windows` implements the local build behind an off-by-default flag
(`LauncherStateDocument.LocalBuildEnabled`, Settings checkbox). Flow: 3dsrecomp port under the
CC/CPATH environment above → shim compile + `ld64.lld` link (`-platform_version ios 16.0.0`,
`-undefined dynamic_lookup`, `@rpath/GamePack-<TITLE>.dylib`) → thin-arm64 Mach-O check →
`3ds2apple-pack packages record`. See [windows-launcher.md](windows-launcher.md) §13 for the tool
requirements, readiness row and limitations. Tests: 6 provider tests + full suite **63/63**
(`dotnet test`, .NET 10); Core + Avalonia Desktop build 0 warnings / 0 errors. The macOS Build Agent
stays the supported, default path.

### 8.5 Residual gaps (honest)

* **No real Windows PC here:** 3dsrecomp-on-Windows and the launcher provider were exercised via the
  identical command lines on Linux plus unit tests; the first Windows smoke test (build 3dsrecomp with
  rustup, `tools/winbuild/build-gamepack.sh --selfcheck`, one real pack) is still required.
* **No device AOT run** (no iPhone here): the simulator proves load/registration/instruction
  accounting; a phone run (AOT active, ~0% interpreted, playable frames) remains device acceptance.
* **3dsrecomp has no upstream LICENSE file** (Cargo.toml declares MIT). It is cloned at a pinned
  revision at build time, run only as a build tool, never vendored and never redistributed; that is
  why the shipping recipe builds it on the user's PC with rustup instead of bundling a binary.
* Device/simulator outputs stay distinct (`GamePack-<TID>.dylib` vs `GamePack-<TID>-sim.dylib`) so
  one output root can hold both.

### 8.6 Recommendation update (after task-26)

Keep **option A (macOS Build Agent) as the supported default**. The local path is now proven
end-to-end for ROM → C → pack → **simulator AOT run (0.00% interpreted)** and is implemented in the
Windows launcher behind a flag. Promote it after (1) a real-Windows smoke test and (2) a device AOT
acceptance run. No Apple SDK is involved anywhere in the local path; the LLVM toolchain is
redistributable under Apache-2.0 WITH LLVM-exception (THIRD_PARTY/NOTICE updated in this task).

