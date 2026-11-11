# Contributing

Thanks for helping. This project is at the planning / Phase 0 stage, so the
most useful contributions right now are:

- reproducing the desktop [Zakuro](https://github.com/fearkov/zakuro) +
  [3dsrecomp](https://github.com/fearkov/3dsrecomp) results on Windows/Linux;
- testing the iOS build path on a cloud Mac;
- reporting game compatibility with title, region, version, and what breaks;
- improving the docs in `docs/`.

## Ground rules

1. **No ROMs, keys, system files, or game assets.** Do not attach them to
   issues or PRs. Use only your own legally obtained, decrypted dumps.
2. **No piracy links or instructions.** Compatibility reports should describe
   the game and the bug, not where to obtain it.
3. **Keep the pipeline AOT.** The iOS build must not rely on a CPU JIT. The
   ~0.2% interpreter fallback in Zakuro is expected; adding a JIT is out of
   scope for the first release.
4. **Licenses.** This repository's own code is Apache-2.0. Zakuro and
   3dsrecomp are MIT; keep their notices. Do not paste GPL code (Azahar,
   TriAevum) into this repository.
5. **Generated code is game-derived.** Keep the C code from 3dsrecomp, the
   compiled dylibs, IPAs, and extracted assets out of git. Build outputs
   belong in `out/`, `build/`, or `Payload/`, which are ignored.

## Pull requests

- Keep changes focused; one topic per PR.
- For build changes, include the command you ran and the platform
  (Windows / Linux / macOS version).
- For compatibility fixes, include the game title ID, region, version, and a
  short log excerpt if possible.
- By contributing, you agree that your contribution is licensed under
  Apache-2.0.

## Reporting a build or game issue

Please include:

- host OS and version;
- Zakuro / 3dsrecomp commit or release;
- game title, title ID, region, version (base / update / DLC);
- whether the game was recompiled;
- the last 50 lines of the log;
- whether the same game works in desktop Zakuro.

Do not upload the ROM or generated C code.