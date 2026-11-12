# Third-party components

This repository contains the iOS shell, the Zakuro C ABI crate and build
scripts. Third-party source is fetched at build time and is not vendored here.

## Runtime and tooling

| Component | License | Role |
|---|---|---|
| [Zakuro](https://github.com/fearkov/zakuro) | MIT | 3DS HLE runtime that runs AOT code without a CPU JIT |
| [3dsrecomp](https://github.com/fearkov/3dsrecomp) | MIT | ARM / Thumb / VFP → C static recompiler |
| [Pocket Native](https://github.com/whovian64/pocket-native) | MIT | Zakuro + 3dsrecomp AOT fork; reference for static `Linked` integration, GLES rendering and per-game profiles |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Apache-2.0 | Planned Vulkan → Metal compatibility layer for the renderer |

## Reference only (not linked into this project)

| Component | License | Why it is referenced |
|---|---|---|
| [Azahar](https://github.com/azahar-emu/azahar) | GPLv3+ | 3DS HLE / GPU / service behaviour reference |
| [Citra](https://github.com/citra-emu/citra) | GPLv2+ | PICA200 semantics and compatibility reference |
| [TriAevum](https://github.com/coccofresco/TriAevum) | GPLv3 | Per-title pure-AOT reference |
| [nxnative](https://github.com/seedds/nxnative) | MIT | Same-ISA Switch → iOS pipeline and Metal platform-layer reference |
| [S2Arm](https://github.com/jhaizhou-ops/S2Arm) | Apache-2.0 | Same-ISA Switch → iOS build and launcher reference |

## Assets

No Nintendo ROMs, decryption keys, system files, fonts or game assets are
included. Game data stays on the user's machine and is never committed or
distributed by this project.
