# Contributing

Thanks for helping 3ds2apple. The project is an early-stage native iOS port of
Nintendo 3DS games; the most useful contributions are:

- build and run instructions for macOS / Xcode versions;
- compatibility reports: game, title ID, region, version, what works and what
  breaks;
- fixes to the SwiftUI shell, the Zakuro C ABI or the build scripts;
- performance work on the software renderer or a Metal/Vulkan backend;
- documentation that makes the build path easier to reproduce.

## Documentation rules

- **`README.md` / `README.zh-CN.md` are the only user-facing usage guides.**
  Installation, signing, import, deploy and push instructions live there and
  must stay in sync in both languages.
- Developer notes live in the component READMEs (`launcher/windows`,
  `launcher/macos`, `ios/app`, `builder`, `tools/devpush`, `tools/winbuild`)
  and in `scripts/README.md`. There is no separate product documentation
  directory.
- Release notes never repeat the usage guide; they link to the README.

## Ground rules

1. **No ROMs, keys, system files or game assets.** Do not attach them to issues,
   pull requests or logs. Only use your own legally obtained, decrypted games.
2. **No piracy links or instructions.** Compatibility reports should describe
   the game and the bug, not where to obtain it.
3. **Keep the pipeline AOT.** The iOS build must not depend on a CPU JIT.
   Zakuro's small interpreter fallback is expected; adding a JIT is out of
   scope.
4. **Licenses.** This repository is Apache-2.0. Zakuro and 3dsrecomp are MIT;
   keep their notices. Do not paste GPL code (Azahar, Citra, TriAevum) into this
   repository.
5. **Generated code is game-derived.** Never commit the C produced by
   3dsrecomp, compiled archives, IPAs or extracted game assets. Build outputs
   belong in `build/`, `IPA/` or `third_party/`, which are ignored.
6. **One topic per pull request.** Include the command you ran, the host
   configuration and a short log excerpt where relevant.

## Reporting a build or game issue

Please include:

- host OS and Xcode version;
- Zakuro / 3dsrecomp commit or release;
- game title, title ID, region and version (base / update / DLC);
- whether the game was recompiled and whether the app shows
  `AOT: linked, active` or `linked, interpreting`;
- the last 50 lines of the build or device log.

Do not upload the ROM, generated C code or a signed IPA.

## Pull requests

By contributing, you agree that your contribution is licensed under
Apache-2.0. Keep changes focused and update the relevant public documentation:
the root README for user-facing behavior and the component README for developer
details.

## Release policy

Never name a commercial game in release notes, the README, issue templates or any other repository text: say "a retail title" / "部分游戏、某款游戏" instead. Compatibility reports may include a title ID, but no game name is needed.

Public releases are GitHub Releases on
<https://github.com/HFYKratos/3ds2apple/releases>. The policy is intentionally
minimal: users download one package, and GitHub provides the asset digests.

### Repository page branding

- The repository README shows the app icon from `docs/assets/readme-icon.png`.
- GitHub does **not** expose an API for a repository's social preview (and a
  user-owned repository's avatar is the account avatar). Upload
  `docs/assets/social-preview.png` (1280x640) once in **Settings -> Social
  preview** so link previews show the app icon.

### Assets (exactly two)

Attach only the two platform packages produced by the release build:

| Asset | Content |
|---|---|
| `3ds2apple-<version>-windows-x64.zip` | Windows 10/11 launcher; one self-contained executable plus `LICENSE`, `NOTICE`, `THIRD_PARTY.md` at the ZIP root |
| `3ds2apple-<version>-macos-universal.zip` | macOS 13+ launcher (`.app`, Intel + Apple silicon) plus the same three licence texts at the ZIP root |

**Licence texts ship inside the packages, never as separate assets.** Both
platform zips carry `LICENSE`, `NOTICE` and `THIRD_PARTY.md` at their root,
byte-identical to the repository files; `verify-release.sh` enforces this and
`scripts/tests/release-selfcheck.sh` proves the gate offline with synthetic
zips. **Never attach as separate Release assets:** `LICENSE`, `NOTICE`,
`THIRD_PARTY.md`, a `SHA256SUMS.txt`, the ROM-free shell IPA template, per-game
IPAs, GamePacks/dylibs, generated C, ROMs, keys/BIOS, credentials or
certificates, or screenshots containing game art. The shell template is
embedded in the launchers; the licence texts also remain in the repository (and
inside the Windows launcher payload); each asset's SHA-256 digest is visible on
the GitHub Release assets page (and can be computed locally).

### Release body: fixed bilingual format

Every Release page uses the same body: a version heading, new features and
fixes, with each item bilingual. The body describes only the changes in that
version — no known-issue lists, installation instructions or asset lists (issues
live in the issue tracker, usage in the README and assets are shown
automatically by GitHub).

```markdown
# <version>

### 新功能 / What's new
- 中文一句话说明新功能
  *One-line English description of the new feature*

### 修复 / Fixes
- 中文一句话说明修复
  *One-line English description of the fix*
```

- Write the Chinese line first, then the English line in italics, matching the
  project's existing release pages.
- Keep each item to one line and describe a user-facing change.
- Always include both `新功能 / What's new` and `修复 / Fixes`; if a section has
  nothing, write `- 无 / None` rather than dropping it.
- Do not include a known-issues section, an installation walk-through, an asset
  checklist or a usage guide in the Release body. Link to the README for usage
  and installation instead.
- Note an unverified platform in one factual sentence at most.
- **README and website updates never contain a per-version update log.** Keep
  capabilities in the existing Features / Controls / Layouts sections without
  version headings; version-specific change history belongs on the Release page
  only.

### Process

1. Build the two packages and run the project test gates (`cargo test`,
   `dotnet test`, `scripts/tests/*-selfcheck.sh`, including
   `bash scripts/tests/release-selfcheck.sh`); the Windows package must pass
   its clean-folder `--self-test` and, on a Windows host, the native
   `bash scripts/release/win-selftest.sh --zip <windows zip> --expect-version <version>`
   (32 PASS / 0 FAIL / 0 WARN, version line, exit 0).
2. Assemble the release directory (this also renames the build artifacts to the
   canonical asset names and runs the verifier):

   ```bash
   bash scripts/release/assemble-release.sh --version v<version> \
     --windows-zip out/launchers/3ds2apple-windows-single-<version>.zip \
     --macos-zip out/launchers/3ds2apple-launcher-<version>-macos-app.zip
   bash scripts/release/verify-release.sh --release-dir out/release/v<version> \
     [--win-selftest-log <log from win-selftest.sh>]
   ```

   The verifier requires both zips to carry `LICENSE`, `NOTICE` and
   `THIRD_PARTY.md` at the ZIP root with SHA-256 digests equal to the repository
   files, and it still requires exactly the two platform assets.

3. Create the annotated tag and the GitHub Release; the **release title is only
   the version number** (`<version>`, e.g. `0.1.0`):

   ```bash
   git tag -a v<version> -m "3ds2apple <version>"
   gh release create v<version> --title "<version>" --notes-file <notes.md> \
     out/release/v<version>/*
   ```

4. Optionally mark a pre-release when a platform is explicitly unverified; do
   not claim verified states you do not have.
5. Download the published assets once into a clean directory and check them
   against the digests shown on the Release page.

### Immutability

Released tags and assets are immutable: never move, delete or force-push a
published tag, and never silently replace an uploaded asset. Fixes ship as a
new version (for example `0.1.1`); the old release stays available and is
marked superseded in its notes.
