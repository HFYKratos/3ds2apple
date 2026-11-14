Impactor v2.7.2 + plumesign — third-party signing tool bundled with the 3ds2apple launcher for Windows
=============================================================================================

What these files are
--------------------
There are two executable files in this directory when the launcher is bundled:

  Impactor-windows-x86_64-portable.exe   the official graphical Impactor (the user signs in
                                         with their own Apple ID here)
  plumesign-windows-x86_64.exe           the official command-line signer from the same release

They are the unmodified official files from the GitHub release:

  https://github.com/claration/impactor/releases/tag/v2.7.2

Neither file is rebuilt, patched, renamed, re-signed or distributed by 3ds2apple as our own
work. The SHA-256 values are pinned in PINS.json and in the launcher (Signing/ImpactorPins.cs).
Every launch verifies them and refuses a mismatch. Do not replace them with another version:
they are tested as a pair (Impactor GUI + plumesign CLI share the %APPDATA%\PlumeImpactor
account store).

Licenses
--------
Impactor is MIT-licensed: see LICENSE-Impactor-MIT.txt (Copyright 2025 Samara M).

Impactor embeds the apple-codesign 0.29.0 library, which is MPL-2.0: see
LICENSE-apple-codesign-MPL-2.0.txt. Its source is available here:

  https://github.com/claration/impactor/tree/v2.7.2/3rdparty/apple-codesign-0.29.0

The launcher does not modify or statically link either project; it only starts the official
binaries. Under MPL-2.0 the source-offer obligation for the embedded library is satisfied by the
upstream source link above (we redistribute the same unmodified binary release).

Apple ID and privacy
--------------------
The Apple ID, password, two-factor code and signing session stay inside Impactor/plumesign.
The launcher never asks for, reads or logs them. Signing talks only to Apple's own services.
No Apple certificate or provisioning profile is bundled with 3ds2apple.

Game data
---------
This directory contains no game data, no ROM and no decrypted keys. Users import their own
legally owned decrypted games; see the project licence and README.
