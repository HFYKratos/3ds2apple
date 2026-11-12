# AOT game builds

3ds2apple builds each game ahead of time:

```text
ROM → 3dsrecomp (generated C) → clang for arm64-apple-ios → libgame.a
    → linked into the app together with libzakuro_ios.a → unsigned IPA
```

The repository never stores the ROM, the generated C or the resulting IPA.

## Prerequisites

- macOS with Xcode + iOS SDK.
- Rust with `aarch64-apple-ios`.
- Python 3.
- A local decrypted `.3ds` / `.cci` that you own.

Run from the repository root. `scripts/build-zakuro-ios.sh` must have produced
the runtime checkout/static library first.

## Split build (recommended)

```bash
# 1. Recompile the game and compile its C for iOS.
scripts/build-recomp-ios.sh "ROM/game.cci" game-name --auto-serial

# 2. Build the linked runtime for that title and collect both archives.
scripts/build-linked-ios-lib.sh game-name

# 3. Build the app and package the unsigned IPA.
scripts/build-game-ipa.sh game-name --display-name "Game name"
```

Outputs:

```text
build/game/game-name/code/librecomp.a       generated game code (local)
build/ios/game-name/libzakuro_ios.a         linked runtime (local)
build/ios/game-name/libgame.a               copy of the generated archive
build/ios/game-name/build-info.txt          title ID, revisions
build/ios/game-name/manifest.txt            build manifest
IPA/game-name-AOT.ipa                       unsigned IPA
```

## Options

### `build-recomp-ios.sh`

| Option | Meaning |
|---|---|
| `--auto-serial` | Retry serially if parallel compilation runs out of memory |
| `--serial-compile` | Compile one file at a time |
| `--code-dir DIR` | Reuse already-generated C instead of running 3dsrecomp |
| `--archive FILE` | Reuse an existing `librecomp.a` |
| `--title-id ID` | Explicit 16-hex title ID (otherwise read from generated files/build info) |
| `--recomp-rev REV` | Pin 3dsrecomp revision |
| `--force` | Recompile/re-copy instead of incremental reuse |

### `build-linked-ios-lib.sh`

| Option | Meaning |
|---|---|
| `--reuse` | Reuse existing `build/game/<name>/` output |
| `--title-id ID` | Explicit title ID |
| `--isolated-target` | Use a per-game Cargo target directory |

### `build-game-ipa.sh`

| Option | Meaning |
|---|---|
| `--display-name NAME` | Home-screen display name |
| `--bundle-id ID` | Per-game bundle identifier |
| `--lib-dir DIR` | Alternate `build/ios/<name>` directory |
| `--out-dir DIR` | Alternate IPA output directory |
| `--ipa-name NAME` | IPA file name without `.ipa` |
| `--keep-project` | Keep the generated Xcode project |

## Version matching

The linked code and the runtime must be built from compatible revisions:

- use the 3dsrecomp revision pinned by the Zakuro checkout's `Cargo.lock`
  (`recomp-abi` git source);
- do not mix a Pocket Native recompiler (interface 7) with vanilla Zakuro
  (interface 5) — they are separate stacks;
- when updating either side, regenerate the game code and rebuild the linked
  runtime.

If the title ID or interface version does not match, Zakuro logs a fallback and
runs the interpreter instead of the linked code. This is safe but much slower.

## Diagnostics

The app shows:

```text
AOT: linked, active       # linked code accepted
AOT: linked, interpreting # title/ABI mismatch, interpreter fallback
AOT: interpreter shell    # build contains no linked code
```

Runtime logs use `zk_create: …`, `AOT active/inactive: …` and `zk_perf: …`.
Inspect them with `idevicesyslog` or Xcode's device console if the status line
does not explain a fallback.

## Serial compile fallback

Large generated files can exhaust memory on an 8 GB build VM. If the parallel
compile fails:

```bash
scripts/build-recomp-ios.sh "ROM/game.cci" game-name --serial-compile
```

The script also accepts `--code-dir` to recompile an existing generated C tree
incrementally.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `missing librecomp.a` | 3dsrecomp step did not finish; check its log |
| Undefined `_recomp_*` at app link | `libgame.a` missing or listed before `libzakuro_ios.a` |
| `AOT: linked, interpreting` | title ID/interface mismatch; rebuild both sides |
| `no space left on device` | generated C and object files are large; clean `build/` |
| App launches but no ROM | the ROM lives only on your device; import it in the app |
