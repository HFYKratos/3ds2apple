"""Subprocess client for tools/devpush (NDJSON contract devpush/1).

The Rust bridge is the only layer that talks to usbmuxd/AFC. This module builds
exact arguments, streams events to the launcher, and translates stable devpush
error codes into the wrapper error catalog.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

from errors import DeviceError, map_devpush_error

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "devpush/1"


def find_devpush(explicit: str | os.PathLike | None = None) -> Path:
    """Resolve the bridge binary: explicit > DEVPUSH_EXE > repo target > PATH."""
    candidates: list[Path | str | None] = [explicit, os.environ.get("DEVPUSH_EXE")]
    for profile in ("release", "debug"):
        candidates.extend(REPO_ROOT / "tools" / "devpush" / "target" / profile / name for name in ("devpush.exe", "devpush"))
    candidates.append(shutil.which("devpush"))
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate)
        if path.is_file():
            return path
    raise DeviceError("devpush_missing", "devpush binary not found (build tools/devpush or bundle it with the launcher)")


def run(exe: str | os.PathLike, args: list[str], on_event=None) -> dict:
    """Run one devpush command, stream devpush/1 events, return the done payload."""
    exe = Path(exe)
    command = args[0] if args else "unknown"
    process = subprocess.Popen(
        [str(exe), *args, "--json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    done: dict | None = None
    error: dict | None = None
    try:
        assert process.stdout is not None
        for line in process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict) or event.get("schema") != SCHEMA:
                continue
            if on_event is not None:
                on_event(event)
            if event.get("type") == "error":
                error = event.get("error") or {}
            elif event.get("type") == "done":
                done = event
        if process.stdout is not None:
            process.stdout.close()
        stderr = process.stderr.read() if process.stderr is not None else ""
        if process.stderr is not None:
            process.stderr.close()
        return_code = process.wait()
    except BaseException:
        process.kill()
        process.wait()
        raise
    if error is not None or return_code != 0:
        code = map_devpush_error(str((error or {}).get("code") or "io_error"))
        message = (error or {}).get("message") or stderr.strip() or f"devpush {command} exited with {return_code}"
        detail = None
        if (error or {}).get("afcCode") is not None:
            detail = f"afcCode={error.get('afcCode')}"
        raise DeviceError(code, message, hint=(error or {}).get("hint"), detail=detail)
    if done is None:
        raise DeviceError("internal_error", f"devpush {command} produced no done event", detail=stderr[-500:])
    return done


def capabilities(exe: str | os.PathLike) -> dict:
    return run(exe, ["capabilities"])


def devices(exe: str | os.PathLike) -> list[dict]:
    return run(exe, ["devices"]).get("devices") or []


def _container_args(container: str) -> list[str]:
    return ["--container", container]


def put(exe, bundle_id: str, local, remote: str, container: str = "app", udid: str | None = None, on_event=None) -> dict:
    args = ["put", "--bundle-id", bundle_id, "--local", str(local), "--remote", remote, *_container_args(container)]
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args, on_event=on_event)


def get(exe, bundle_id: str, remote: str, local, container: str = "app", udid: str | None = None, on_event=None) -> dict:
    args = ["get", "--bundle-id", bundle_id, "--remote", remote, "--local", str(local), *_container_args(container)]
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args, on_event=on_event)


def ls(exe, bundle_id: str, path: str, container: str = "app", udid: str | None = None) -> list[dict]:
    args = ["ls", "--bundle-id", bundle_id, "--path", path, *_container_args(container)]
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args).get("entries") or []


def stat(exe, bundle_id: str, path: str, container: str = "app", udid: str | None = None) -> dict:
    args = ["stat", "--bundle-id", bundle_id, "--path", path, *_container_args(container)]
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args)


def app_attr(exe, bundle_id: str, key: str | None = None, udid: str | None = None) -> dict:
    args = ["app-attr", "--bundle-id", bundle_id]
    if key:
        args.extend(["--key", key])
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args)


def mkdir(exe, bundle_id: str, path: str, container: str = "app", udid: str | None = None) -> dict:
    args = ["mkdir", "--bundle-id", bundle_id, "--path", path, *_container_args(container)]
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args)


def tar_ok(exe, bundle_id: str, path: str, container: str = "app", udid: str | None = None) -> bool:
    args = ["tar-ok", "--bundle-id", bundle_id, "--path", path, *_container_args(container)]
    if udid:
        args.extend(["--udid", udid])
    return bool(run(exe, args).get("ok"))


def install(exe, ipa, bundle_id: str | None = None, udid: str | None = None, on_event=None) -> dict:
    args = ["install", "--ipa", str(ipa)]
    if bundle_id:
        args.extend(["--bundle-id", bundle_id])
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args, on_event=on_event)


def uninstall(exe, bundle_id: str, udid: str | None = None) -> dict:
    args = ["uninstall", "--bundle-id", bundle_id]
    if udid:
        args.extend(["--udid", udid])
    return run(exe, args)


def progress_event(event: dict) -> dict | None:
    """Normalize a devpush progress event for wrapper output."""
    if event.get("type") != "progress":
        return None
    total = event.get("bytesTotal")
    sent = event.get("bytesSent") or 0
    percent = event.get("percent")
    if percent is None and total:
        percent = round(100.0 * sent / total, 1)
    return {"file": event.get("file"), "bytesSent": sent, "bytesTotal": total, "percent": percent}
