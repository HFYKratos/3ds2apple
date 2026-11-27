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
- Imported `.32a` packages (built on Windows/macOS) deploy without recompiling:
  their embedded GamePack + build cache are used directly.

## Not available yet (P2)

- Local AOT GamePack compilation on Linux is not implemented (P2 R&D). The Deploy
  page states this explicitly and the build step fails with an actionable message;
  it never produces a placeholder pack. Deploy imported `.32a` packages instead.

## Build

Requirements: .NET 10 SDK (or set `DOTNET`) for building on a Linux x86-64 host.
The release payload additionally needs the macOS-built shell template, the Linux
pack CLI/devpush builds and the official plumesign binary.

    # developer build (no payload)
    ./launcher/linux/build-linux.sh

    # P3 release payload + tar.gz
    ./launcher/linux/build-linux.sh --payload --tar \
      --shell-dir /path/to/out/shell \
      --pack-bin  builder/target/release/3ds2apple-pack \
      --devpush-bin tools/devpush/target/release/devpush \
      --plumesign launcher/linux/vendor/plumesign-linux-x86_64

Output: `out/launchers/3ds2apple-launcher-linux-x64/` (+ `.tar.gz`). The payload
layout matches `DistributionLayout.LinuxExpectedRelativePaths`:

    Shell/manifest.json, Shell/3ds2apple-shell.ipa
    ThirdParty/Impactor/plumesign-linux-x86_64 (+ PINS/licences/README)
    Bin/3ds2apple-pack, Bin/devpush
    licenses/LICENSE, licenses/NOTICE, licenses/THIRD_PARTY.md

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
3. Import a ROM or an already-built `.32a`; build (on Windows/macOS) or use the
   imported GamePack.
4. Deploy: compose → plumesign sign/install → devpush push → verify.
5. After 7 days (free Apple ID), press Refresh signing; the app is overwrite-installed
   and existing Documents/saves stay intact.

Known P1/P3 gaps: no Linux local AOT compile (P2); AppImage/desktop-entry packaging
and full QA screenshots on the CachyOS build machine are follow-ups; Deploy copy is
Linux-aware but the local-build row is always an explicit red P2 row.
