3ds2apple bundled signing tools - official Impactor v2.7.3 (unmodified)

What this directory is for
  The Windows launcher bundles the *official* Impactor v2.7.3 release files
  unmodified so the user can sign the base shell IPA with their own Apple ID
  without a second download. The macOS launcher signs through Xcode/devicectl
  and bundles no Impactor or plumesign files. Nothing here is modified, patched
  or re-signed; Apple ID login and passwords stay inside Impactor (or Xcode),
  never in 3ds2apple.

Official release files and their pins (NOT committed to git; see .gitignore;
  the Windows launcher bundles only the Windows x64 pair, the other rows are pin
  references for the fetch tool / future ports)
  Windows x64: Impactor-windows-x86_64-portable.exe  and plumesign-windows-x86_64.exe
  Windows arm64: Impactor-windows-arm64-portable.exe and plumesign-windows-arm64.exe
  Windows x86: Impactor-windows-x86-portable.exe     and plumesign-windows-x86.exe
  macOS universal: Impactor-macos-universal.dmg      and plumesign-macos-universal
  Linux x86_64: Impactor-linux-x86_64.appimage       and plumesign-linux-x86_64
  Linux aarch64: Impactor-linux-aarch64.appimage     and plumesign-linux-aarch64
  Fetch them with: launcher/windows/tools/fetch-impactor.sh --fetch (or
  launcher/windows/tools/fetch-impactor.ps1 on Windows).

Pinned SHA-256 (official GitHub release asset digests via the REST API, verified 2026-11-19)
  Impactor-windows-x86_64-portable.exe  ebf939f8c8e74b4cd693d2f9871db4b8304f12396181fdd17404a127427b9923
  plumesign-windows-x86_64.exe         94664749fbbceb9a16bf89583f473dafb9b35c8d058a9d8665dc963b3453c6fc
  Impactor-windows-arm64-portable.exe  ef4a1fdceece04b35a14b099c336bc24fb81489a3297fca38727b34a754fc4a7
  plumesign-windows-arm64.exe          cb137127c3c4f1f5b43340bdf3976b5f5d581017152d7c218953e0575f2ec0c0
  Impactor-windows-x86-portable.exe    185d8461ce1f8c61952eef4799d83b6edf3f6606ddbc77a5f834dd9ab5b88d1e
  plumesign-windows-x86.exe            e0ed0fd796650d824d3fe21924982a2ba79c0307922f07b71d75cb8abfec70a4
  Impactor-macos-universal.dmg         d87b4051ef12fe3c79a5c21fc117502b7d99d6fef785f9934cd689c60d971557
  plumesign-macos-universal            24bdc78f334f7db324d0d3ae35b1fc67d69f3f8f4a354d10b9967bc3fc261a08
  Impactor-linux-x86_64.appimage       9c420954a5edb6cbd14ed389adf8665e1f84561e66c3eb0fe9eb6b8fcb6ad90f
  plumesign-linux-x86_64               d7d631d04fd80bf134fef9a7c71f704e9ae92f3d8f7e4895f10de4236acdc177
  Impactor-linux-aarch64.appimage      3a48ff597b657f0de5a900920f7c025f949e7dbb58d515efc47c4cf31a8a269b
  plumesign-linux-aarch64              62e62ea95f336d145a960a6616256cf34c7e80f8fcb91751a05dff53e2485d88

Licenses (kept in this repo, copied next to the bundled binaries)
  LICENSE-Impactor-MIT.txt            Impactor v2.7.3, MIT, Copyright 2025 Samara M
  LICENSE-apple-codesign-MPL-2.0.txt  embedded apple-codesign 0.29.0, MPL-2.0

Source links
  Impactor:        https://github.com/claration/impactor/tree/v2.7.3
  apple-codesign:  https://github.com/claration/impactor/tree/v2.7.3/3rdparty/apple-codesign-0.29.0
  Release page:    https://github.com/claration/impactor/releases/tag/v2.7.3

Rules (see THIRD_PARTY.md and NOTICE)
  - Do not modify, patch, rename into a fork, or re-sign these official binaries.
  - Keep the SHA-256 pins; the launchers refuse a bundled copy whose hash differs.
  - Do not commit the downloaded binaries; only the licenses and this notice are tracked.
  - Apple ID credentials never pass through 3ds2apple; login happens in Impactor/Xcode.
