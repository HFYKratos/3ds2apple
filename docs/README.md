# Documentation

Product documentation for the three parts of 3ds2apple (Windows launcher, macOS
launcher, iOS app) plus the cross-cutting contracts they rely on. The repository
landing page is [../README.md](../README.md); per-component build recipes live in
each component's README.

| Document | Covers |
|---|---|
| [windows-launcher.md](windows-launcher.md) | Windows launcher: ROM import, local LLVM/LLD GamePack build, IPA composition, Impactor signing, devpush deploy, error handling and the device test plan. |
| [macos-launcher.md](macos-launcher.md) | macOS launcher: portable data root, Xcode toolchain, the one-click Deploy chain (compile → compose → sign → install → push), self-check and screenshots. |
| [device-bridge.md](device-bridge.md) | `devpush` contract v1 (devices, install, AFC container push, NDJSON, exit codes, stall watchdog), signing/install boundaries and the `Documents/Games/` data layout. |
| [performance.md](performance.md) | Performance telemetry (`zk_perf`), the measurement plan, MoltenVK tuning, the readback audit and the GPL reference boundary. |
| [release.md](release.md) | Public release policy: GitHub Releases asset set, checksum/verification rules, version and tag rules, and what is never published. |

## Component and build docs

- [../builder/README.md](../builder/README.md) — `3ds2apple-pack` CLI, package layout,
  `GameInfo.json` / `GameCatalog.json` schemas and the GamePack ABI hand-off.
- [../scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md) — per-game AOT build scripts,
  options, diagnostics and the catalog step.
- [../ios/app/README.md](../ios/app/README.md) — iOS shell runtime, UI, input,
  save states and debug launch arguments.
- [../launcher/windows/README.md](../launcher/windows/README.md) and
  [../launcher/macos/README.md](../launcher/macos/README.md) — launcher developer
  guides.
- [../tools/winbuild/README.md](../tools/winbuild/README.md) — Apple-SDK-free
  LLVM/LLD toolchain recipe.
- [../tools/devpush/README.md](../tools/devpush/README.md) — device bridge quickstart.

## Legal and licensing

- [../LICENSE](../LICENSE) — project license (Apache-2.0).
- [../NOTICE](../NOTICE) — project notice, Nintendo disclaimer, bundled tools.
- [../THIRD_PARTY.md](../THIRD_PARTY.md) — third-party components and licenses.
- [../licenses/impactor/README-bundled-tools.txt](../licenses/impactor/README-bundled-tools.txt)
  — bundled Impactor/plumesign provenance, SHA-256 pins and license texts.
