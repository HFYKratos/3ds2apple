# Contributing

Thanks for helping 3ds2apple. The project is an early-stage native iOS port of
Nintendo 3DS games; the most useful contributions are:

- build and run instructions for macOS / Xcode versions;
- compatibility reports: game, title ID, region, version, what works and what
  breaks;
- fixes to the SwiftUI shell, the Zakuro C ABI or the build scripts;
- performance work on the software renderer or a Metal/Vulkan backend;
- documentation that makes the build path easier to reproduce.

## Ground rules

1. **No ROMs, keys, system files or game assets.** Do not attach them to issues,
   pull requests or logs. Only use your own legally obtained, decrypted games.
2. **No piracy links or instructions.** Compatibility reports should describe
   the game and the bug, not where to obtain it.
3. **Keep the pipeline AOT.** The iOS build must not depend on a CPU JIT.
   Zakuro's small interpreter fallback is expected; adding a JIT is out of
   scope.
4. **Licenses.** This repository is Apache-2.0. Zakuro and 3dsrecomp are MIT;
   keep their notices. Do not paste GPL code (Azahar, Citra, TriAevum) into this
   repository.
5. **Generated code is game-derived.** Never commit the C produced by
   3dsrecomp, compiled archives, IPAs or extracted game assets. Build outputs
   belong in `build/`, `IPA/` or `third_party/`, which are ignored.
6. **One topic per pull request.** Include the command you ran, the host
   configuration and a short log excerpt where relevant.

## Reporting a build or game issue

Please include:

- host OS and Xcode version;
- Zakuro / 3dsrecomp commit or release;
- game title, title ID, region and version (base / update / DLC);
- whether the game was recompiled and whether the app shows
  `AOT: linked, active` or `linked, interpreting`;
- the last 50 lines of the build or device log.

Do not upload the ROM, generated C code or a signed IPA.

## Pull requests

By contributing, you agree that your contribution is licensed under
Apache-2.0. Keep changes focused and update the relevant public documentation
in `README.md`, `docs/` or `ios/*/README.md`.
