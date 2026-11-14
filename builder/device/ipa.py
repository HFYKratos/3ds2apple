"""IPA validation and bundle metadata for the device wrapper (stdlib only)."""
from __future__ import annotations

import plistlib
import tempfile
import zipfile
from pathlib import Path

from errors import DeviceError


def _info_plist_member(names: list[str]) -> str | None:
    candidates = [name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist")]
    if len(candidates) != 1:
        return None
    return candidates[0]


def read_info_plist(path: str | Path) -> dict:
    """Read Payload/<App>.app/Info.plist from an IPA without unpacking everything."""
    path = Path(path)
    if not path.is_file():
        raise DeviceError("ipa_invalid", f"IPA not found: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            member = _info_plist_member(names)
            if member is None:
                raise DeviceError("ipa_invalid", f"{path.name} is not an IPA: exactly one Payload/<App>.app/Info.plist expected")
            return plistlib.loads(archive.read(member))
    except zipfile.BadZipFile as error:
        raise DeviceError("ipa_invalid", f"{path.name} is not a valid zip/IPA: {error}") from error
    except (OSError, plistlib.InvalidFileException) as error:
        raise DeviceError("ipa_invalid", f"cannot read {path.name}: {error}") from error


def inspect_ipa(path: str | Path) -> dict:
    """Metadata used by status/sign-install/install-verification."""
    path = Path(path)
    info = read_info_plist(path)
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        signed = any("/_CodeSignature/CodeResources" in name for name in names)
        embedded_profile = any(name.startswith("Payload/") and name.endswith(".app/embedded.mobileprovision") for name in names)
    bundle_id = info.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise DeviceError("ipa_invalid", f"{path.name} has no CFBundleIdentifier")
    return {
        "path": str(path),
        "size": path.stat().st_size,
        "bundleId": bundle_id,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "displayName": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
        "executable": info.get("CFBundleExecutable"),
        "signed": signed,
        "embeddedProfile": embedded_profile,
    }


def extract_app(path: str | Path, dest: str | Path) -> Path:
    """Extract Payload/<App>.app to dest (for xcrun devicectl install app)."""
    path = Path(path)
    dest = Path(dest)
    try:
        with zipfile.ZipFile(path) as archive:
            member = _info_plist_member(archive.namelist())
            if member is None:
                raise DeviceError("ipa_invalid", f"{path.name} is not an IPA: no .app bundle")
            prefix = member[: -len("Info.plist")]  # Payload/<App>.app/
            payload = prefix.split("/", 1)[0] + "/"  # Payload/
            for name in archive.namelist():
                if not name.startswith(prefix) or name.endswith("/"):
                    continue
                target = dest / name[len(payload):]
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, open(target, "wb") as sink:
                    sink.write(source.read())
            app_name = prefix.rstrip("/").split("/")[-1]
            return dest / app_name
    except zipfile.BadZipFile as error:
        raise DeviceError("ipa_invalid", f"{path.name} is not a valid zip/IPA: {error}") from error


def temporary_app_dir() -> tempfile.TemporaryDirectory:
    return tempfile.TemporaryDirectory(prefix="3ds2apple-device-")
