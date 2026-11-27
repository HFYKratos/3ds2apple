plumesign-linux-x86_64 — official third-party signing CLI used by the 3ds2apple Linux launcher
=================================================================================================

What this file is
-----------------
launcher/linux/vendor/plumesign-linux-x86_64 is the official Linux x86-64 build of
plumesign from the Impactor v2.7.3 release:

  https://github.com/claration/impactor/releases/tag/v2.7.3

It is NOT part of the 3ds2apple source tree and is never committed (see
vendor/.gitignore). Download it unmodified from that release, place it here and
keep it executable. The SHA-256 and size are pinned in PINS.json; the launcher
and packaging scripts refuse a mismatched file.

Licenses
--------
Impactor (and therefore plumesign) is MIT-licensed: see
LICENSE-Impactor-MIT.txt (Copyright 2025 Samara M).

The embedded apple-codesign 0.29.0 library is MPL-2.0: see
LICENSE-apple-codesign-MPL-2.0.txt, source at
https://github.com/claration/impactor/tree/v2.7.3/3rdparty/apple-codesign-0.29.0
The launcher only starts the unmodified official binary; it does not modify or
statically link either project.

Apple ID and privacy
--------------------
The Apple ID, password, two-factor code and signing session stay inside the
official plumesign/Impactor tool. Its account store is outside this repository
(~/.config/PlumeImpactor on Linux). The launcher must never ask for, read or log
those secrets. No Apple certificate or provisioning profile is bundled here.

Game data
---------
This directory contains no game data, no ROM, no keys and no IPA. Users import
their own legally owned decrypted games.
