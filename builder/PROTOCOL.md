# Builder wire protocol (retired)

> **Removed 2026-11-16.** This document specified the v1 protocol between the
> Builder front ends and a macOS Build Agent. The agent, its clients and the
> golden fixtures were deleted when the v2 Windows launcher moved to a local
> compile (3dsrecomp + LLVM/LLD, no Mac required); no current code implements or
> consumes this protocol.

The last complete specification is in git history (commit 6421e58, file
`builder/PROTOCOL.md`). For the contracts that are still live see:

- [../docs/desktop-aot.md](../docs/desktop-aot.md) — package layout, `GameInfo.json`,
  `GameCatalog.json` schema 2 and the GamePack ABI.
- [../docs/windows-build.md](../docs/windows-build.md) — how the Windows launcher
  compiles and links a GamePack locally.
- [../docs/windows-launcher.md](../docs/windows-launcher.md) — end-to-end launcher
  flow (build -> compose IPA -> sign -> install -> push).
