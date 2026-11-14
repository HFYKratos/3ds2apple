#!/usr/bin/env python3
"""Fetch or verify the bundled official Impactor v2.7.2 + plumesign files.

Download-or-bundled mode for the launchers: files are downloaded from the
official GitHub release, SHA-256 verified against impactor.py pins, and shipped
unmodified next to the licenses. Nothing here modifies or re-signs Impactor.

  python3 scripts/impactor/fetch_impactor.py --dest <launcher>/ThirdParty/Impactor
  python3 scripts/impactor/fetch_impactor.py --status [--resources <launcher dir>]
  python3 scripts/impactor/fetch_impactor.py --dest <dir> --platform windows-x86_64
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "builder" / "device"))

import impactor  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch/verify official Impactor v2.7.2 + plumesign (SHA-256 pinned)")
    parser.add_argument("--dest", help="directory to download the pinned release files and licenses into")
    parser.add_argument("--platform", choices=sorted(impactor.ASSETS), help="release asset family (default: current host)")
    parser.add_argument("--resources", help="launcher resources directory to verify (contains ThirdParty/Impactor)")
    parser.add_argument("--status", action="store_true", help="print readiness/verification JSON without downloading")
    args = parser.parse_args(argv)
    try:
        if args.status:
            print(json.dumps(impactor.status(args.resources, args.platform), indent=2, ensure_ascii=False))
            return 0
        if not args.dest:
            parser.error("--dest is required unless --status is used")
        manifest = impactor.fetch(args.dest, platform=args.platform)
        print(json.dumps(manifest, indent=2, ensure_ascii=False))
        return 0
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3


if __name__ == "__main__":
    sys.exit(main())
