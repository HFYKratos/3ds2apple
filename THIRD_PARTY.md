# Third-party components

This repository currently contains planning documents only; no third-party
code is vendored here.

## Planned runtime / tooling

| Component | License | Role |
|---|---|---|
| [Zakuro](https://github.com/fearkov/zakuro) | MIT | 3DS HLE runtime that uses AOT recompilation instead of a JIT |
| [3dsrecomp](https://github.com/fearkov/3dsrecomp) | MIT (declared in `Cargo.toml`) | ARM / Thumb / VFP → C static recompiler |

## Reference only (not linked into the planned pipeline)

| Component | License | Why it is referenced |
|---|---|---|
| [Azahar](https://github.com/azahar-emu/azahar) | GPLv3+ | 3DS HLE / GPU / service reference; iOS libretro core |
| [TriAevum](https://github.com/coccofresco/TriAevum) | GPLv3 | Per-title pure-AOT reference (Ocarina of Time 3D) |
| [nxnative](https://github.com/seedds/nxnative) | MIT | Same-ISA Switch → iOS pipeline reference |
| [S2Arm](https://github.com/jhaizhou-ops/S2Arm) | Apache-2.0 | Same-ISA Switch → iOS pipeline reference |

## Assets

No Nintendo ROMs, decryption keys, system files, fonts, or game assets are
included. Any game data used during a build stays on the user's machine and
is never committed or distributed by this project.