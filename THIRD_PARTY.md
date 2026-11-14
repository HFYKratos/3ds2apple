# Third-party components

This repository contains the iOS shell, the Zakuro C ABI crate, the desktop
builder and the device bridge. Third-party source is fetched at build time and
is not vendored here.

## Runtime and tooling

| Component | License | Role |
|---|---|---|
| [Zakuro](https://github.com/fearkov/zakuro) | MIT | 3DS HLE runtime that runs AOT code without a CPU JIT |
| [3dsrecomp](https://github.com/fearkov/3dsrecomp) | MIT (declared in Cargo.toml; no LICENSE file upstream — build tool only, never vendored) | ARM / Thumb / VFP → C static recompiler |
| [Pocket Native](https://github.com/whovian64/pocket-native) | MIT | Zakuro + 3dsrecomp AOT fork; reference for static Linked integration, GLES rendering and per-game profiles |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Apache-2.0 | Planned Vulkan → Metal compatibility layer for the renderer |
| [idevice](https://github.com/jkcoxson/idevice) | MIT | Rust usbmuxd/lockdownd/AFC/installation_proxy client used by tools/devpush (pinned to commit 5171e34e3a236842af1160a84d955d037ddca3af) |
| [LLVM/Clang/LLD](https://llvm.org) 21.1.8 | Apache-2.0 WITH LLVM-exception | Optional local Windows/Linux GamePack cross-builder (tools/winbuild); official binaries SHA-256 pinned in tools/winbuild/llvm-manifest.json; no Apple SDK used |
| [Impactor](https://github.com/claration/impactor) v2.7.2 + plumesign | MIT (Copyright 2025 Samara M) | Official signing/install tool bundled unmodified by the launchers; SHA-256 pinned in builder/device/impactor.py |
| [apple-codesign](https://github.com/claration/impactor/tree/v2.7.2/3rdparty/apple-codesign-0.29.0) 0.29.0 | MPL-2.0 | Code-signing engine embedded inside the official Impactor binary; MPL text kept in scripts/impactor/licenses/ |
| [Avalonia](https://github.com/AvaloniaUI/Avalonia) 12.1.5 | MIT | .NET desktop UI framework used by the Windows launcher (launcher/windows, shipped self-contained) |
| [.NET](https://github.com/dotnet/runtime) 10 | MIT | Runtime/SDK used by the Windows launcher and its self-contained Windows publish |

The official Impactor/plumesign release files are downloaded from
<https://github.com/claration/impactor/releases/tag/v2.7.2> at launcher
packaging time (download-or-bundled mode, SHA-256 verified), are shipped
unmodified, and are not committed to this repository. The MIT and MPL-2.0
license texts are committed under scripts/impactor/licenses/ together with the
pinned SHA-256 list and source links.

The optional Windows/Linux local GamePack build (tools/winbuild, the Windows
launcher's experimental LocalPackBuildProvider) uses the official **LLVM 21.1.8**
release: Clang, `ld64.lld`, `llvm-ar`, `llvm-nm` and `llvm-objdump`, licensed
under **Apache-2.0 WITH LLVM-exception** (<https://llvm.org/LICENSE.txt>). The
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
