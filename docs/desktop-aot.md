# Desktop AOT-first pipeline

> Status: MVP, host-native (Linux/Windows/macOS), 2026-11-14 · task-7 ·
> companion to [aot-first.md](aot-first.md) (route) and
> [../builder/](../builder/) (builder binaries).
>
> This document is the contract between the desktop build and the AOT shell: the
> per-game package layout, the `GameInfo.json` manifest, the `GameCatalog.json`
> schema v2 and the `GamePack.dylib` ABI hand-off. The real macOS compile/link is
> still delegated to the scripts in `scripts/` (or the Build Agent); everything
> else runs natively on the user's desktop, including on Linux.

The AOT-first model moves ROM import and compilation off the phone:

1. The user selects their own **decrypted** ROMs (`.3ds` / `.cci`; a raw NCCH
   `.ncch`/`.cxi` also works) on a computer.
2. The desktop reads the **headers only** (a few KiB, never a copy or a full
   hash), detects title ID / product code / display name and queues one AOT
   build per title.
3. A macOS host (local Mac or Build Agent) compiles the game; the result becomes
   one package: `out/packages/<TITLE_ID>/GamePack.dylib + GameInfo.json`.
4. The user selects packages; one **shell IPA** is produced that carries all of
   them: `Payload/3ds2apple.app/Frameworks/GamePack-<TITLE_ID>.dylib` plus a
   generated `GameCatalog.json`.
5. The phone only shows the catalog as its library and launches an already
   compiled pack; there is no device-side import and no interpreter fallback for
   catalog titles (shell side: [aot-first.md §7](aot-first.md)).

Nothing in this pipeline is committed: ROMs, generated C, `GamePack.dylib`,
`GameInfo.json`, catalogs and IPAs live in gitignored directories (`out/`,
`build/`, `IPA/`). The project provides no ROMs, keys, game data or covers.

## 1. Components

| Component | Location | Runs on | Responsibility |
|---|---|---|---|
| Desktop CLI (`3ds2apple-pack`) | `builder/pack/` | Linux/Windows/macOS | ROM header detection, import queue, `GameInfo.json`, package verify/remove, deterministic `GameCatalog.json` allocation, command plan for the macOS scripts, fake/preview packs |
| Per-game pack script | `scripts/build-game-pack.sh` | macOS (real) / any (fake, dry-run) | Links or adopts one `GamePack.dylib`, records it in the package through the CLI (single manifest writer) |
| Multi-game IPA script | `scripts/build-multi-game-ipa.sh` | any (fake shell) / macOS+app (real) | Stages the shell app, embeds N packs, writes `GameCatalog.json`, packages the unsigned IPA through `scripts/package-ipa.sh` |
| Existing AOT scripts | `scripts/build-recomp-ios.sh`, `build-linked-ios-lib.sh`, `build-game-ipa.sh` | macOS (Xcode) | 3dsrecomp → generated C → iOS clang → linked runtime; unchanged single-game path |
| Shell side | `ios/app/Sources/GameCatalog.swift`, `AOTPackageLoader.swift` | iOS | Reads catalog v2, calls `dlopen` on `packFile`, validates the GamePack ABI (owned by the AOT-shell task) |

The CLI is a normal Rust workspace member:

```bash
cd builder
cargo build -p builder-pack --release
# binary: builder/target/release/3ds2apple-pack (also available in debug/)
# or run without installing: cargo run -p builder-pack -- --help
```

## 2. Host-native split (Linux-first heavy compute)

The flow is designed so expensive host-native steps run on the desktop, not in
the 6 vCPU macOS VM:

| Stage | Preferred host | Why / status |
|---|---|---|
| ROM import: header parse, title detection, queue, package metadata | **Linux/Windows/macOS natively** | Implemented in `builder/pack`; header-only, milliseconds even for 3+ GB ROMs |
| 3dsrecomp: ROM → generated C | **Linux host natively** (Rust tool, multi-threaded; 16 threads on the reference WSL host vs 6 vCPU VM) | **Planned hand-off**; see below |
| iOS clang compile of generated C → `libgame.a` | macOS + Xcode SDK | Apple toolchain/legal boundary; macOS only |
| Linked Zakuro runtime (`libzakuro_ios.a`) | macOS (Xcode + Rust `aarch64-apple-ios`) | Existing scripts; a Linux cross build of the Rust staticlib is unverified |
| `GamePack.dylib` link | macOS (Xcode clang) | `build-game-pack.sh --from-libs` (experimental) or `--dylib` adoption |
| `GameCatalog.json` + IPA assembly | Any host for the preview; macOS for a real shell app | `build-multi-game-ipa.sh --fake-shell` is the Linux preview path |

### 3dsrecomp on Linux: exact commands (not vendored)

3dsrecomp has **no license**, so it is used only as a build tool: it is never
copied into this repository, never committed and never redistributed. The
existing scripts already clone it into `third_party/3dsrecomp` (gitignored) and
pin a revision.

```bash
# once, on the Linux host (or any machine with Rust; a couple of minutes)
git clone https://github.com/fearkov/3dsrecomp third_party/3dsrecomp
git -C third_party/3dsrecomp checkout <pinned-rev>   # DEFAULT_RECOMP_REV in scripts/build-recomp-ios.sh
(cd third_party/3dsrecomp && cargo build --release)
# binary: third_party/3dsrecomp/target/release/3dsrecomp
```

Current gap: `scripts/build-recomp-ios.sh` couples "run 3dsrecomp" with
"compile the generated C with the iOS SDK clang" and refuses to run off macOS.
The hand-off seam already exists -- on macOS it can adopt a C tree generated
elsewhere:

```bash
# Linux (planned): generate C once, then copy build/game/<name>/ to the Mac
# macOS: compile the adopted C with the iOS clang; no ROM/3dsrecomp needed
scripts/build-recomp-ios.sh <name> --code-dir build/game/<name>
```

Wiring a real "generate only" mode (3dsrecomp's current `port` command compiles
with `CC`) is a follow-up in `scripts/build-recomp-ios.sh`/`builder/agent`; the
`--code-dir` path above is the documented split, and this MVP keeps the whole
recomp step on the macOS host until that wiring is verified. The CLI dry run
below makes the split visible without a Mac.

### Fake / dry-run macOS link step on Linux

```bash
# 1. import ROMs + print the exact macOS command plan (no compile, no Mac)
3ds2apple-pack packages add --roms "ROM/Pokémon Y.cci" "ROM/Pokémon Alpha Sapphire.cci"
3ds2apple-pack build --queued

# 2. full local pipeline with labelled placeholder packs (NOT installable)
3ds2apple-pack build --queued --fake

# 3. preview the multi-game IPA layout (fake shell + placeholders, NOT installable)
3ds2apple-pack pack --all --execute --fake-shell --ipa-out IPA/
```

`build --queued --execute` is the only mode that runs the macOS scripts; on a
non-macOS host it fails with a clear hint, which is why the fake/dry-run path
exists for Linux/Windows development and for a Windows desktop without a Mac
(until the remote Build Agent multi-game stage lands, see §10).

## 3. CLI flow

All commands default to `--out out`; the output tree is gitignored. Global
`--json` prints machine-readable JSON (the integration tests use it).

```bash
CLI=builder/target/release/3ds2apple-pack   # or cargo run -p builder-pack --

# Detect metadata from headers only (fast; never copies or hashes the ROM)
"$CLI" rom inspect "ROM/Pokémon Y.cci"
# -> ROM/Pokémon Y.cci  titleID=0004000000055E00  productCode=CTR-P-EK2A  container=Ncsd  bytes=1807118336  content=1.7 GiB
#    displayName: Pokémon Y

# Import/queue one or many ROMs (creates out/packages/<TITLE_ID>/GameInfo.json)
"$CLI" packages add --roms "ROM/Pokémon Y.cci" "ROM/Pokémon Alpha Sapphire.cci"
"$CLI" packages list
# 0004000000055E00  queued    Pokémon Y              CTR-P-EK2A      not built
# 000400000011C500  queued    Pokémon Alpha Sapphire CTR-P-ECLA     not built

# Build: default prints the macOS plan; --fake writes placeholders; --execute runs the scripts
"$CLI" build --queued                     # print plan
"$CLI" build --queued --fake              # local preview packs
"$CLI" build --queued --execute           # macOS: recomp -> link -> pack
"$CLI" build --roms "ROM/game.cci" --execute   # import + build in one step (macOS)
"$CLI" build --queued --force --fake      # rebuild packages that already have a pack

# Verify package manifests/pack hashes (hashes every pack)
"$CLI" packages verify

# Generate the catalog only (also done by "pack")
"$CLI" catalog --all
"$CLI" catalog --title-id 0004000000055E00 --catalog-out /tmp/one.json

# One shell IPA with the selected games (print command / execute)
"$CLI" pack --all --fake-shell --ipa-out IPA/          # print command
"$CLI" pack --all --execute --fake-shell --ipa-out IPA/  # Linux preview
"$CLI" pack --all --execute --base-app ios/app/build/Release-iphoneos/3ds2apple.app \
       --ipa-out IPA/                                    # macOS real shell

# Remove packages + queue entries
"$CLI" packages remove 000400000011C500
```

Behaviour notes:

- `build --roms ...` exits **1** if any requested ROM was rejected, while still
  processing (building or planning) the accepted ones; `--json` reports every
  error. Exit 0 means every requested ROM was accepted.
- `--fake` and `--execute` are mutually exclusive (clap usage error, exit 2);
  a preview can never silently skip the real macOS scripts.
- `build --queued --force` rebuilds packages that already have a pack; plain
  `--queued` only builds packages without one. `build --roms --force` re-imports
  an existing package (keeping its pack) instead of failing.
- Exit codes: 0 success, 1 failure/validation, 2 CLI usage error.

Internally the CLI also has `packages record --title-id ... --pack FILE` (adopt a
real dylib) and `--fake-placeholder`; `scripts/build-game-pack.sh` uses these so
there is exactly one `GameInfo.json`/`GameCatalog.json` writer (the Rust crate).

## 4. Package layout

```text
out/
  aot-queue.json                          import/build queue (deterministic)
  packages/
    GameCatalog.json                      generated catalogue (all built games)
    0004000000055E00/
      GameInfo.json                       manifest (see below)
      GamePack.dylib                      AOT pack: real Mach-O, or --fake placeholder
      cover.png                           optional user cover; never committed
    000400000011C500/
      ...
```

`GameInfo.json` (manifest schema version 1; deterministic pretty JSON, no
timestamps; the ROM path is provenance only and stays in the gitignored tree):

```json
{
  "schemaVersion": 1,
  "titleID": "0004000000055E00",
  "displayName": "Pokémon Y",
  "productCode": "CTR-P-EK2A",
  "aotVersion": 1,
  "saveNamespace": "0004000000055E00",
  "packFile": "GamePack.dylib",
  "pack": {
    "sha256": "64 lower-case hex digits",
    "bytes": 42102784,
    "format": "macho"
  },
  "rom": {
    "path": "/home/user/ROM/Pokémon Y.cci",
    "fileName": "Pokémon Y.cci",
    "bytes": 1807118336
  }
}
```

- `pack` is absent while a package is queued; it is written when the pack is
  built/recorded. `format` is `macho` for a real arm64 dylib and `placeholder`
  for `--fake` (labelled, not installable).
- The package directory name is always the 16-digit title ID; the manifest must
  agree or `packages verify` fails.
- `saveNamespace` is the title ID: the shell stores battery saves under
  `Documents/data/<TITLEID>` and save states under `Documents/states/<TITLEID>`
  ([aot-first.md §7.5](aot-first.md)). Two packages can never collide.
- `notes` is free-form build information and is **omitted from the JSON when
  empty** (the example above therefore has no `notes` field; it appears only
  when set, and is mirrored into the catalogue's `notes`).

## 5. GameCatalog.json schema v2 (shell contract)

The catalogue is **compact one-line JSON + trailing newline**, games sorted by
`titleID` (byte-identical for the same package set). Schema v2 is what the AOT
shell reads; v1 (static single-game builds) remains accepted:

```json
{"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Pokémon Y","productCode":"CTR-P-EK2A","aot":true,"aotVersion":1,"packFile":"Frameworks/GamePack-0004000000055E00.dylib","packABIVersion":1,"notes":""}]}
```

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | 2 (this pipeline); 1 still accepted = statically linked single-game build |
| `titleID` | yes | 16 upper-case hex digits; unique, sorted |
| `displayName` | yes | library card title |
| `productCode` | yes (may be empty) | 3DS product code from the NCCH header |
| `aot` | yes | true = AOT code allocated for this title |
| `aotVersion` | yes | pack version (>= 1) |
| `packFile` | yes for schema 2 | app-bundle-relative dylib: `Frameworks/GamePack-<TITLE_ID>.dylib` |
| `packABIVersion` | optional, default 1 | GamePack C ABI version (host ABI = 1) |
| `registrationSymbol` | optional | override of the registration hook (default `zk_gamepack_register`) |
| `coverFile` | optional | app-bundle-relative cover, `Covers/<TITLE_ID>.png` when `out/packages/<TITLE_ID>/cover.png` exists |
| `notes` | optional | build note |

Validators: `builder/pack` (`GameCatalog::validate`) and
`scripts/lib/game-catalog.sh` (`game_catalog_validate`, used by
`package-ipa.sh`) both accept v1 and v2 and enforce the `packFile`,
`packABIVersion`, `registrationSymbol` and `coverFile` rules above. The shell
task's own validation lives in `ios/app/Sources/GameCatalog.swift` +
`AOTPackageLoader.isValidBundleRelativePath`. For schemaVersion 2 both desktop
validators require `packFile`; an entry without it would only be a static-link
fallback and is rejected by this pipeline. The shell remains deliberately
permissive: it logs and treats a schema-2 entry without `packFile` as statically
linked, and warns for schema versions newer than `GameCatalog.supportedSchemaVersion`.
If the shell bumps its supported schema, update `CATALOG_SCHEMA_VERSION` and both
validators in one change.

Assumptions agreed with the AOT-shell task (Lead, 2026-11-14):
`schemaVersion 2`, `packABIVersion = 1`, default registration symbol
`zk_gamepack_register`, optional `coverFile`, legacy v1 accepted,
`saveNamespace = <TITLEID>`.

## 6. GamePack ABI hand-off (documented gap, owned by runtime-ffi)

The shell loads each `packFile` with `dlopen(RTLD_NOW | RTLD_LOCAL)` and accepts
these **optional** C symbols (host ABI version 1,
`AOTPackageLoader.hostABIVersion`):

| Symbol | Signature | Meaning |
|---|---|---|
| `zk_gamepack_title_id` | `uint64_t zk_gamepack_title_id(void)` | title the pack was built for; mismatch means the pack is refused |
| `zk_gamepack_abi_version` | `uint32_t zk_gamepack_abi_version(void)` | must equal the host ABI (1) |
| `zk_gamepack_register` | `int32_t zk_gamepack_register(uint32_t host_abi_version)` | registration hook; 0 = accepted, non-zero means unload |

**Status: GAP.** This desktop MVP records `packABIVersion=1` in the catalogue but
does not yet produce these symbols:

- `--fake` packs are labelled placeholders (never installable);
- `build-game-pack.sh --from-libs` links the existing static archives into a
  dylib and is **experimental/unverified** (the linked runtime was designed to be
  linked into the app binary);
- a pack that actually hands its AOT image to the runtime (registering the
  recompiled tables with Zakuro and starting `zk_create` from a pack) is
  **runtime work in `ios/zakuro-ios`** (runtime-ffi task). The shell side already
  validates/opens the pack and reports a clear "No AOT build" error when the pack
  or runtime support is missing, and never falls back to the interpreter;
- nested-dylib re-signing (SideStore/Sideloadly must sign the embedded
  `Frameworks/GamePack-*.dylib`) and a real pack `dlopen` on device are
  unverified in this slice.

Until then the end-to-end proof in this repository is the **preview IPA**
(fake shell + placeholder packs, catalog verified inside the IPA) plus the
unchanged single-game static-link IPA path.

> **2026-11-14 update (task-10, runtime-ffi): the hand-off gap is closed for
> the runtime + pack builds; the Simulator proof runs.** The GamePack C ABI v1
> is implemented and exercised:
>
> - **Runtime side** (ios/zakuro-ios): ios/zakuro-ios/include/zakuro_gamepack.h
>   declares it; ios/zakuro-ios/src/gamepack.rs implements
>   zk_register_gamepack(title_id, recomp_abi, generation, entries,
>   entry_count, modules, module_count, origins), zk_unregister_gamepack(),
>   zk_gamepack_registered() and zk_registered_gamepack_title_id(). zk_create()
>   hands registered tables to Zakuro through Config.linked (the statically
>   linked single-game path still wins when present), so zk_recompiled() == 1
>   and the AOT-only shell's post-create check passes.
> - **Pack side**: ios/zakuro-ios/gamepack/zk_gamepack_shim.c implements the
>   pack's three exports and calls the host API; the pack links the game's
>   generated archive plus the shim only (no copy of the runtime) with
>   -undefined dynamic_lookup.
> - **Pipeline**: scripts/build-game-pack.sh now builds a real pack:
>   --code-dir DIR compiles the 3dsrecomp-generated C for the target
>   (--target device|sim), --from-libs links build/ios/<name>/libgame.a and the
>   shim, and --selfcheck runs the shim + Mach-O export checks without a ROM.
>   --target sim --no-record is the Simulator proof path;
>   scripts/build-ios-app-sim.sh --game-code-dir/--game-pack embeds the dylib
>   and the catalogue into the simulator shell + harness.
> - **Proof**: Pokemon Y, 489 generated C files compiled for
>   x86_64-apple-ios-simulator into a 250,834,744 byte
>   GamePack-0004000000055E00.dylib (sha256
>   92bab7aaf4fbe7628ed82d392792f8bbc2085423f8518f830160ec1ba2145da2),
>   dlopen()ed and registered in the iPhone 17 Pro simulator: zk_recompiled()
>   == 1, zk_linked_program_id 0004000000055E00, zk_perf lines say "AOT active |
>   interpreted 0.00%", 353 frames in 60 s against the software renderer. A
>   two-entry catalogue (real pack + a placeholder pack whose recomp ABI the
>   runtime refuses) installs and displays in the shell; the harness skips the
>   placeholder and runs the real game. Evidence: docs/build-simulator.md
>   section 9, /tmp/gp-evidence/ on the build VM.
>
> Still open for the phone flow: the AOT-first package has to carry the game
> data/ROM (or import it during a desktop-to-phone transfer - GameCatalog v2 has
> no romDataFile yet; Zakuro's loader still boots from the NCSD), nested-dylib
> re-signing plus a device dlopen are unverified, and only one registered pack
> is used per process.


## 7. Multi-game IPA (allocation)

```bash
scripts/build-multi-game-ipa.sh [options] [PACKAGE_DIR...]

# real mode (macOS): extend an unsigned shell .app built by build-ios-app.sh
scripts/build-multi-game-ipa.sh --base-app ios/app/build/Release-iphoneos/3ds2apple.app \
  --packages-dir out/packages --all

# Linux/Windows preview: minimal fake shell app (NOT installable)
scripts/build-multi-game-ipa.sh --packages-dir out/packages --all \
  --allow-placeholder-dylibs --fake-shell

# select titles / validate only / custom catalogue
scripts/build-multi-game-ipa.sh --packages-dir out/packages \
  --title-id 0004000000055E00 --title-id 000400000011C500
scripts/build-multi-game-ipa.sh out/packages/0004000000055E00 --dry-run
```

Behaviour:

- selection is deterministic (sorted by title ID); each package is checked for
  `GameInfo.json`, matching directory/title ID, and `GamePack.dylib`;
- `--fake` placeholder packs are **rejected** unless
  `--allow-placeholder-dylibs` is passed, so a preview cannot silently become a
  release;
- the catalogue is generated by `3ds2apple-pack catalog` (or passed with
  `--catalog`) and validated before packaging; the embedded copy is compared
  again after packaging;
- optional `cover.png` in a package is copied to `Covers/<TITLE_ID>.png` and
  listed as `coverFile`;
- packaging reuses `scripts/package-ipa.sh` (unsigned IPA, SHA256 printed) and
  writes `IPA/<name>.pack-manifest.txt` with catalogue/pack/IPA hashes;
- the IPA is unsigned: signing/installing remains the user's step
  (Sideloadly/AltStore/SideStore).

Outputs (gitignored): `IPA/<ipa-name>.ipa` and
`IPA/<ipa-name>.pack-manifest.txt`.

## 8. Real macOS path (delegated, not exercised in this slice)

```bash
# 1. recomp + linked runtime (existing, macOS; see docs/build.md / AOT_BUILD.md)
scripts/build-recomp-ios.sh "ROM/Pokémon Y.cci" pokemon-y-00055e00 --auto-serial
scripts/build-linked-ios-lib.sh pokemon-y-00055e00 --title-id 0004000000055E00

# 2. per-game package (adopt a runtime-provided dylib, or experimental link)
scripts/build-game-pack.sh pokemon-y-00055e00 --title-id 0004000000055E00 \
  --display-name "Pokémon Y" --product-code CTR-P-EK2A --out out \
  --dylib build/ios/pokemon-y-00055e00/GamePack.dylib
# experimental:  ... --from-libs --lib-dir build/ios/pokemon-y-00055e00

# 3. one shell IPA with several packages
3ds2apple-pack pack --all --execute --base-app ios/app/build/Release-iphoneos/3ds2apple.app
```

`3ds2apple-pack build --queued --execute` runs this exact sequence through the
script plan (the CLI prints it by default for review).

## 9. Library boundary and legal notes

- Only user-owned, decrypted ROMs. The pipeline never downloads ROMs/keys,
  never decrypts and never stores game data in the repository.
- No GPL code: S2Arm (Apache-2.0) and NX2Apple (MIT) are behavioural references
  only; nothing from them is copied here. 3dsrecomp is a build tool with no
  license: run it, never vendor it.
- `GamePack.dylib`, `GameInfo.json`, catalogs and IPAs contain game-derived
  code; they are produced for the user, stay on the user's machines and must not
  be redistributed. The project provides no hosted build service.
- Covers/artwork are user-provided local content (never committed).

## 10. Implemented vs gaps

Implemented (Linux-verified in this slice):

- [x] ROM header detection (NCSD `.3ds`/`.cci`, raw NCCH) with title ID,
  product code, title version and sizes; invalid/truncated/CIA files rejected
  with actionable errors; no ROM copy or full hash.
- [x] Import queue + per-game package directories + deterministic
  `GameInfo.json`; add/list/verify/remove/record; **atomic remove** (a partial
  failure never leaves a stale queue entry); re-import/rebuild safety
  (`--force`, `build --queued --force`); partial-import exit code (1) for
  `build --roms`.
- [x] Fake AOT builds (`--fake`) and the full macOS command plan on Linux.
- [x] Deterministic `GameCatalog.json` schema v2 (+ legacy v1 validator support).
- [x] `build-game-pack.sh` (real adopt/link on macOS, fake/dry-run elsewhere).
- [x] `build-multi-game-ipa.sh` multi-pack shell IPA with generated catalog;
  embedded-catalogue verification; preview mode on Linux.
- [x] Golden-fixture + unit/integration tests + `desktop-aot-selfcheck.sh`
  (55 checks) + `game-catalog-selfcheck.sh` (71 checks).
- [x] Docs: this file, `docs/build.md` preview section, `builder/README.md`.

Gaps / follow-ups (owners):

1. **GamePack runtime hand-off** (runtime-ffi): the `zk_gamepack_*` symbols and
   starting a game from a registered pack image; until then no real multi-game
   IPA can run ([aot-first.md §8](aot-first.md)).
2. **Real dylib link** (build-infra): `--from-libs` needs a macOS run and
   on-device validation; nested-dylib re-signing must be tested with
   SideStore/Sideloadly (dlopen of a re-signed nested dylib).
3. **Build Agent / zkb integration** (task-7 follow-up): the Agent still builds
   one static-link game IPA; extend its packaging stage to invoke
   `build-game-pack.sh` / `build-multi-game-ipa.sh` and stream package
   artifacts. The desktop CLI plan already matches the Agent's script contract.
4. **Host-native 3dsrecomp generation** (build-infra): wire a generate-only mode
   on Linux and benchmark; use `--code-dir` adoption on the Mac for the compile.
5. **CIA support**: the MVP rejects CIA containers (title ID lives in the ticket,
   executable encrypted). Requires the user's decrypted `.3ds`/`.cci` or a
   separate safe extraction step (not in scope).
6. **GUI launchers**: Windows/macOS graphical shells remain design-only; the CLI
   is the MVP interface (same as the rest of `builder/`).
7. **Covers**: `cover.png` is copied if present, but fetching artwork is not
   implemented (legal/UI decision left to the launcher work).

## 11. Test commands

```bash
cd builder && cargo test --workspace         # incl. builder-pack unit + CLI integration tests
cd builder && cargo test -p builder-pack     # this pipeline only
bash scripts/tests/desktop-aot-selfcheck.sh  # 55 checks, no Xcode/ROM
bash scripts/tests/game-catalog-selfcheck.sh # 71 checks, catalogue helper
```

The CLI integration test drives synthetic NCSD headers through the real binary
(import -> fake build -> verify -> catalog -> preview IPA) and, when the
gitignored `ROM/` directory exists, runs header detection against the user's own
ROMs (title IDs/product codes only; no content is logged).

## 12. See also

- [aot-first.md](aot-first.md) -- product route and the shell-side subset (§7)
- [aot-first.md §8](aot-first.md) -- open items handed to parallel tasks
- [build.md](build.md) -- the existing single-game macOS build guide
- [../scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md) -- per-game AOT commands and diagnostics
- [../builder/README.md](../builder/README.md) -- Builder/Agent architecture
- [related-projects.md](related-projects.md) -- S2Arm/NX2Apple references and licenses
