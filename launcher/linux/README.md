# 3ds2apple Linux launcher

Linux desktop launcher for 3ds2apple. It reuses the shared Avalonia UI and engine
sources from launcher/windows (same Library, Deploy and Settings pages, same
launcher state and build-package formats); the macOS SwiftUI launcher is only a
functional/parity reference and is not compiled here.

## What works

- Self-contained `linux-x64` GUI: Library (import ROM/.32a, export dialog, build
  cache), Deploy, Settings; `--self-test` and the headless `--ui-smoke` mode run
  on Linux (X11/Wayland; Xvfb/WSLg works for screenshots).
- Signing/installing uses the official `plumesign-linux-x86_64` from Impactor
  v2.7.3 (SHA-256 pinned in `vendor/PINS.json`, never committed):
  - Settings → "Sign in with plumesign" opens a terminal for
    `plumesign account login`; the Apple ID/password/2FA stay in that terminal
    and in plumesign's own store (`~/.config/PlumeImpactor`). The launcher only
    reads whether an account is saved; it never sees or logs credentials.
  - Deploy composes the ROM-free app IPA and runs
    `plumesign sign --package <ipa> --apple-id --register-and-install --udid <udid> -o <signed.ipa>`
    (falling back to sign + `device --install`), then pushes game data through the
    Linux `devpush` device bridge.
  - "Refresh signing" re-signs/overwrite-installs the last composed or exported IPA
    without recompiling or recomposing it (free Apple ID 7-day renewal; app data in
    Documents/saves is kept).
- Devices are discovered through `devpush` (Linux build) with a read-only
  `usbmuxd` fallback (`/var/run/usbmuxd`; override with
  `THREEDS2APPLE_USBMUXD_SOCKET`). USB + unlock + Trust is required.
- Imported `.32a` packages deploy without recompiling: their embedded GamePack +
  build cache are used directly.
- **Local AOT build on Linux (P2)**: when the payload includes the local-AOT tools
  (`Bin/3dsrecomp`, `Bin/llvm/bin/{clang,llvm-ar,ld64.lld}`, `Bin/llvm/lib/clang/<ver>/include`,
  `tools/winbuild/darwin-stubs`, the GamePack shim and headers), Deploy/Library can
  compile a user's ROM into a real arm64 iOS GamePack on this PC (3dsrecomp →
  clang `-target arm64-apple-ios16.0` → ld64.lld), then record/export a `.32a`.
  No Apple SDK, macOS or Windows is used. The staged LLVM pin is the exact official 23.1.6 release; the actual version is
  written to the payload's `PINS-local-aot.json` (no version is misreported).

## Build

Requirements: .NET 10 SDK (or set `DOTNET`) for building on a Linux x86-64 host.
The release payload additionally needs:

- the macOS-built shell template (from the local macOS VM);
- the Rust `3ds2apple-pack` and `devpush` Linux builds;
- the official plumesign-linux binary (downloaded and pinned, never committed);
- for `--local-aot`: the exact official LLVM 23.1.6 Linux toolchain (`clang`,
  `llvm-ar`, `ld64.lld`, `lib/clang/23/include`) and a Linux `3dsrecomp` release
  build (clone `third_party/3dsrecomp` at the pinned revision and
  `cargo build --release`).

    # developer build (no payload)
    ./launcher/linux/build-linux.sh

    # release payload + tar.gz (P1/P3 + P2 local AOT)
    ./launcher/linux/build-linux.sh --payload --local-aot --tar \
      --shell-dir /path/to/out/shell \
      --pack-bin  builder/target/release/3ds2apple-pack \
      --devpush-bin tools/devpush/target/release/devpush \
      --plumesign launcher/linux/vendor/plumesign-linux-x86_64 \
      --llvm-dir third_party/llvm-23.1.6-linux/bin \
      --recompiler-bin third_party/3dsrecomp/target/release/3dsrecomp

Output: `out/launchers/3ds2apple-launcher-linux-x64/` (+ `.tar.gz`). The payload
layout matches `DistributionLayout.LinuxExpectedRelativePaths`:

    Shell/manifest.json, Shell/3ds2apple-shell.ipa
    ThirdParty/Impactor/plumesign-linux-x86_64 (+ PINS/licences/README)
    Bin/3ds2apple-pack, Bin/devpush
    Bin/3dsrecomp, Bin/llvm/bin/{clang,llvm-ar,ld64.lld}, Bin/llvm/lib/clang/<ver>/include
    tools/winbuild/darwin-stubs, tools/winbuild/zk_gamepack_shim.c, tools/winbuild/include
    PINS-local-aot.json
    licenses/LICENSE, licenses/NOTICE, licenses/THIRD_PARTY.md (the three repository
      licence texts, copied verbatim; the optional local-AOT toolchain licences are
      staged as licenses/LLVM-LICENSE.txt and licenses/3dsrecomp-LICENSE.txt and
      never replace the repository texts)

Run the packaged build with `/path/to/3ds2apple-launcher --self-test`, then start
the GUI. On a headless machine use `xvfb-run -a ./3ds2apple-launcher`.

### `--skip-publish` and the stale-publish guard

`--skip-publish` reuses the launcher already published in `--output` instead of
running `dotnet publish` (used to stage the payload on a host without .NET), but
it never rebuilds that launcher: pointing it at an old publish folder silently
packages the old version. The published v0.3.0 Linux tar was built that way and
reported `0.2.2-beta6` while the Windows/macOS assets reported `0.3.0`.

`build-linux.sh` therefore runs a stale-publish guard right after the
publish/reuse step: it reads `<Version>` from
`launcher/windows/Directory.Build.props` and compares it with the
`3ds2apple-launcher/<ver>` deps.json project key embedded in the staged .NET
single-file launcher bundle (plain UTF-8; nothing is extracted or executed). A
mismatch, or a bundle without the key, exits 2 — rebuild without
`--skip-publish` or point `--output` at a fresh publish folder.
`scripts/release/verify-release.sh` performs the same cross-check on the release
Linux tar, so a stale launcher also fails the release gate.

## Signing dependency and licences

`launcher/linux/vendor/plumesign-linux-x86_64` is the unmodified official Impactor
v2.7.3 Linux binary (SHA-256/size in `vendor/PINS.json`; download it from the
upstream release). It is never committed (`vendor/.gitignore`) and is only
executed, not modified. Impactor is MIT; the embedded apple-codesign library is
MPL-2.0 — see `vendor/LICENSE-*.txt` and `vendor/README-source-and-licenses.txt`.
The local-AOT payload additionally carries the official LLVM licence
(Apache-2.0 WITH LLVM-exception) as `licenses/LLVM-LICENSE.txt` and the 3dsrecomp
licence as `licenses/3dsrecomp-LICENSE.txt` when those sources are available;
`licenses/{LICENSE,NOTICE,THIRD_PARTY.md}` always stay the repository texts.
The launcher provides no ROM, key, IPA or game asset and never uploads anything.

## Real-device acceptance

1. Connect the iPhone/iPad by USB, unlock and tap Trust; install/start usbmuxd.
2. Settings → Sign in with plumesign; enter the Apple ID and 2FA in the terminal.
3. Import a ROM or an already-built `.32a`; with the local-AOT payload, Deploy
   compiles the ROM into a real GamePack on Linux (no Windows/macOS build needed).
4. Deploy: build (only when the cache is stale) → compose → plumesign sign/install →
   devpush push → verify.
5. After 7 days (free Apple ID), press Refresh signing; the app is overwrite-installed
   and existing Documents/saves stay intact.

## Payload state (0.3.0)

The published 0.3.0 payload carries the exact official LLVM **23.1.6** toolchain
and the Linux `Bin/3dsrecomp`. `PINS-local-aot.json` records the actual staged
versions and the recompiler SHA-256, and `scripts/release/verify-release.sh`
pins LLVM 23.1.6 and cross-checks that digest against the shipped
`Bin/3dsrecomp`.

Remaining follow-ups are not release blockers: AppImage/desktop-entry packaging
(the release artifact is the launcher-folder `tar.gz`), and the local-AOT path
has had less real-device exposure than the Windows path — report issues on the
tracker.
