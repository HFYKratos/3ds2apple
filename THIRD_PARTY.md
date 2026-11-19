# Third-party components

This repository contains the iOS shell, the Zakuro C ABI crate, the desktop
builder and the device bridge. Third-party source is fetched at build time and
is not vendored here.

## Runtime and tooling

| Component | License | Role |
|---|---|---|
| [Zakuro](https://github.com/fearkov/zakuro) | MIT | 3DS HLE runtime that runs AOT code without a CPU JIT |
| [3dsrecomp](https://github.com/fearkov/3dsrecomp) | MIT (declared in Cargo.toml; no LICENSE file upstream — build tool only, never vendored) | ARM / Thumb / VFP → C static recompiler |
| [Pocket Native](https://github.com/whovian64/pocket-native) v0.6.1 | MIT | Zakuro + 3dsrecomp AOT fork, reference only (not vendored, linked or redistributed): static Linked integration, GLES rendering and per-game profile reference for the iOS port |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) 1.4.2 | Apache-2.0 | Vulkan → Metal compatibility layer for the PICA200 renderer. The pinned ios-arm64 dynamic framework (SHA-256 pinned in the shell template and the macOS launcher) is embedded in the iOS shell template and in the macOS launcher; a build/packaging input, not committed to git |
| [idevice](https://github.com/jkcoxson/idevice) | MIT | Rust usbmuxd/lockdownd/AFC/installation_proxy client used by tools/devpush (pinned to commit 5171e34e3a236842af1160a84d955d037ddca3af) |
| [LLVM/Clang/LLD](https://llvm.org) 23.1.6 | Apache-2.0 WITH LLVM-exception | Local Windows/Linux GamePack cross-builder and the Windows launcher's only build path since 0.1.0 (tools/winbuild); official binaries SHA-256 pinned in tools/winbuild/llvm-manifest.json; no Apple SDK used |
| [Impactor](https://github.com/claration/impactor) v2.7.3 + plumesign | MIT (Copyright 2025 Samara M) | Official signing/install tool bundled unmodified by the Windows launcher; SHA-256 pinned in launcher/windows/vendor/impactor/PINS.json |
| [apple-codesign](https://github.com/claration/impactor/tree/v2.7.3/3rdparty/apple-codesign-0.29.0) 0.29.0 | MPL-2.0 | Code-signing engine embedded inside the official Impactor binary; MPL text kept in licenses/impactor/ |
| [Avalonia](https://github.com/AvaloniaUI/Avalonia) 12.1.6 | MIT | .NET desktop UI framework used by the Windows launcher (launcher/windows, shipped self-contained) |
| [.NET](https://github.com/dotnet/runtime) 10 | MIT | Runtime/SDK used by the Windows launcher and its self-contained Windows publish |

The official Impactor/plumesign release files are downloaded from
<https://github.com/claration/impactor/releases/tag/v2.7.3> at launcher
packaging time (download-or-bundled mode, SHA-256 verified), are shipped
unmodified, and are not committed to this repository. The MIT and MPL-2.0
license texts are committed under licenses/impactor/ together with the
pinned SHA-256 list and source links.

The Windows/Linux local GamePack build (tools/winbuild, the Windows launcher's
LocalWinbuildPackProvider and its only Deploy build path since 0.1.0) uses the
official **LLVM 23.1.6** release: Clang, `ld64.lld`, `llvm-ar`, `llvm-nm` and
`llvm-objdump`, licensed under **Apache-2.0 WITH LLVM-exception**
(<https://llvm.org/LICENSE.txt>). The
release archives/installers and their SHA-256 values are pinned in
`tools/winbuild/llvm-manifest.json`; the toolchain is either installed by the
user or bundled unmodified with the licence text and LLVM copyright notices.
No Apple SDK header, `.tbd` stub library, Xcode component or other Apple file is
used or redistributed by this path: the generated C compiles `-nostdinc`
against the hand-written ISO C headers in `tools/winbuild/darwin-stubs`, and the
GamePack links with `-undefined dynamic_lookup` exactly like the Xcode-built
pack. `3dsrecomp` declares MIT in its Cargo.toml but ships no upstream LICENSE file; it
is cloned at a pinned revision at build time and run only as a build tool, never
vendored or redistributed.

## License texts in the release packages

Every release publishes exactly two assets: the Windows and macOS launcher zips.
From 0.1.1 on, each zip contains `LICENSE`, `NOTICE` and `THIRD_PARTY.md` at its
archive root, byte-identical to the files in this repository; they are not
published as separate release assets. The Windows launcher additionally embeds
the same texts and the Impactor MIT / apple-codesign MPL-2.0 licence files in its
self-contained payload and extracts them on first run. The macOS launcher `.app`
is unchanged; the three project texts sit next to it at the zip root.

The GPL-2.0 and GPL-3.0 projects in the next table are read as architecture
references only; no GPL code or text is copied into this repository or shipped in
the packages.

## Reference only (not linked into this project)

| Component | License | Why it is referenced |
|---|---|---|
| [Azahar](https://github.com/azahar-emu/azahar) | GPLv3+ | 3DS HLE / GPU / service behaviour reference |
| [Citra](https://github.com/citra-emu/citra) | GPLv2+ | PICA200 semantics and compatibility reference |
| [TriAevum](https://github.com/coccofresco/TriAevum) | GPLv3 | Per-title pure-AOT reference |
| [nxnative](https://github.com/seedds/nxnative) | MIT | Same-ISA Switch → iOS pipeline and Metal platform-layer reference |
| [S2Arm](https://github.com/jhaizhou-ops/S2Arm) | Apache-2.0 | Same-ISA Switch → iOS build/launcher reference and the device-bridge API usage pattern (usbmuxd + house_arrest VendContainer/AFC + installation_proxy) |

## Assets

No Nintendo ROMs, decryption keys, system files, fonts or game assets are
included. Game data stays on the user's machine and is never committed or
distributed by this project.
