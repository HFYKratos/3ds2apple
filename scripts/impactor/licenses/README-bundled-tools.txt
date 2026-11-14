3ds2apple bundled signing tools - official Impactor v2.7.2 (unmodified)

What this directory is for
  The Windows and macOS launchers bundle the *official* Impactor v2.7.2 release
  files unmodified so the user can sign the base shell IPA with their own Apple
  ID without a second download. Nothing here is modified, patched or re-signed;
  Apple ID login and passwords stay inside Impactor (or Xcode), never in 3ds2apple.

Files bundled at launcher packaging time (NOT committed to git; see .gitignore)
  Windows x64: Impactor-windows-x86_64-portable.exe  and plumesign-windows-x86_64.exe
  Windows arm64: Impactor-windows-arm64-portable.exe and plumesign-windows-arm64.exe
  macOS universal: Impactor-macos-universal.dmg      and plumesign-macos-universal
  Fetch them with: python3 scripts/impactor/fetch_impactor.py --dest <dir>

Pinned SHA-256 (official GitHub release digests, verified 2026-11-14)
  Impactor-windows-x86_64-portable.exe  f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef
  plumesign-windows-x86_64.exe         b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0
  Impactor-windows-arm64-portable.exe  351ff17e1eab2a5615ab5c155a499f1eeb3c7347c0404cbf6918a4462b756b80
  plumesign-windows-arm64.exe          260c22455aee139b8fe7f93638a7d340d3e821b0f1a7dd9c7486d924cb8fc86c
  Impactor-windows-x86-portable.exe    4cc30efbde19911862f38ac6a60ac50ecc9674ac4fbb16eee0b5feb71f1e3488
  plumesign-windows-x86.exe            5585005107deb285244d2c4362eca0edc8498b8764a790d9130e3dfb6810247c
  Impactor-macos-universal.dmg         fa1a2ba0fb7e46dbe1b0ea5e66f12d04cc570693afd14fe3b43979e5a3cfe3be
  plumesign-macos-universal            f07f8d25813e6a8c1e0e5ae8cec53e795b496c7f1fb6262eb725fde36eb3dafa
  Impactor-linux-x86_64.appimage       28e737e736ddcea4189c5d470c813df09cef902f109cfeb8c71b409ab52561ce
  plumesign-linux-x86_64               daaa6f296247a501c899de6167ebcf1b03ab2a4c8d3ca3ec6ec4c27613701aa2
  Impactor-linux-aarch64.appimage      fc715f7937c70abdb3b29a13b92e7e07a44a4e1a6bdda3f1c92a967b4a10c050
  plumesign-linux-aarch64              fded8b2e2f4898945072331338a04df97e345088abc6dbb5fab5c028c0b586a3

Licenses (kept in this repo, copied next to the bundled binaries)
  LICENSE-Impactor-MIT.txt            Impactor v2.7.2, MIT, Copyright 2025 Samara M
  LICENSE-apple-codesign-MPL-2.0.txt  embedded apple-codesign 0.29.0, MPL-2.0

Source links
  Impactor:        https://github.com/claration/impactor/tree/v2.7.2
  apple-codesign:  https://github.com/claration/impactor/tree/v2.7.2/3rdparty/apple-codesign-0.29.0
  Release page:    https://github.com/claration/impactor/releases/tag/v2.7.2

Rules (see THIRD_PARTY.md and NOTICE)
  - Do not modify, patch, rename into a fork, or re-sign these official binaries.
  - Keep the SHA-256 pins; the wrapper refuses a bundled copy whose hash differs.
  - Do not commit the downloaded binaries; only the licenses and this notice are tracked.
  - Apple ID credentials never pass through 3ds2apple; login happens in Impactor/Xcode.
