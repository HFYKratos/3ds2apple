# 3ds2apple Linux launcher (0.2.3 P0/P1/P3)

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
  No Apple SDK, macOS or Windows is used. The exact LLVM pin is 23.1.6 when
  fetchable; the current CachyOS fallback is 23.1.5 (actual version is written to
  the payload's `PINS-local-aot.json` — no version is misreported).

## Build

Requirements: .NET 10 SDK (or set `DOTNET`) for building on a Linux x86-64 host.
The release payload additionally needs the macOS-built shell template, the Linux
pack CLI/devpush builds and the official plumesign binary.

    # developer build (no payload)
    ./launcher/linux/build-linux.sh

    # release payload + tar.gz (P1/P3 + P2 local AOT)
    ./launcher/linux/build-linux.sh --payload --local-aot --tar \
      --shell-dir /path/to/out/shell \
      --pack-bin  builder/target/release/3ds2apple-pack \
      --devpush-bin tools/devpush/target/release/devpush \
      --plumesign launcher/linux/vendor/plumesign-linux-x86_64 \
      --llvm-dir /path/to/llvm/bin \
      --recompiler-bin /path/to/linux/3dsrecomp

Output: `out/launchers/3ds2apple-launcher-linux-x64/` (+ `.tar.gz`). The payload
layout matches `DistributionLayout.LinuxExpectedRelativePaths`:

    Shell/manifest.json, Shell/3ds2apple-shell.ipa
    ThirdParty/Impactor/plumesign-linux-x86_64 (+ PINS/licences/README)
    Bin/3ds2apple-pack, Bin/devpush
    Bin/3dsrecomp, Bin/llvm/bin/{clang,llvm-ar,ld64.lld}, Bin/llvm/lib/clang/<ver>/include
    tools/winbuild/darwin-stubs, tools/winbuild/zk_gamepack_shim.c, tools/winbuild/include
    PINS-local-aot.json, licenses/LICENSE, licenses/NOTICE, licenses/THIRD_PARTY.md

Run the packaged build with `/path/to/3ds2apple-launcher --self-test`, then start
the GUI. On a headless machine use `xvfb-run -a ./3ds2apple-launcher`.

## Signing dependency and licences

`launcher/linux/vendor/plumesign-linux-x86_64` is the unmodified official Impactor
v2.7.3 Linux binary (SHA-256/size in `vendor/PINS.json`; download it from the
upstream release). It is never committed (`vendor/.gitignore`) and is only
executed, not modified. Impactor is MIT; the embedded apple-codesign library is
MPL-2.0 — see `vendor/LICENSE-*.txt` and `vendor/README-source-and-licenses.txt`.
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

Known P2 gaps: the exact LLVM 23.1.6 release asset was not fetchable on the current
build network (payload uses 23.1.5 and records the truth in PINS-local-aot.json);
3dsrecomp is currently built on WSL and copied because CachyOS cargo cannot fetch its
git dependency; AppImage/desktop-entry packaging is a follow-up.
