# Build and run the 3ds2apple runtime in the iOS Simulator

This guide builds a **simulator** variant of the Zakuro runtime and runs it in
the iOS Simulator of the Intel macOS build VM. The device build described in
[build.md](build.md) is unchanged; the simulator needs a separate x86_64 static
library because the VM's Simulator is x86_64 and cannot link the arm64 device
slice.

Measured on 2026-11-14: macOS 26.7.3 VM, Xcode 26.6 / iOS 26.5 SDK, iPhone 17
Pro simulator (UDID `3CBF5A62-AE12-47E8-803D-1D77BED85A66`), Rust 1.100.0,
upstream Zakuro `2fcb9fa`.

## Result at a glance

| Piece | State in the Simulator |
|---|---|
| `build/ios/libzakuro_ios_sim.a` | **works** — x86_64, 61 MB, 39 `zk_*` exports |
| HLE kernel + CPU interpreter | **works** — `zk_create` boots a ROM and `zk_run_frame` advances frames |
| Software PICA200 renderer + CPU readback | **works** — the default path; `zk_read_screen` returns pixels |
| Shipping SwiftUI shell (`ios/app`) | **builds and launches** (x86_64, built from the shared checkout); the in-flight AOT-only shell shows its empty-catalog home screen, so runtime drive is done through the harness |
| MoltenVK / Metal hardware renderer | **not available on this VM** — the VM has no Metal device (see below); the runtime falls back to software |
| `CAMetalLayer` presentation / Metal HUD | **not available** for the same reason |

The simulator library is built with the same feature set as the device library
(Cranelift shader JIT off, Vulkan code compiled in), so it is a drop-in runtime
for the shell. It only differs in the target triple.

## 1. Build the simulator runtime library

```bash
scripts/build-zakuro-ios-sim.sh
```

Outputs:

```text
build/ios/libzakuro_ios_sim.a          x86_64-apple-ios static library
build/ios/libzakuro_ios_sim.info.txt   target, build time, rustc, Zakuro commit
```

The script is the simulator sibling of `scripts/build-zakuro-ios-sim.sh`:
it clones/patches `third_party/zakuro` if needed (same local patches as the
device build), copies `ios/zakuro-ios` into the checkout, disables the shader
JIT and builds the `zakuro-ios` staticlib for `x86_64-apple-ios`. The device
library `build/ios/libzakuro_ios.a` is not touched.

Useful knobs:

```bash
ZAKURO_DIR=/path/to/zakuro scripts/build-zakuro-ios-sim.sh   # existing checkout
CARGO_BUILD_JOBS=2 scripts/build-zakuro-ios-sim.sh           # leave the VM headroom
ZAKURO_SIM_TARGET=aarch64-apple-ios-sim scripts/build-zakuro-ios-sim.sh  # Apple-silicon Simulator
```

The script verifies the produced archive with `lipo`/nm and fails if the slice
is wrong or `zk_run_frame` is missing. On a normal Mac `rustup target add
x86_64-apple-ios` is enough; on the build VM that download was extremely slow,
so the script skips `rustup` when `$(rustc --print sysroot)/lib/rustlib/x86_64-apple-ios/lib`
already exists. To install the target offline (what the VM does):

```bash
# on a host with a fast link, fetch the component (30 MB):
curl -LO https://rsproxy.cn/dist/rust-std-1.100.0-x86_64-apple-ios.tar.xz
# copy it to the VM, then install it into the toolchain's sysroot:
tar -xJf rust-std-1.100.0-x86_64-apple-ios.tar.xz
SYSROOT="$(rustc --print sysroot)"
cp -R rust-std-1.100.0-x86_64-apple-ios/rust-std-x86_64-apple-ios/lib/rustlib/x86_64-apple-ios \
      "$SYSROOT/lib/rustlib/"
```

## 2. Build the Simulator apps

```bash
scripts/build-ios-app-sim.sh                 # shipping shell + runtime harness
scripts/build-ios-app-sim.sh --app harness   # harness only (fast)
scripts/build-ios-app-sim.sh --app shell     # shipping shell only
```

Outputs (all under the gitignored `build/`):

```text
build/sim/shell/out/Release-iphonesimulator/3ds2apple.app
build/sim/harness/out/Release-iphonesimulator/3ds2apple-sim-harness.app
```

Both are unsigned, `-sdk iphonesimulator -arch x86_64`, and link
`build/ios/libzakuro_ios_sim.a`. The script prepends `/usr/local/bin` (where
xcodegen lives on the build VM) to `PATH`, so it also works from a non-login
SSH session.

The script does **not** edit `ios/app/project.yml` or `ios/app/Sources`: it
copies the spec into `build/sim/shell/`, rewrites the source/resource/bridging
paths to absolute ones, swaps `-lzakuro_ios` for `-lzakuro_ios_sim` and
generates a throw-away Xcode project there. `xcodegen` and `xcodebuild` logs
stay under `build/sim/`.

### The runtime harness (`ios/sim/`)

The shipping shell is written for a person: it needs a tap in the library to
start a ROM, and the Simulator cannot be tapped headlessly from the command
line. `ios/sim/` is a tiny development app (bundle id
`com.kratos.3ds2apple.sim`) that bypasses the UI and drives the real runtime
directly on the same static library:

1. probes Metal and logs `MTLCreateSystemDefaultDevice` / `MTLCopyAllDevices`;
2. finds the first `.cci`/`.3ds` in `Documents/roms`;
3. calls `zk_create(rom, Documents/data)`, then runs `zk_run_frame` in a loop,
   reading both screens with `zk_read_screen` and showing them with SwiftUI;
4. writes every log line to `Documents/sim-harness.log` (also `NSLog`) and
   saves PNG evidence under `Documents/frames/`;
5. logs per-second `perf: frames=… fps=… frame_min/max/avg` lines and a
   "Press A" button that exercises `zk_set_input`.

## 3. Run it on the Simulator

Always start `caffeinate` on the VM first (idle sleep kills both SSH and the
Simulator), and shut the Simulator down when done:

```bash
nohup caffeinate -dimsu >/dev/null 2>&1 &        # on the VM

UDID=3CBF5A62-AE12-47E8-803D-1D77BED85A66
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b               # 3-4 minutes on this VM
xcrun simctl list devices | grep Booted
```

Install the harness and seed a ROM into its container. ROMs are user-owned,
local-only test data: never commit them, never put them in the repo, and remove
the seeded copy when done.

```bash
xcrun simctl install "$UDID" build/sim/harness/out/Release-iphonesimulator/3ds2apple-sim-harness.app
CONTAINER=$(xcrun simctl get_app_container "$UDID" com.kratos.3ds2apple.sim data)
mkdir -p "$CONTAINER/Documents/roms"
cp "/path/to/your/rom.cci" "$CONTAINER/Documents/roms/"
```

Launch it (the `--console-pty` stream also shows the harness log):

```bash
xcrun simctl launch --console-pty "$UDID" com.kratos.3ds2apple.sim
```

In a second shell, capture a screenshot and pull the log/PNG evidence:

```bash
xcrun simctl io "$UDID" screenshot /tmp/sim-harness.png
CONTAINER=$(xcrun simctl get_app_container "$UDID" com.kratos.3ds2apple.sim data)
cp "$CONTAINER/Documents/sim-harness.log" /tmp/
cp -R "$CONTAINER/Documents/frames" /tmp/sim-frames/ 2>/dev/null || true
```

The shipping shell can be installed the same way; putting a ROM into
`Documents/roms` makes it appear in the library after a relaunch (that is the
on-device flow). Driving a game from the shell needs a tap, which is why the
harness exists.

```bash
xcrun simctl install "$UDID" build/sim/shell/out/Release-iphonesimulator/3ds2apple.app
SHELL_CONTAINER=$(xcrun simctl get_app_container "$UDID" com.kratos.3ds2apple data)
mkdir -p "$SHELL_CONTAINER/Documents/roms"
cp "/path/to/your/rom.cci" "$SHELL_CONTAINER/Documents/roms/"
xcrun simctl launch "$UDID" com.kratos.3ds2apple
xcrun simctl io "$UDID" screenshot /tmp/sim-shell-home.png
```

Cleanup:

```bash
xcrun simctl shutdown all
xcrun simctl terminate "$UDID" com.kratos.3ds2apple.sim 2>/dev/null || true
```

## 4. What is measured / expected results

> Filled in from the 2026-11-14 run; the evidence files are listed in
> [§7](#7-evidence-from-the-2026-11-14-run). Numbers are for one ROM
> (Pokémon Y, interpreter path, software renderer) on the 6-vCPU VM.

- Metal probe inside the Simulator (iOS 26.5, SIMULATOR_MODEL_IDENTIFIER
  `iPhone18,1`): `MTLCreateSystemDefaultDevice=nil` and
  `MTLCopyAllDevices=[]` — **no Metal device exists in the Simulator on this
  VM**, so MoltenVK cannot initialise here.
- `zk_create` (Pokémon Y, 1.80 GB, interpreter build): **0.32 s**.
- first frame: **137 ms**; `zk_read_screen` returns 384,000 B (top 400×240) and
  307,200 B (bottom 320×240).
- steady-state frame loop on the game's boot screens: **4.5–5.2 fps**,
  ~195–215 ms/frame (e.g. `frames=277 fps=5.12 frame_min=175.37ms
  frame_max=202.76ms frame_avg=195.24ms`). This is interpreter + software
  PICA200; a real device without linked AOT behaves the same way.
- `scripts/build-zakuro-ios-sim.sh`: 3m01s cold (all x86_64 dependencies),
  ~57 s incremental.
- harness `xcodebuild`: ~1 min; shipping-shell `xcodebuild`: ~1–2 min. Both
  succeeded for `x86_64-apple-ios-simulator` from the shared checkout with no
  linker errors against `libzakuro_ios_sim.a`.
- Simulator boot: ~1–2 min on the restarted 8-vCPU VM (3–4 min on the old
  6-vCPU setup). CoreSimulator still spikes the VM load while booting: shut the
  Simulator down after each run and never run it during another heavy build.
- Rendering proof: the harness screenshot shows the game's language-select
  screen on both 3DS screens, with the harness overlay reading
  `running: 277 frames, 5.1 fps` (see §7).

## 5. Why the GPU path cannot be exercised on this VM

The iOS Simulator does not have its own GPU: Metal calls in the Simulator are
serviced by the **host Mac's Metal device**. The build VM is a virtual machine
with a virtual display adapter (3 MB VRAM); there is no Metal device at all:

```text
$ cat /tmp/metalprobe.swift
import Metal
print(MTLCreateSystemDefaultDevice() as Any, MTLCopyAllDevices())
# (on the VM host, 2026-11-14)
MTLCreateSystemDefaultDevice: nil
all devices: []
```

Consequences:

- `ZAKURO_IOS_HARDWARE` builds would still fall back to the software PICA200
  renderer; the loader deliberately warns and continues ("hardware rendering was
  requested but no Vulkan device started; the 3D draws in software").
- MoltenVK cannot be exercised: there is no `MTLDevice` to create a
  `VkInstance`/`VkDevice`/`CAMetalLayer` swapchain for. This is a property of
  the VM, not of the x86_64 slice: the same `libzakuro_ios_sim.a` built for a
  Metal-capable Mac (or a device build) contains the same Vulkan/MoltenVK path.
- The simulator run therefore validates the **interpreter + software renderer +
  readback** path, which is exactly the device fallback path for ROMs without
  linked AOT code.
- `ios/sim` logs the probe from inside the Simulator so this limitation is part
  of every run's evidence, not just a claim in a document.

To test hardware rendering, run the same code on real hardware (device build) or
on a Metal-capable Apple-silicon Mac with `ZAKURO_IOS_HARDWARE=1`; see
[METAL.md](../ios/zakuro-ios/METAL.md).

## 6. Limitations and follow-ups

- **Interpreter only.** The simulator library is the interpreter build; no AOT
  tables are linked. A linked simulator library can be built with
  `ZAKURO_LINKED_PROGRAM_ID=<16-hex-title-id>` plus the generated archive at
  final link (see [AOT_BUILD.md](../scripts/AOT_BUILD.md)); that needs the
  per-game generated C on this machine.
- **x86_64 only on this VM.** An Apple-silicon Mac needs
  `ZAKURO_SIM_TARGET=aarch64-apple-ios-sim` for the library; the app build
  script currently passes `-arch x86_64` (drop `-arch` there for a native
  Apple-silicon simulator build).
- **Performance is not device performance.** The simulator runs the interpreter
  natively (no CPU JIT is ever used), but it is a virtualized environment; treat
  fps numbers as a sanity check, not as device expectations.
- **ROM transfer is local only.** The VM does not ship ROMs; seed a copy from
  the operator's machine. Keep ROMs out of the repository and delete the copy in
  the simulator container when the test is done.
- **Metal HUD** cannot be used in this environment (no Metal device).

## 7. Evidence from the 2026-11-14 run

> Game-screen images are evidence artifacts only: they stay outside the
> repository (`/tmp` on the VM) and are never committed.

Evidence lives outside the repository (game screenshots must never be
committed). Both locations were populated by the 2026-11-14 run:

On the macOS VM (`/tmp/sim-evidence/`):

| File | Contents |
|---|---|
| `sim-harness.log` | full harness log: Metal probe, `zk_create`, per-second `perf:` lines |
| `03-harness-running.png` | Simulator screenshot of the harness running the game on both screens |
| `frames/top-frame120.png`, `frames/bottom-frame120.png` | raw 400×240 / 320×240 frames `zk_read_screen` produced (the first frames at 30 are still black: the game was not drawing yet) |
| `04-shell-home.png`, `05-shell-home.png` | Simulator screenshot of the shipping shell running (AOT-only home screen, empty catalog) |
| `shell-app.log` | shipping shell's own log for that launch (`iOS 26.5 · iPhone · iPhone 17 Pro`, catalog/library counts, 400×240/320×240) |

Copied to the operations machine at `/tmp/sim-evidence/` with the same names
(the copy is what this document and the task report refer to; it is scratch, not
a repository file).

Selected log lines (verbatim, `Documents/sim-harness.log`):

```text
[sim +0.075s] metal: MTLCreateSystemDefaultDevice=nil
[sim +0.085s] metal: MTLCopyAllDevices=[]
[sim +0.088s] metal: ProcessInfo.simulator=iPhone18,1
[sim +0.424s] zk_create: OK after 0.32 s
[sim +0.425s] screens: top=400x240 bottom=320x240
[sim +0.564s] frame: first frame rendered (137.42 ms)
[sim +0.575s] read_screen: top=384000 bottom=307200 bytes
[sim +11.857s] png: saved .../frames/top-frame120.png (75216 bytes)
[sim +42.784s] perf: frames=266 fps=4.86 frame_min=164.15ms frame_max=274.75ms frame_avg=205.73ms
```

The shipping shell's log confirms it is a real Simulator install of the same
shell: `3ds2apple log started; iOS 26.5 · iPhone · iPhone 17 Pro`, then
`zk_screen_width(0)=400 zk_screen_height(0)=240 zk_screen_width(1)=320
zk_screen_height(1)=240`, and `GameCatalog.json is not in the app bundle; the
library is empty` (the script builds the shell without a per-game catalog).

## 8. Troubleshooting

- `build-ios-app-sim.sh: missing build/ios/libzakuro_ios_sim.a` — run
  `scripts/build-zakuro-ios-sim.sh` first.
- Linker error `undefined symbol zk_create` in the Simulator build — the
  project is linking the arm64 device library; check that the spec copy under
  `build/sim/` contains `-lzakuro_ios_sim` and `-L<repo>/build/ios`.
- `xcrun simctl install` fails with "device not booted" — boot the device first
  and wait for `bootstatus -b`.
- The harness shows "no ROM in Documents/roms" — check the container path, the
  file extension (`.cci`/`.3ds`) and the app's Documents folder.
- `zk_create failed` — the harness logs `zk_last_error`; a decrypted
  `.3ds`/`.cci` is required (encrypted ROMs and arbitrary files fail).
- VM becomes unresponsive during Simulator boot — start `caffeinate` first, do
  not build while the Simulator boots, and `xcrun simctl shutdown all` after.

## 9. Per-game AOT GamePack on the Simulator (AOT-first proof)

The runs in sections 1-7 drive the interpreter-only runtime. The AOT-first build
adds one dylib per game ("GamePack") that hands 3dsrecomp-generated tables to
the same runtime at run time; this section builds and runs that path in the
Simulator, where it can be proven headless.

### 9.1 The contract in one paragraph

The pack is a Mach-O dylib that exports GamePack C ABI v1
(ios/zakuro-ios/include/zakuro_gamepack.h): zk_gamepack_title_id(),
zk_gamepack_abi_version() and zk_gamepack_register(host_abi). Its C shim
(ios/zakuro-ios/gamepack/zk_gamepack_shim.c) forwards the generated recomp
tables to the runtime through zk_register_gamepack(), then zk_create() hands
them to Zakuro through the same Config.linked path a statically linked build
uses, so zk_recompiled() returns 1. The pack carries the game code only: the
runtime (libzakuro_ios.a / libzakuro_ios_sim.a) stays in the app and the pack's
undefined host symbols are resolved at dlopen() time (-undefined
dynamic_lookup). The shipping shell's AOTPackageLoader dlopen()s the catalog
packFile, checks the title id and the ABI version, and **requires** the
registration hook: a pack without it is refused (it could only fall back to the
interpreter). The runtime has one registration slot, so the loader re-runs the
cached pack's hook when the registered title is another game (A -> B -> A runs
A's AOT tables each time).

### 9.2 Build the runtime, the pack and the apps

Run on the build VM from the repository root:

    scripts/build-zakuro-ios-sim.sh          # runtime with the GamePack API
    scripts/build-game-pack.sh --selfcheck   # shim ABI + Mach-O export checks

The generated C for one game must be on the VM (build/game/<name>; the
desktop machine produces it, see docs/desktop-aot.md). Compile it for the
Simulator and link the real pack (this compiles 489 C files in the Pokemon Y
case; give it 20-40 minutes on this VM):

    nohup scripts/build-game-pack.sh pokemon-y \
      --title-id 0004000000055E00 --display-name "Pokemon Y" --product-code CTR-P-EK2A \
      --code-dir build/game/pokemon-y --target sim \
      --out build/sim/game --no-record > /tmp/gp-pack.log 2>&1 &

Then build both simulator apps with the pack and the catalogue embedded:

    scripts/build-ios-app-sim.sh --app both \
      --game-pack build/sim/game/packages/0004000000055E00 \
      --game-title-id 0004000000055E00 \
      --game-display-name "Pokemon Y" --game-product-code CTR-P-EK2A

--game-title-id is required with --game-pack/--game-code-dir (the catalogue
entry and the Frameworks/ file name are derived from it); --game-display-name
defaults to the game name. The script copies GamePack-<TITLE_ID>.dylib under the
app's Frameworks/ and writes the schema v2 GameCatalog.json (packFile pointing
at it) into both the shell and the harness. --no-record is the Simulator proof
path: the shipped pipeline still gets its GameInfo.json/catalogue from the Rust
desktop CLI, which is the single schema writer.

Self-contained package (task-11): add the user's decrypted ROM so the shell boots
it straight from the app bundle with no Documents/roms import:

    # stage the ROM next to the pack (the same shape the desktop CLI writes)
    cp "/path/to/your/Pokemon Y.cci" \
       build/sim/game/packages/0004000000055E00/GameRom.cci

    scripts/build-ios-app-sim.sh --app shell \
      --game-pack build/sim/game/packages/0004000000055E00 \
      --game-title-id 0004000000055E00 --game-display-name "Pokemon Y" \
      --game-product-code CTR-P-EK2A \
      --game-rom build/sim/game/packages/0004000000055E00/GameRom.cci

The script copies the ROM to Roms/<TITLE_ID>.<ext> in the **shell** app (not the
harness), verifies the copy's SHA256, and writes "romFile" into the shell's
GameCatalog.json. It also auto-detects a GameRom.<ext> file in the --game-pack
directory when --game-rom is omitted. The ROM is user-owned test data: keep it
out of the repository and delete it from the output tree when done.

### 9.3 Run and read the evidence

Boot/install as in section 3 (the harness can still use a Documents/roms seed).
The harness log then shows the pack path before any frame runs. This is the
**pack admission** proof (dlopen, title id, ABI, registration); the shipping
shell's launch from a bundled ROM is documented in section 9.6.

    gamepack: candidates=["GamePack-0004000000055E00.dylib"]
    gamepack: ...: dlopen OK
    gamepack: ...: title id 0004000000055E00
    gamepack: ...: pack ABI 1 (host ABI 1)
    gamepack: ...: registered with the runtime; AOT code is active
    zk_create: game package registered for title 0004000000055E00, handing its AOT code to the loader
    zk_create: recomp-abi accepted the game package tables: ...
    zk_create: AOT active: linked code, ...
    zk_recompiled: 1 (1 = Zakuro is running AOT code)
    zk_linked_program_id: 0004000000055E00

Photos and logs stay outside the repository (/tmp/gp-evidence/ on the VM).

Measured on 2026-11-14 (iPhone 17 Pro simulator, iOS 26.5, x86_64, software
PICA200 only):

- GamePack.dylib: 250,834,744 bytes, sha256
  92bab7aaf4fbe7628ed82d392792f8bbc2085423f8518f830160ec1ba2145da2,
  linked from the 489 generated C files (173,131 entry points, 133 modules).
- harness: gamepack dlopen at +0.234 s, registered at +0.303 s, zk_create OK
  after 0.33 s, zk_recompiled() == 1, zk_linked_program_id 0004000000055E00,
  zk_linked_code() == 1.
- runtime stderr on the console-pty launch (zk_create's own log):
  zk_register_gamepack: registered title 0004000000055E00: recomp interface ABI
  5, generation 5, 173131 entry points, 133 modules; zk_create: game package
  registered for title 0004000000055E00; zk_create: AOT active: linked code,
  173131 entry points, 133 modules, 0 instruction fallbacks, ... ; zk_perf ...
  interpreted 0.00% | AOT active.
- frames: 353 frames in 60 s (4.1-5.3 fps) - the AOT CPU is not the limit, the
  software PICA200 is: the first 60 frames averaged 3.24 ms/frame (the boot
  screen barely draws) and later frames 121-205 ms with 50-190 ms/frame in the
  software GPU.
- evidence on the build VM: /tmp/gp-evidence/01-harness-aot.png (harness
  running the game), frames/top-frame300.png + frames/bottom-frame300.png (raw
  400x240 / 320x240 reads), sim-harness-aot.log.

### 9.4 Limitations of this proof

- The runtime needs the decrypted ROM at zk_create (Zakuro boots the console
  from the NCSD: exheader, exefs and romfs). The package closes that gap by
  carrying the ROM (section 9.6); the harness in this section still seeds its
  ROM into the container, which is only a test convenience.
- One registered pack wins per process. The runtime's registration slot is
  replaced by each successful registration; the shipping shell re-registers the
  cached dylib when the slot names another title, but two games are never
  registered at once.
- Nested-dylib signing (SideStore/Sideloadly must re-sign
  Frameworks/GamePack-*.dylib) and a **device** dlopen are unverified here.
- No Metal on this VM, so the same software PICA200/readback path of section 5
  is what the AOT code draws through.

### 9.5 A two-entry catalogue: real pack + placeholder (T3 result)

A second, 13 KB placeholder pack was built with the same shim and stand-in
tables but a recomp interface version this runtime refuses (recomp_abi 3 vs 5),
for title 000400000000FF00 (sorts before the real pack so it is tried first).
Both packs embedded, both apps installed:

- harness log (fails the placeholder, then runs the real pack):
      gamepack: candidates=["GamePack-000400000000FF00.dylib", "GamePack-0004000000055E00.dylib"]
      gamepack: GamePack-000400000000FF00.dylib: dlopen OK
      gamepack: GamePack-000400000000FF00.dylib: registration refused (result 2); skipped
      gamepack: GamePack-0004000000055E00.dylib: registered with the runtime; AOT code is active
      zk_recompiled: 1 (1 = Zakuro is running AOT code)
- runtime console-pty log: "zk_register_gamepack: refused title
  000400000000FF00: it was built for version 3 of the interface, this is 5",
  then the real pack registered and zk_create reported AOT active.
- shell (2-entry GameCatalog.json): home shows two library cards, "Placeholder
  (fake pack)" and "Pokemon Y", each with the green AOT badge; the shell log
  says "game catalog: GameCatalog.json - schemaVersion 2 - 2 game(s), 2 built"
  and "library: 2 game(s) from GameCatalog.json".
- evidence: /tmp/gp-evidence/02-harness-two-packs.png (harness running Pokemon Y
  with both packs in the bundle), 03-shell-two-entries.png (shell home with the
  two entries), harness-console-t3.log, sim-harness-t3.log, shell-log-t3.log.

Only the real pack is admitted, and only the real game runs. This section proves
**pack admission** in the harness (the shell shows the same library). The
shipping shell's own launch path - tapping a card, or the `-openAOTTitleID`
debug argument - is proven end-to-end in section 9.6.

### 9.6 Self-contained package: the shipping shell launches from a bundled ROM (task-11)

The AOT-first package must not ask the phone to import game data. Task-11 changed
the contract and the shell so a package carries the user's ROM:

- **GameInfo.json** (desktop package) gains `romFile`/`romSha256`/`romBytes`;
  `3ds2apple-pack packages add|record --include-rom` copies the ROM into the
  package as `GameRom.<ext>` and hashes it (raw, uncompressed: the copy costs
  the ROM's size, 1.8 GB for Pokemon Y).
- **GameCatalog.json v2** gains the optional app-bundle-relative `romFile`
  (`Roms/<TITLE_ID>.<ext>`). The shell resolves it through the same
  bundle-relative path check as `packFile` (`AOTPackageLoader.bundleROMURL`).
- **Shell**: `ROMSession.start()` now launches a `packFile` game through the
  package path - pack loaded and registered, ROM read from the bundle, then
  `zk_create()` - instead of showing a notice. The legacy static-link path still
  reads `Documents/roms`. `-openAOTTitleID <TITLE_ID>` (DebugLaunch.swift)
  starts one catalog game from the command line because simctl cannot tap the
  UI; the argument is inert in normal launches.

Exact run (iPhone 17 Pro simulator, iOS 26.5, x86_64; the VM was concurrently
compiling the arm64 device pack, so the fps below is not representative):

    # 1. stage the ROM into the package and build the shell (1.9 GB app)
    cp "/path/to/Pokemon Y.cci" build/sim/game/packages/0004000000055E00/GameRom.cci
    scripts/build-ios-app-sim.sh --app shell \
      --game-pack build/sim/game/packages/0004000000055E00 \
      --game-title-id 0004000000055E00 --game-display-name "Pokemon Y" \
      --game-product-code CTR-P-EK2A \
      --game-rom build/sim/game/packages/0004000000055E00/GameRom.cci

    # 2. install with no ROM in the data container (the old on-device flow)
    xcrun simctl uninstall "$UDID" com.kratos.3ds2apple || true
    xcrun simctl install "$UDID" build/sim/shell/out/Release-iphonesimulator/3ds2apple.app
    CONTAINER=$(xcrun simctl get_app_container "$UDID" com.kratos.3ds2apple data)
    ls "$CONTAINER/Documents"            # no roms/ and no library.json before launch

    # 3. launch the catalog game through the debug argument
    xcrun simctl launch --console-pty "$UDID" com.kratos.3ds2apple \
      -openAOTTitleID 0004000000055E00

Measured (2026-11-14, task-11; evidence in /tmp/gp-evidence/ on the build VM,
kept out of the repository):

- install: 34 s for the 1.9 GB app. The app bundle carries
  1,807,118,336-byte `Roms/0004000000055E00.cci` (the script SHA256-checked the
  copy against the staged source). After the run the data container's
  `Documents` held only `Library/`, `logs/` and `data/`: **there was never a
  `Documents/roms`**, and the runtime read
  `.../3ds2apple.app/Roms/0004000000055E00.cci`.
- shell log (`Documents/logs/latest.log`):
      game catalog: GameCatalog.json - schemaVersion 2 - 1 game(s), 1 built
      -openAOTTitleID: starting Pokemon Y (0004000000055E00) from the command line
      game package Frameworks/GamePack-0004000000055E00.dylib: registered for 0004000000055E00 (abi 1)
      starting Pokemon Y from the package ROM Roms/0004000000055E00.cci (0004000000055E00.cci)
      zk_create: loading .../3ds2apple.app/Roms/0004000000055E00.cci (CAMetalLayer: no)
      zk_create: game package registered for title 0004000000055E00, handing its AOT code to the loader
      zk_create: recomp-abi accepted the game package tables: 173131 entry points, 133 modules
      zk_create: AOT active: linked code, 173131 entry points, 133 modules, 0 instruction fallbacks
      AOT linked=1 recompiled=1 program=0x0004000000055E00 status=AOT - package
      zk_create OK after 0.3 s: Pokemon Y (0004000000055E00.cci)
      zk_perf: ... | interpreted 0.00% | AOT active
- screenshot evidence: `/tmp/gp-evidence/04-shell-boot-25s.png` (also
  `-50s` and `04-shell-bundled-rom.png`): the shipping SwiftUI shell (title bar
  "Pokemon Y", pause button, on-screen controls) shows Pokemon Y's
  language-select screen on both 3DS screens. The frames come from the package
  ROM and the registered pack; no game data was imported.
- fps: 1-4 in this run because the arm64 device GamePack compile was running on
  the same 8-vCPU VM (load >60). The task-10 idle-VM measurement was 4.1-5.3 fps
  with the software PICA200, which is the environment limit here.

What this does not prove: an arm64 **device** pack with a device `dlopen()`;
nested-dylib re-signing (SideStore/Sideloadly); hardware/Metal rendering
(section 5 covers the software-only VM).

