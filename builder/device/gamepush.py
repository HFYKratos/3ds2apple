"""Game data push/verify for Documents/Games/<TITLEID>/.

Executable game code stays inside the signed shell IPA: the launcher/build step
embeds the per-game GamePack.dylib and the catalog, so IPA signing covers nested
dylibs. The device bridge only pushes user data into the app container:

    Documents/Games/<TITLEID>/GameRom.cci     the user's decrypted ROM
    Documents/Games/<TITLEID>/GameInfo.json   schemaVersion 1 metadata

GameRom.cci is pushed first and GameInfo.json LAST, so an interrupted push is
never visible to the shell (directories without a valid GameInfo.json are
ignored). After the push the sizes are verified with stat and the pushed
GameInfo.json is downloaded and hashed.

GameInfo.pack ({file,size,sha256}) describes the pack that is embedded in the
signed IPA; it is metadata only and is never pushed. Pass pack= (CLI: --pack)
to fill it from the local build artifact.
"""
from __future__ import annotations

import hashlib
import json
import re
import tempfile
import time
from pathlib import Path

from errors import DeviceError
import devpush as bridge

TITLE_ID_RE = re.compile(r"^[0-9A-F]{16}$")
# Files pushed into the app container (user data only).
GAME_FILES = {
    "rom": "GameRom.cci",
    "info": "GameInfo.json",
}
# Executable code that must live inside the signed IPA; never pushed.
PACK_FILE = "GamePack.dylib"


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def game_dir(title_id: str) -> str:
    title = (title_id or "").strip().upper()
    if not TITLE_ID_RE.match(title):
        raise DeviceError("usage", f"titleID must be 16 upper-case hex characters, got {title_id!r}")
    return f"Documents/Games/{title}"


def load_game_info(source: str | Path | dict) -> dict:
    if isinstance(source, dict):
        info = dict(source)
    else:
        path = Path(source)
        if not path.is_file():
            raise DeviceError("usage", f"GameInfo.json not found: {path}")
        try:
            info = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise DeviceError("usage", f"GameInfo.json is not valid JSON: {error}") from error
    if not isinstance(info, dict):
        raise DeviceError("usage", "GameInfo.json must be a JSON object")
    if info.get("schemaVersion") != 1:
        raise DeviceError("usage", f"GameInfo.json schemaVersion must be 1 (got {info.get('schemaVersion')!r})")
    return info


def prepare_game_info(
    source: str | Path | dict,
    title_id: str,
    rom: str | Path,
    launcher_version: str | None = None,
    game_name: str | None = None,
    pack: str | Path | None = None,
) -> dict:
    """Validate GameInfo.json, fill ROM metadata and optional IPA pack metadata.

    pack is the local GamePack.dylib that the build step embeds into the signed
    IPA; it is only hashed/sized for GameInfo.pack and is never pushed.
    """
    info = load_game_info(source)
    title = game_dir(title_id).rsplit("/", 1)[-1]
    if str(info.get("titleID") or "").upper() != title:
        raise DeviceError("usage", f"GameInfo.json titleID {info.get('titleID')!r} does not match --title-id {title}")
    rom = Path(rom)
    if not rom.is_file():
        raise DeviceError("usage", f"{GAME_FILES['rom']} not found: {rom}")
    if rom.name != GAME_FILES["rom"]:
        raise DeviceError("usage", f"ROM must be named {GAME_FILES['rom']} (got {rom.name})")
    if pack is not None:
        pack = Path(pack)
        if not pack.is_file():
            raise DeviceError("usage", f"{PACK_FILE} not found: {pack} (it must be embedded in the signed IPA build)")
        if pack.name != PACK_FILE:
            raise DeviceError("usage", f"pack must be named {PACK_FILE} (got {pack.name})")
    info["titleID"] = title
    info["aot"] = bool(info.get("aot", True))
    info["packABIVersion"] = info.get("packABIVersion") or 1
    if pack is not None:
        info["pack"] = {"file": PACK_FILE, "size": pack.stat().st_size, "sha256": sha256_file(pack)}
    info["rom"] = {"file": GAME_FILES["rom"], "size": rom.stat().st_size, "sha256": sha256_file(rom)}
    if game_name:
        info["displayName"] = game_name
    if launcher_version:
        info["launcherVersion"] = launcher_version
    info["pushedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return info


def push_plan(title_id: str, rom: str | Path, info_path: str | Path) -> list[tuple[str, Path]]:
    """Pushed files in safe order: ROM first, GameInfo.json last (visibility marker)."""
    base = game_dir(title_id)
    return [
        (f"{base}/{GAME_FILES['rom']}", Path(rom)),
        (f"{base}/{GAME_FILES['info']}", Path(info_path)),
    ]


def resolve_installed_bundle_id(exe, candidates: list[str], udid: str | None = None) -> str | None:
    """Find which candidate bundle id the signature tool actually installed."""
    for candidate in candidates:
        try:
            bridge.app_attr(exe, candidate, udid=udid)
            return candidate
        except DeviceError as error:
            if error.code not in ("app_missing",):
                raise
    return None


def push_game(
    exe,
    bundle_id: str,
    title_id: str,
    game_info,
    rom,
    pack=None,
    udid: str | None = None,
    launcher_version: str | None = None,
    game_name: str | None = None,
    container: str = "app",
    emit=None,
) -> dict:
    """Push ROM + GameInfo.json (never executable code) and verify them afterwards."""
    base = game_dir(title_id)
    info = prepare_game_info(game_info, title_id, rom, launcher_version=launcher_version, game_name=game_name, pack=pack)
    report_files = []
    with tempfile.TemporaryDirectory(prefix="3ds2apple-gameinfo-") as temp:
        info_path = Path(temp) / GAME_FILES["info"]
        info_path.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
        plan = push_plan(title_id, rom, info_path)
        total_files = len(plan)
        for index, (remote, local) in enumerate(plan, start=1):
            name = remote.rsplit("/", 1)[-1]
            if emit:
                emit({"schema": "device-install/1", "type": "step", "command": "push-game", "name": "push",
                      "status": "running", "detail": f"{index}/{total_files} {name}", "file": remote})
            def on_event(event, _name=name, _index=index):
                if emit and event.get("type") == "progress":
                    progress = bridge.progress_event(event) or {}
                    emit({"schema": "device-install/1", "type": "progress", "command": "push-game",
                          "phase": "push", "file": _name, "bytesSent": progress.get("bytesSent"),
                          "bytesTotal": progress.get("bytesTotal"), "percent": progress.get("percent"),
                          "fileIndex": _index, "fileCount": total_files})
            result = bridge.put(exe, bundle_id, local, remote, container=container, udid=udid, on_event=on_event)
            report_files.append({"remote": remote, "bytes": result.get("bytes"), "sha256": result.get("sha256"), "verified": False})
        # verify inside the temp dir: the pushed GameInfo.json bytes can be hashed exactly
        verification = verify_game(
            exe, bundle_id, title_id, udid=udid, local_info=info_path, expected_info=info,
            container=container, exact_info_bytes=True,
        )
    for item in report_files:
        remote = item["remote"]
        match = next((entry for entry in verification["files"] if entry["remote"] == remote), None)
        item["verified"] = bool(match and match["ok"])
    if not verification["ok"]:
        raise DeviceError("verify_failed", f"pushed game files did not verify: {verification['mismatches']}", detail=json.dumps(verification))
    return {
        "titleID": title_id.upper(),
        "bundleId": bundle_id,
        "udid": udid,
        "baseDir": base,
        "files": report_files,
        "pack": info.get("pack"),
        "packLocation": "ipa",
        "verified": True,
    }


def verify_game(
    exe,
    bundle_id: str,
    title_id: str,
    udid: str | None = None,
    local_info: str | Path | None = None,
    expected_info: dict | None = None,
    container: str = "app",
    exact_info_bytes: bool = False,
) -> dict:
    """Verify the pushed ROM side (GameRom.cci size + GameInfo.json content/sha256).

    local_info is normally the source GameInfo.json (enriched on device), so it
    is compared semantically (titleID + rom size/sha256). push_game passes
    exact_info_bytes=True because it holds the exact bytes it uploaded.
    The embedded GamePack.dylib is part of the signed IPA; it cannot be listed
    through the app data container and is covered by IPA signing instead.
    """
    base = game_dir(title_id)
    expected = expected_info or (load_game_info(local_info) if local_info else None)
    files = []
    mismatches = []
    for label in ("rom", "info"):
        name = GAME_FILES[label]
        remote = f"{base}/{name}"
        try:
            stat = bridge.stat(exe, bundle_id, remote, container=container, udid=udid)
        except DeviceError as error:
            files.append({"remote": remote, "ok": False, "missing": True, "error": error.payload()})
            mismatches.append(f"{name}: missing ({error.message})")
            continue
        entry = {"remote": remote, "bytes": stat.get("size"), "isDir": stat.get("isDir"), "ok": True}
        if label == "rom" and expected:
            wanted = (expected.get("rom") or {}).get("size")
            if wanted is not None and stat.get("size") != wanted:
                entry["ok"] = False
                mismatches.append(f"{name}: size {stat.get('size')} != {wanted}")
        files.append(entry)
    # Download GameInfo.json: verify it is the metadata we expect.
    try:
        with tempfile.TemporaryDirectory(prefix="3ds2apple-verify-") as temp:
            local = Path(temp) / GAME_FILES["info"]
            bridge.get(exe, bundle_id, f"{base}/{GAME_FILES['info']}", local, container=container, udid=udid)
            remote_sha = sha256_file(local)
            entry = next(item for item in files if item["remote"].endswith(GAME_FILES["info"]))
            entry["sha256"] = remote_sha
            device_pack = None
            try:
                remote_info = json.loads(local.read_text(encoding="utf-8"))
            except (OSError, ValueError) as error:
                entry["ok"] = False
                mismatches.append(f"GameInfo.json on device is not valid JSON: {error}")
                remote_info = None
            if isinstance(remote_info, dict):
                if isinstance(remote_info.get("pack"), dict):
                    device_pack = remote_info.get("pack")
                if str(remote_info.get("titleID") or "").upper() != title_id.upper():
                    entry["ok"] = False
                    mismatches.append(f"GameInfo.json titleID {remote_info.get('titleID')!r} != {title_id.upper()}")
                expected_rom = (expected or {}).get("rom") or {}
                remote_rom = remote_info.get("rom") or {}
                if expected_rom.get("sha256") and remote_rom.get("sha256") != expected_rom.get("sha256"):
                    entry["ok"] = False
                    mismatches.append("GameInfo.json rom.sha256 does not match the local ROM")
                if expected_rom.get("size") is not None and remote_rom.get("size") != expected_rom.get("size"):
                    entry["ok"] = False
                    mismatches.append("GameInfo.json rom.size does not match the local ROM")
            if exact_info_bytes and local_info:
                wanted_sha = sha256_file(local_info)
                if wanted_sha != remote_sha:
                    entry["ok"] = False
                    mismatches.append(f"GameInfo.json sha256 {remote_sha} != {wanted_sha}")
    except (DeviceError, StopIteration):
        pass
    return {
        "titleID": title_id.upper(),
        "baseDir": base,
        "files": files,
        "pack": device_pack if device_pack is not None else (expected or {}).get("pack"),
        "packLocation": "ipa",
        "mismatches": mismatches,
        "ok": not mismatches,
    }
