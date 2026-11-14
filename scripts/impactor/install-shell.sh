#!/usr/bin/env bash
# Sign and install the 3ds2apple base shell IPA on a connected iPhone/iPad.
#
# Windows: uses the official Impactor v2.7.2 plumesign.exe bundled by the launcher.
# macOS:   uses the official plumesign binary (bundled or installed), or
#          xcrun devicectl for an already-signed IPA; Xcode handles provisioning.
#
# The wrapper never implements Apple ID login: sign in once in Impactor (or Xcode
# Accounts) and the password never leaves that tool. See docs/device-bridge.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/builder/device/device_cli.py" sign-install "$@"
