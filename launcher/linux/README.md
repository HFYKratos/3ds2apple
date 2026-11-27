# 3ds2apple Linux launcher (0.2.3 P0 baseline)

Linux desktop launcher for 3ds2apple. It reuses the shared Avalonia UI and engine
sources from launcher/windows (same Library, Deploy and Settings pages, same
launcher state and build-package formats); the macOS SwiftUI launcher is only a
functional/parity reference and is not compiled here.

## What works in P0

- `dotnet publish -r linux-x64` produces a self-contained executable and the
  Avalonia window starts on Linux (X11/Wayland via Avalonia).
- The Library page (import ROM/.32a UI, export dialog, build cache display) and
  the Settings/Deploy pages render and are usable.
- `--self-test` passes on Linux (optional Windows-only payload/tool probes are
  reported as warnings, not failures).
- The headless UI smoke mode (`--ui-smoke`) runs under Xvfb/WSLg and is used for
  the reproducible screenshots under `out/ui-smoke/`.

## Not done yet (P1+)

- Signing/installing on Linux is not wired yet: the Deploy page currently reports
  the Windows toolchain/warnings. P1 adds the official `plumesign-linux-x86_64`
  login (PTY/terminal interaction for the Apple ID + 2FA, nothing logged),
  `sign --package --register-and-install` and device push.
- Local AOT GamePack compilation on Linux is R&D (P2). Imported `.32a` packages
  that already contain a GamePack remain the supported path until then.
- Linux packaging (tar.gz/AppImage), desktop entry/icon and licence staging into
  a release payload are P3.
- The embedded distribution payload (shell template, pack/devpush CLIs, signing
  helpers) is staged separately by the Linux packaging script; P0 builds use the
  developer layout (`THREEDS2APPLE_*` overrides or PATH).

## Build

Requirements: .NET 10 SDK (or set `DOTNET` to the dotnet binary), a Linux x86-64
host. No ROM, Apple ID, network or iPhone is needed for the P0 build.

    ./launcher/linux/build-linux.sh            # self-contained folder in out/launchers/
    ./launcher/linux/build-linux.sh --tar      # also writes a .tar.gz
    out/launchers/3ds2apple-launcher-linux-x64/3ds2apple-launcher --self-test
    out/launchers/3ds2apple-launcher-linux-x64/3ds2apple-launcher   # GUI

The ZIP/tar contains the launcher plus LICENSE, NOTICE and THIRD_PARTY.md. It is
user data free: no ROM, key, IPA or game asset is included.

## Signing dependency: official plumesign for Linux

The launcher does not bundle a signer in the repository. The official
Impactor v2.7.3 release provides `plumesign-linux-x86_64`; the verified copy lives
in `launcher/linux/vendor/` and is listed in `PINS.json` (SHA-256/size). The
binary is never committed (see `vendor/.gitignore`) and is redistributed
unmodified from the upstream release page:

- Impactor: MIT (see `vendor/LICENSE-Impactor-MIT.txt`),
- apple-codesign embedded in Impactor: MPL-2.0 (see
  `vendor/LICENSE-apple-codesign-MPL-2.0.txt`).

P1 verifies the binary against `PINS.json` before use. The launcher never asks for
or logs the Apple ID, password or 2FA code: accounts are handled by plumesign and
stay in `~/.config/PlumeImpactor`.

## Layout

    launcher/linux/
      README.md                this file
      build-linux.sh           publish a self-contained linux-x64 launcher
      vendor/
        PINS.json              official plumesign-linux pin (sha256/size/version)
        LICENSE-*.txt          upstream licences (MIT / MPL-2.0)
        README-source-and-licenses.txt
        plumesign-linux-x86_64 verified binary (git-ignored, download manually)
