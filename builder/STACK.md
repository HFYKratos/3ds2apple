# Builder stack (2026-11-16)

> **Status: trimmed to the pack pipeline.** This file used to record the stack of
> the retired Build Agent front ends; that design record is in git history. The
> current `builder/` workspace contains only:

| Member | Crate | Language | Purpose |
|---|---|---|---|
| `builder/core` | `builder-core` | Rust 2021 | Streaming SHA-256 helpers shared with the pack pipeline. |
| `builder/pack` | `builder-pack` (`3ds2apple-pack`) | Rust 2021 | Desktop AOT-first import/queue/package/catalogue pipeline and the macOS script plan. |

- One Cargo workspace (`builder/Cargo.toml`), `resolver = "2"`, edition 2021,
  Rust >= 1.80; `cargo test --workspace` is the gate.
- Dependencies are deliberately small: `serde`/`serde_json`/`clap`/`thiserror`
  for the CLI and `sha2`/`hex` for hashing. No async runtime, no network and no
  process execution in the library; the launchers run the compilers.
- Distribution: `3ds2apple-pack.exe` is bundled by the launcher packaging
  scripts (`launcher/windows/tools/prepare-dist*.ps1`,
  `tools/prepare-dist-singlefile.sh`); no builder binary other than the pack CLI
  ships.
- Why the Build Agent stack was removed: the v2 Windows launcher compiles
  GamePacks locally (3dsrecomp + LLVM/LLD) and needs no macOS host, so a second,
  remote implementation would have been dead code. Deleted 2026-11-16.
