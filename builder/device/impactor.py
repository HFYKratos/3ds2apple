"""Official Impactor v2.7.2 + plumesign: pinned upstream binaries and readiness.

We never modify, re-sign or repackage Impactor/plumesign. The launcher bundles the
official release files unmodified, SHA-256 pinned below, together with their
licenses (MIT for Impactor, MPL-2.0 for the embedded apple-codesign) and source
links. Apple ID login happens inside Impactor (or Xcode on macOS); this module
only reads the account selector (selected email + team id) so the wrapper can
report readiness - never tokens, never passwords.

Source: https://github.com/claration/impactor/releases/tag/v2.7.2
"""
from __future__ import annotations

import hashlib
import json
import os
import platform as _platform
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

TESTED = "2.7.2"
RELEASE_PAGE = f"https://github.com/claration/impactor/releases/tag/v{TESTED}"
DOWNLOAD = f"https://github.com/claration/impactor/releases/download/v{TESTED}/"
REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLE_SUBDIR = Path("ThirdParty") / "Impactor"
REPO_CACHE = REPO_ROOT / "third_party" / "impactor" / f"v{TESTED}"

# SHA-256 values are the official GitHub release digests (GitHub API
# release-assets digest, verified 2026-11-14). Keep them in sync with
# docs/device-bridge.md and scripts/impactor/licenses/README-bundled-tools.txt.
ASSETS: dict[str, dict[str, tuple[str, str]]] = {
    "windows-x86_64": {
        "impactor": ("Impactor-windows-x86_64-portable.exe", "f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef"),
        "plumesign": ("plumesign-windows-x86_64.exe", "b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0"),
    },
    "windows-arm64": {
        "impactor": ("Impactor-windows-arm64-portable.exe", "351ff17e1eab2a5615ab5c155a499f1eeb3c7347c0404cbf6918a4462b756b80"),
        "plumesign": ("plumesign-windows-arm64.exe", "260c22455aee139b8fe7f93638a7d340d3e821b0f1a7dd9c7486d924cb8fc86c"),
    },
    "windows-x86": {
        "impactor": ("Impactor-windows-x86-portable.exe", "4cc30efbde19911862f38ac6a60ac50ecc9674ac4fbb16eee0b5feb71f1e3488"),
        "plumesign": ("plumesign-windows-x86.exe", "5585005107deb285244d2c4362eca0edc8498b8764a790d9130e3dfb6810247c"),
    },
    "macos-universal": {
        "impactor": ("Impactor-macos-universal.dmg", "fa1a2ba0fb7e46dbe1b0ea5e66f12d04cc570693afd14fe3b43979e5a3cfe3be"),
        "plumesign": ("plumesign-macos-universal", "f07f8d25813e6a8c1e0e5ae8cec53e795b496c7f1fb6262eb725fde36eb3dafa"),
    },
    "linux-x86_64": {
        "impactor": ("Impactor-linux-x86_64.appimage", "28e737e736ddcea4189c5d470c813df09cef902f109cfeb8c71b409ab52561ce"),
        "plumesign": ("plumesign-linux-x86_64", "daaa6f296247a501c899de6167ebcf1b03ab2a4c8d3ca3ec6ec4c27613701aa2"),
    },
    "linux-aarch64": {
        "impactor": ("Impactor-linux-aarch64.appimage", "fc715f7937c70abdb3b29a13b92e7e07a44a4e1a6bdda3f1c92a967b4a10c050"),
        "plumesign": ("plumesign-linux-aarch64", "fded8b2e2f4898945072331338a04df97e345088abc6dbb5fab5c028c0b586a3"),
    },
}

LICENSES = {
    "impactor_mit": "LICENSE-Impactor-MIT.txt",
    "apple_codesign_mpl": "LICENSE-apple-codesign-MPL-2.0.txt",
    "readme": "README-bundled-tools.txt",
}

SOURCE_LINKS = {
    "impactor": f"https://github.com/claration/impactor/tree/v{TESTED}",
    "apple_codesign": f"https://github.com/claration/impactor/tree/v{TESTED}/3rdparty/apple-codesign-0.29.0",
    "release": RELEASE_PAGE,
}


def platform_key() -> str:
    """Release asset family for the current host (launchers may pass an override)."""
    if sys.platform == "win32":
        machine = _platform.machine().lower()
        if machine in ("arm64", "aarch64"):
            return "windows-arm64"
        if machine in ("x86", "i386", "i686"):
            return "windows-x86"
        return "windows-x86_64"
    if sys.platform == "darwin":
        return "macos-universal"
    machine = _platform.machine().lower()
    return "linux-aarch64" if machine in ("aarch64", "arm64") else "linux-x86_64"


def expected_assets(platform: str | None = None) -> dict[str, tuple[str, str]]:
    return dict(ASSETS.get(platform or platform_key(), {}))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def licenses_dir() -> Path:
    return REPO_ROOT / "scripts" / "impactor" / "licenses"


def bundled_dir(resources: str | os.PathLike | None = None) -> Path | None:
    """Candidate bundled-tools directory (launcher resources or repo cache)."""
    override = os.environ.get("DEVPUSH_IMPACTOR_DIR")
    candidates = []
    if override:
        candidates.append(Path(override))
    if resources:
        candidates.append(Path(resources) / BUNDLE_SUBDIR)
        candidates.append(Path(resources))
    candidates.append(REPO_CACHE)
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return None


def _exe_names(role: str, platform: str | None = None) -> list[str]:
    entry = expected_assets(platform).get(role)
    names = []
    if entry:
        names.append(entry[0])
    if role == "plumesign":
        names.extend(["plumesign.exe", "plumesign"])
    else:
        names.extend(["Impactor.exe", "Impactor-windows-x86_64-portable.exe", "Impactor.app"])
    return names


def find_tool(role: str, resources: str | os.PathLike | None = None, platform: str | None = None) -> Path | None:
    """Locate plumesign / Impactor GUI, preferring the launcher-bundled copy."""
    override = os.environ.get("PLUMESIGN_EXE" if role == "plumesign" else "IMPACTOR_GUI")
    if override and Path(override).is_file():
        return Path(override)
    directory = bundled_dir(resources)
    if directory:
        for name in _exe_names(role, platform):
            candidate = directory / name
            if candidate.is_file():
                return candidate
    if role == "plumesign":
        found = shutil.which("plumesign")
        if found:
            return Path(found)
    return None


def tool_version(path: Path) -> str | None:
    """Return the plumesign version string, or None when it cannot be executed."""
    try:
        result = subprocess.run([str(path), "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    text = (result.stdout or result.stderr or "").strip()
    for token in text.replace("plumesign", " ").split():
        token = token.strip().lstrip("v")
        if token[:1].isdigit():
            return token
    return None


def verify_bundle(resources: str | os.PathLike | None = None, platform: str | None = None) -> dict:
    """Check hashes of the bundled official binaries for the requested platform."""
    directory = bundled_dir(resources)
    expected = expected_assets(platform)
    result: dict = {"dir": str(directory) if directory else None, "files": {}, "ok": False, "missing": [], "mismatched": []}
    if not directory:
        result["missing"] = [name for name, _ in expected.values()]
        return result
    for role, (name, digest) in expected.items():
        path = directory / name
        if not path.is_file():
            result["missing"].append(name)
            continue
        actual = sha256_file(path)
        ok = actual == digest
        result["files"][name] = {"sha256": actual, "expected": digest, "ok": ok}
        if not ok:
            result["mismatched"].append(name)
    result["ok"] = not result["missing"] and not result["mismatched"]
    return result


def account_store_path() -> Path | None:
    """Impactor/plumesign account store (we only read the selector, never tokens)."""
    override = os.environ.get("PLUME_ACCOUNT_STORE")
    if override:
        return Path(override)
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA") or (Path.home() / "AppData" / "Roaming"))
        return base / "PlumeImpactor" / "accounts.json"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "PlumeImpactor" / "accounts.json"
    return Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "PlumeImpactor" / "accounts.json"


def account_status() -> dict:
    """Whether Impactor has at least one saved Apple ID and which one is selected."""
    path = account_store_path()
    status = {"store": str(path) if path else None, "logged_in": False, "selected": None, "accounts": [], "team_id": None}
    if not path or not path.is_file():
        return status
    try:
        store = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return status
    if not isinstance(store, dict):
        return status
    accounts = store.get("accounts") or {}
    if not isinstance(accounts, dict):
        return status
    selected = store.get("selected_account") or None
    status["accounts"] = sorted(accounts)
    status["logged_in"] = bool(accounts)
    status["selected"] = selected if selected in accounts else None
    entry = accounts.get(selected) if selected else None
    if isinstance(entry, dict):
        team = entry.get("team_id")
        if isinstance(team, str) and len(team) == 10 and team.isalnum():
            status["team_id"] = team
    return status


def status(resources: str | os.PathLike | None = None, platform: str | None = None) -> dict:
    key = platform or platform_key()
    directory = bundled_dir(resources)
    verify = verify_bundle(resources, key)
    plumesign = find_tool("plumesign", resources, key)
    plumesign_version = tool_version(plumesign) if plumesign else None
    impactor_gui = find_tool("impactor", resources, key)
    if sys.platform == "darwin":
        app = Path("/Applications/Impactor.app")
        if app.is_dir():
            impactor_gui = app
    account = account_status()
    return {
        "tested": TESTED,
        "release": RELEASE_PAGE,
        "download": DOWNLOAD,
        "platform": key,
        "bundleDir": verify["dir"],
        "bundle": verify,
        "impactor": {"path": str(impactor_gui) if impactor_gui else None, "bundled": bool(directory)},
        "plumesign": {"path": str(plumesign) if plumesign else None, "version": plumesign_version, "pinned": plumesign_version == TESTED},
        "appleId": account,
        "licensesDir": str(licenses_dir()),
        "sourceLinks": SOURCE_LINKS,
    }


def fetch(dest: str | os.PathLike, platform: str | None = None, fetcher=None, licenses: bool = True) -> dict:
    """Download-or-bundled mode: fetch pinned official files + licenses, verify hashes."""
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    expected = expected_assets(platform)
    if fetcher is None:
        def fetcher(url: str, target: Path) -> None:  # noqa: E306 - local default
            request = urllib.request.Request(url, headers={"User-Agent": "3ds2apple-device-wrapper/1"})
            with urllib.request.urlopen(request, timeout=120) as response, open(target, "wb") as handle:
                shutil.copyfileobj(response, handle)

    results = []
    for role, (name, digest) in expected.items():
        target = dest / name
        if not target.is_file() or sha256_file(target) != digest:
            temp = target.with_suffix(target.suffix + ".part")
            if temp.exists():
                temp.unlink()
            fetcher(DOWNLOAD + name, temp)
            actual = sha256_file(temp)
            if actual != digest:
                temp.unlink(missing_ok=True)
                raise ValueError(f"SHA-256 mismatch for {name}: {actual} != {digest} ({RELEASE_PAGE})")
            temp.replace(target)
        if role == "plumesign" and sys.platform != "win32":
            try:
                os.chmod(target, 0o755)
            except OSError:
                pass
        results.append({"role": role, "name": name, "sha256": digest, "path": str(target), "bytes": target.stat().st_size})

    license_files = []
    if licenses:
        source_dir = licenses_dir()
        for key, name in LICENSES.items():
            source = source_dir / name
            if source.is_file():
                target = dest / name
                shutil.copyfile(source, target)
                license_files.append({"name": name, "path": str(target)})
    manifest = {
        "tested": TESTED,
        "release": RELEASE_PAGE,
        "platform": platform or platform_key(),
        "fetchedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": results,
        "licenses": license_files,
        "sourceLinks": SOURCE_LINKS,
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    readme = [
        f"Official Impactor v{TESTED} + plumesign (unmodified upstream release files, SHA-256 pinned).",
        "The 3ds2apple launcher bundles these files for the user's own Apple ID signing; we do not modify, patch or re-sign them.",
        f"Release: {RELEASE_PAGE}",
        f"Source: {SOURCE_LINKS['impactor']}",
        f"Embedded apple-codesign 0.29.0 (MPL-2.0): {SOURCE_LINKS['apple_codesign']}",
        "Apple ID passwords are typed only into Impactor/Xcode and never pass through 3ds2apple.",
        "Files in this directory are NOT committed to git; licenses are kept in scripts/impactor/licenses/.",
        "",
    ]
    readme.extend(f"{item['name']}  {item['bytes']} bytes  SHA-256 {item['sha256']}" for item in results)
    (dest / LICENSES["readme"]).write_text("\n".join(readme), encoding="utf-8")
    return manifest


def cli_status(resources: str | os.PathLike | None = None, platform: str | None = None) -> dict:
    return status(resources, platform)
