# AOT game builds

3ds2apple builds each game ahead of time:

```text
ROM → 3dsrecomp (generated C) → clang for arm64-apple-ios → libgame.a
    → linked into the app together with libzakuro_ios.a → unsigned IPA
```

The repository never stores the ROM, the generated C or the resulting IPA.

Each game IPA also carries a build-time `GameCatalog.json` (see
[GameCatalog and the per-game IPA](#gamecatalog-and-the-per-game-ipa-s2arm-style-distribution)
below): the phone only selects and launches the AOT code already linked into the
app; it never recompiles a ROM on device.

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

# 3. Build the app, generate its GameCatalog.json and package the unsigned IPA.
scripts/build-game-ipa.sh game-name \
  --title-id 0004000000055E00 \
  --display-name "Game name" \
  --product-code CTR-P-EKJA
```

Outputs:

```text
build/game/game-name/code/librecomp.a       generated game code (local)
build/ios/game-name/libzakuro_ios.a         linked runtime (local)
build/ios/game-name/libgame.a               copy of the generated archive
build/ios/game-name/build-info.txt          title ID, revisions
build/ios/game-name/manifest.txt            build manifest (incl. catalog hash)
IPA/3ds2apple-game-name-<version>.ipa       unsigned IPA for one AOT game
ios/app/Resources/GameCatalog.json          only during the build (generated,
                                            bundled into the .app, removed after)
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
| `--title-id ID` | 16-hex title ID recorded in the catalog and manifest (default: resolved from `build-info.txt` / `recomp-info.txt` / `src/main.rs`) |
| `--display-name NAME` | Home-screen display name and catalog `displayName` |
| `--product-code CODE` | Catalog `productCode` (e.g. `CTR-P-EKJA`) |
| `--aot-version N` | Catalog `aotVersion` (default `1`) |
| `--bundle-id ID` | Per-game bundle identifier |
| `--lib-dir DIR` | Alternate `build/ios/<name>` directory |
| `--out-dir DIR` | Alternate IPA output directory |
| `--ipa-name NAME` | Explicit IPA file name without `.ipa` |
| `--ipa-version VER` | Override the version in the default `3ds2apple-<name>-<version>` name |
| `--clean-project` | Delete the generated Xcode project afterwards (default: keep; it is gitignored) |

## GameCatalog and the per-game IPA (S2ARM-style distribution)

A game IPA is self-describing. `build-game-ipa.sh` generates
`ios/app/Resources/GameCatalog.json` before `xcodegen` runs, so the catalog is
copied into the `.app` and ships inside the IPA with exactly one game:

```json
{"schemaVersion":1,"games":[{"titleID":"0004000000055E00","displayName":"Pokémon Y","productCode":"CTR-P-EKJA","aot":true,"aotVersion":1,"notes":""}]}
```

`ios/app/Sources/GameCatalog.swift` reads it: a ROM whose title ID is listed
with `aot: true` runs the AOT code linked into the app, anything else falls
back to the interpreter. The phone only selects and launches - all compilation
happens on the build machine. The plain shell build (`build-ios-app.sh`)
ships an empty catalog (`{"schemaVersion":1,"games":[]}`) and is
interpreter-only; `build-ios-app.sh --game-catalog PATH` can bundle a
pre-generated catalog for advanced multi-game apps.

The catalog is a build artifact: installed for the duration of the build,
verified inside the built `.app` (fatal when missing or invalid), and removed
(or restored) on exit, including failures. `.gitignore` covers it as a
safeguard, so a finished build leaves `git status` clean.

### Verify a game IPA

```bash
scripts/build-game-ipa.sh pokemon-y \
  --title-id 0004000000055E00 \
  --display-name "Pokémon Y" \
  --product-code CTR-P-EKJA

# 1. the catalog is inside the IPA and lists exactly this title
unzip -p IPA/3ds2apple-pokemon-y-0.1.2.ipa Payload/3ds2apple.app/GameCatalog.json

# 2. manifest cross-check (title ID, catalog hash, IPA hash)
grep -E '^(title_id|game_catalog_title_id|game_catalog_sha256|ipa_sha256)=' \
  build/ios/pokemon-y/manifest.txt

# 3. nothing generated is left in the working tree
git status --porcelain      # empty; GameCatalog.json is ignored and removed
```

Acceptance checklist for one game:

- [ ] IPA is named `3ds2apple-<name>-<version>.ipa` and `<version>` equals
      the app `CFBundleShortVersionString` (SideStore's `source.json` requires
      this).
- [ ] `GameCatalog.json` inside the app lists exactly 1 game with
      `aot: true` and `titleID == manifest title_id`.
- [ ] `scripts/package-ipa.sh` prints
      `CATALOG: games=1; AOT: <title> (<titleID>)`.
- [ ] On device the ROM shows `AOT: linked, active` (not
      `linked, interpreting`) and a 20-minute session is stable (evidence under
      `docs/qa/`).
- [ ] `git status` is clean; no ROM, generated C, catalog or IPA is tracked.

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
| `the built app contains no GameCatalog.json` | `Resources/` is no longer bundled by `ios/app/project.yml`, or xcodegen ran before the catalog install; re-run the build |
| `invalid GameCatalog.json` | corrupted generated catalog or a broken `--game-catalog` input; re-run `build-game-ipa.sh` (title IDs are 16 upper-case hex digits) |
| App launches but no ROM | the ROM lives only on your device; import it in the app |
