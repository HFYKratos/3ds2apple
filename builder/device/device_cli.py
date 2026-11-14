#!/usr/bin/env python3
"""3ds2apple device wrapper: readiness, official Impactor signing/install, game push.

Stable launcher contract (docs/device-bridge.md): with --json every event is one
NDJSON object on stdout, schema "device-install/1", type begin|step|progress|done|error,
and the process exit code is stable per error code (see errors.py).

This wrapper never implements Apple ID authentication and never sees passwords or
session tokens: signing is performed by the official Impactor v2.7.2 plumesign CLI
(unmodified, SHA-256 pinned) or by Xcode/xcrun devicectl on macOS. The Apple ID
login happens once inside Impactor (or Xcode Accounts).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import devpush as bridge  # noqa: E402
import gamepush  # noqa: E402
import impactor  # noqa: E402
import ipa as ipa_tools  # noqa: E402
from errors import ERRORS, DeviceError, classify_tool_output  # noqa: E402

SCHEMA = "device-install/1"
PERCENT_RE = re.compile(r"(\d{1,3})\s*%")


class Emitter:
    """NDJSON (schema device-install/1) or human progress output."""

    def __init__(self, json_mode: bool, command: str):
        self.json = json_mode
        self.command = command

    def _emit(self, event: dict) -> None:
        if self.json:
            print(json.dumps(event, ensure_ascii=False), flush=True)

    def begin(self, **fields) -> None:
        self._emit({"schema": SCHEMA, "type": "begin", "command": self.command, **fields})
        if not self.json:
            print(f"== {self.command}")

    def step(self, name: str, status: str = "running", detail: str | None = None, **extra) -> None:
        event = {"schema": SCHEMA, "type": "step", "command": self.command, "name": name, "status": status}
        if detail:
            event["detail"] = detail
        event.update(extra)
        self._emit(event)
        if not self.json:
            prefix = {"running": "..", "ok": "ok", "failed": "FAIL", "warn": "warn"}.get(status, status)
            print(f"[{prefix}] {name}" + (f": {detail}" if detail else ""))

    def progress(self, phase: str, percent=None, **extra) -> None:
        event = {"schema": SCHEMA, "type": "progress", "command": self.command, "phase": phase, "percent": percent}
        event.update(extra)
        self._emit(event)
        if not self.json and percent is not None:
            print(f"   {phase}: {percent:.0f}%", flush=True)

    def done(self, payload: dict, human: str = "") -> None:
        self._emit({"schema": SCHEMA, "type": "done", "command": self.command, "ok": True, **payload})
        if not self.json:
            print(human or "done")

    def error(self, error: DeviceError) -> None:
        self._emit({"schema": SCHEMA, "type": "error", "command": self.command, "ok": False, "error": error.payload(), "exitCode": error.exit_code})
        print(f"{self.command}: {error.code}: {error.message}", file=sys.stderr)
        if error.hint:
            print(f"  hint: {error.hint}", file=sys.stderr)


def run_streaming(command: list[str], on_line=None) -> tuple[int, str]:
    """Run a tool, stream combined output lines, return (returncode, all_output)."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1)
    lines: list[str] = []
    try:
        assert process.stdout is not None
        for line in process.stdout:
            line = line.rstrip("\n")
            lines.append(line)
            if on_line:
                on_line(line)
        return process.wait(), "\n".join(lines)
    except BaseException:
        process.kill()
        process.wait()
        raise


def pick_udid(devices: list[dict], wanted: str | None) -> str:
    if wanted:
        for device in devices:
            if str(device.get("udid", "")).lower() == wanted.lower():
                return device["udid"]
        raise DeviceError("device_not_connected", f"device {wanted} is not connected")
    if not devices:
        raise DeviceError("device_not_connected", "no iPhone/iPad is connected")
    if len(devices) > 1:
        ids = ", ".join(str(device.get("udid")) for device in devices)
        raise DeviceError("device_ambiguous", f"{len(devices)} devices connected ({ids}); pass --udid")
    return devices[0]["udid"]


def devpush_or_none(explicit: str | os.PathLike | None):
    try:
        return bridge.find_devpush(explicit)
    except DeviceError:
        return None


def select_account(plumesign: Path) -> dict:
    """Ensure Impactor has one selected Apple ID; auto-select when unambiguous."""
    account = impactor.account_status()
    if not account["logged_in"]:
        raise DeviceError("apple_login_required", "no Apple ID is signed in to Impactor")
    if account["selected"] is None:
        if len(account["accounts"]) != 1:
            raise DeviceError(
                "apple_login_required",
                "Impactor has several saved Apple IDs and none is selected",
                hint="Open Impactor > Settings, select the Apple ID to use, then retry.",
            )
        email = account["accounts"][0]
        code, output = run_streaming([str(plumesign), "account", "switch", email])
        account = impactor.account_status()
        if code != 0 or account["selected"] is None:
            raise DeviceError("apple_login_required", f"could not select the only saved Apple ID ({email})", detail=output[-400:])
    return account


def verify_bundled_tools(resources: str | None) -> dict:
    """Fail closed when a launcher-bundled official binary was tampered with."""
    directory = impactor.bundled_dir(resources)
    if directory is None:
        return {"ok": True, "dir": None}
    result = impactor.verify_bundle(resources)
    if not result["ok"] and result["mismatched"]:
        raise DeviceError(
            "impactor_hash_mismatch",
            "bundled Impactor/plumesign SHA-256 does not match the pinned official release",
            detail=json.dumps(result["files"]),
        )
    return result


def find_plumesign(resources: str | None) -> Path | None:
    return impactor.find_tool("plumesign", resources)


def find_devicectl() -> Path | None:
    if sys.platform != "darwin":
        return None
    return shutil.which("xcrun")


def signing_readiness(resources: str | None) -> dict:
    """Return (method, tool path, checks) for the current platform."""
    plumesign = find_plumesign(resources)
    devicectl = find_devicectl()
    checks: list[dict] = []
    if plumesign is not None:
        version = impactor.tool_version(plumesign)
        ok = version == impactor.TESTED
        checks.append({"id": "plumesign", "ok": ok, "code": None if ok else "impactor_version_untested", "detail": f"{plumesign} ({version or 'unknown version'})"})
        return {"method": "plumesign", "tool": str(plumesign), "checks": checks, "devicectl": devicectl}
    checks.append({"id": "plumesign", "ok": False, "code": "impactor_missing", "detail": "official plumesign (Impactor v2.7.2) not found"})
    if devicectl:
        checks.append({"id": "devicectl", "ok": True, "code": None, "detail": devicectl})
        return {"method": "devicectl", "tool": devicectl, "checks": checks, "devicectl": devicectl}
    return {"method": None, "tool": None, "checks": checks, "devicectl": None}


def cmd_status(args) -> int:
    emitter = Emitter(args.json, "status")
    emitter.begin(platform=impactor.platform_key())
    checks: list[dict] = []
    paths: dict = {}
    devices: list[dict] = []
    exe = devpush_or_none(args.devpush)
    if exe is not None:
        paths["devpush"] = str(exe)
        try:
            capabilities = bridge.capabilities(exe)
            checks.append({"id": "devpush", "ok": True, "code": None, "detail": f"{exe} ({capabilities.get('version')}, backend {capabilities.get('backend')})"})
        except DeviceError as error:
            checks.append({"id": "devpush", "ok": False, "code": error.code, "detail": error.message})
    else:
        checks.append({"id": "devpush", "ok": False, "code": "devpush_missing", "detail": "devpush binary not found"})

    signing = signing_readiness(args.resources)
    checks.extend(signing["checks"])
    paths["plumesign"] = signing["tool"] if signing["method"] == "plumesign" else None
    paths["devicectl"] = signing.get("devicectl")
    impactor_status = impactor.status(args.resources)
    paths["impactor"] = impactor_status["impactor"]["path"]
    account = impactor_status["appleId"]
    if signing["method"] == "plumesign":
        accounts_ok = bool(account["logged_in"])
        detail = f"selected {account['selected']}" if account["selected"] else (f"{len(account['accounts'])} saved account(s), none selected" if account["logged_in"] else "no Apple ID signed in to Impactor")
        checks.append({"id": "apple-id", "ok": accounts_ok, "code": None if accounts_ok else "apple_login_required", "detail": detail})
    else:
        xcode = shutil.which("xcodebuild")
        checks.append({"id": "xcode", "ok": bool(xcode), "code": None if xcode else "xcode_missing", "detail": xcode or "xcodebuild not found"})

    if exe is not None:
        try:
            devices = bridge.devices(exe)
            if args.udid:
                try:
                    chosen = pick_udid(devices, args.udid)
                    checks.append({"id": "device", "ok": True, "code": None, "detail": chosen})
                except DeviceError as error:
                    checks.append({"id": "device", "ok": False, "code": error.code, "detail": error.message})
            elif devices:
                checks.append({"id": "device", "ok": True, "code": None, "detail": str(devices[0].get("udid"))})
            else:
                checks.append({"id": "device", "ok": False, "code": "device_not_connected", "detail": "no device connected"})
        except DeviceError as error:
            checks.append({"id": "device", "ok": False, "code": error.code, "detail": error.message})

    failed = [check for check in checks if not check["ok"]]
    ready = not failed
    primary = None
    if failed:
        first = failed[0]
        primary = {"code": first.get("code") or "internal_error", "message": first.get("detail") or first["id"], "hint": ERRORS.get(first.get("code") or "", ("", ""))[1] if first.get("code") else None}
    payload = {
        "platform": impactor.platform_key(),
        "ready": ready,
        "checks": checks,
        "paths": paths,
        "impactor": {
            "tested": impactor.TESTED,
            "release": impactor.RELEASE_PAGE,
            "bundleOk": impactor_status["bundle"]["ok"],
            "bundleDir": impactor_status["bundleDir"],
            "sourceLinks": impactor.SOURCE_LINKS,
        },
        "appleId": {"loggedIn": account["logged_in"], "selected": account["selected"], "accounts": account["accounts"], "teamId": account["team_id"]},
        "devices": devices,
        "error": primary,
    }
    emitter.done(payload, human=f"ready={ready} platform={impactor.platform_key()} " + (" ".join(f"{c['id']}={'ok' if c['ok'] else 'FAIL'}" for c in checks)))
    return 0


def cmd_devices(args) -> int:
    emitter = Emitter(args.json, "devices")
    emitter.begin()
    exe = bridge.find_devpush(args.devpush)
    devices = bridge.devices(exe)
    emitter.done({"devices": devices, "count": len(devices)}, human=f"{len(devices)} device(s)")
    return 0


def _sign_plumesign(emitter: Emitter, args, info: dict, bundle_id: str, udid: str, plumesign: Path, account: dict) -> dict:
    emitter.step("sign", "running", f"plumesign v{impactor.TESTED} signing {Path(args.ipa).name}")
    command = [str(plumesign), "sign", "--package", str(args.ipa), "--apple-id", "--udid", udid, "--register-and-install"]
    custom = args.custom_identifier
    if custom:
        command.extend(["--custom-identifier", custom])
    last_percent = {"value": 0.0}

    def on_line(line: str) -> None:
        match = PERCENT_RE.search(line)
        if match:
            value = float(match.group(1))
            if value >= last_percent["value"]:
                last_percent["value"] = value
                emitter.progress("sign", value)
        elif line.strip():
            emitter.step("sign", "running", line.strip()[:240])

    code, output = run_streaming(command, on_line)
    installed_id = custom or bundle_id
    if code != 0:
        error_code = classify_tool_output(output)
        if error_code == "app_id_taken" and args.auto_identifier and account.get("team_id") and not custom:
            retry_custom = f"{bundle_id}.{account['team_id']}"
            emitter.step("sign", "warn", f"bundle identifier taken; retrying with {retry_custom}")
            command = [str(plumesign), "sign", "--package", str(args.ipa), "--apple-id", "--udid", udid, "--register-and-install", "--custom-identifier", retry_custom]
            code, output = run_streaming(command, on_line)
            if code == 0:
                installed_id = retry_custom
            else:
                error_code = classify_tool_output(output)
        if code != 0:
            raise DeviceError(error_code, f"plumesign failed: {output.strip().splitlines()[-1] if output.strip() else 'unknown error'}", detail=output[-800:])
    emitter.step("sign", "ok", f"signed and installed as {installed_id}")
    return {"bundleId": installed_id, "method": "plumesign", "tool": str(plumesign)}


def _sign_devicectl(emitter: Emitter, args, info: dict, udid: str, xcrun: Path) -> dict:
    if not info["signed"]:
        raise DeviceError(
            "ipa_invalid",
            "this IPA is unsigned; xcrun devicectl can only install an app that Xcode already signed",
            hint="Sign the shell with Xcode (ios/app project, your team) or bundle official Impactor+plumesign; then retry with the signed .ipa.",
        )
    emitter.step("install", "running", "xcrun devicectl device install app")
    with ipa_tools.temporary_app_dir() as temp:
        app = ipa_tools.extract_app(args.ipa, temp)
        command = [str(xcrun), "devicectl", "device", "install", "app", "--device", udid, str(app)]
        code, output = run_streaming(command, lambda line: emitter.step("install", "running", line.strip()[:240]) if line.strip() else None)
        if code != 0:
            raise DeviceError("install_failed", "devicectl could not install the signed app", detail=output[-800:])
    emitter.step("install", "ok", "installed with devicectl")
    return {"bundleId": info["bundleId"], "method": "devicectl", "tool": str(xcrun)}


def cmd_sign_install(args) -> int:
    emitter = Emitter(args.json, "sign-install")
    emitter.begin(ipa=str(args.ipa), method=args.method)
    info = ipa_tools.inspect_ipa(args.ipa)
    bundle_id = args.bundle_id or info["bundleId"]
    if args.bundle_id and args.bundle_id != info["bundleId"]:
        raise DeviceError("usage", f"--bundle-id {args.bundle_id} does not match the IPA ({info['bundleId']})")
    emitter.step("validate", "ok", f"{info['bundleId']} {info.get('version')} ({'signed' if info['signed'] else 'unsigned'}, {info['size']} bytes)")

    exe = devpush_or_none(args.devpush)
    udid = args.udid
    if not udid:
        if exe is None:
            raise DeviceError("usage", "pass --udid (devpush is unavailable, so the wrapper cannot detect connected devices)")
        udid = pick_udid(bridge.devices(exe), None)
    emitter.step("device", "ok", udid)
    paths: dict = {"devpush": str(exe) if exe else None}

    if args.method in ("auto", "plumesign", "devicectl"):
        readiness = signing_readiness(args.resources)
        if args.method == "plumesign" and readiness["method"] != "plumesign":
            raise DeviceError("tool_missing", "official plumesign (Impactor v2.7.2) is not available", hint=ERRORS["impactor_missing"][1])
        if args.method == "devicectl" and not find_devicectl():
            raise DeviceError("xcode_missing", "xcrun devicectl is not available")
        method = readiness["method"] if args.method == "auto" else args.method
    else:
        method = args.method
    if method is None:
        raise DeviceError("tool_missing", "no signing/install method is available on this machine", hint=ERRORS["impactor_missing"][1])

    verify_bundled_tools(args.resources)
    result: dict = {}
    if method == "plumesign":
        plumesign = find_plumesign(args.resources)
        if plumesign is None:
            raise DeviceError("impactor_missing", "official plumesign not found")
        impactor_status = impactor.status(args.resources)
        account = select_account(plumesign)
        emitter.step("apple-id", "ok", f"selected {account['selected']}" + (f" (team {account['team_id']})" if account["team_id"] else ""))
        result = _sign_plumesign(emitter, args, info, bundle_id, udid, plumesign, account)
        paths["plumesign"] = str(plumesign)
    elif method == "devicectl":
        xcrun = find_devicectl()
        if xcrun is None:
            raise DeviceError("xcode_missing", "xcrun not found; install Xcode")
        result = _sign_devicectl(emitter, args, info, udid, xcrun)
        paths["devicectl"] = str(xcrun)
    else:
        raise DeviceError("unsupported", f"unknown method {method}")

    installed_bundle = result.get("bundleId") or bundle_id
    if exe is not None:
        candidates = [installed_bundle]
        if args.auto_identifier and args.resources:
            pass
        try:
            resolved = gamepush.resolve_installed_bundle_id(exe, candidates, udid=udid)
            if resolved:
                installed_bundle = resolved
                emitter.step("verify", "ok", f"app {resolved} is installed")
            else:
                emitter.step("verify", "warn", "could not confirm the installed bundle id yet; it may still be indexing")
        except DeviceError as error:
            emitter.step("verify", "warn", f"install verification skipped: {error.message}")
    emitter.done(
        {"installed": True, "bundleId": installed_bundle, "ipa": str(args.ipa), "method": method, "paths": paths},
        human=f"installed {installed_bundle} via {method}",
    )
    return 0


def cmd_push_game(args) -> int:
    emitter = Emitter(args.json, "push-game")
    emitter.begin(titleID=args.title_id, bundleId=args.bundle_id, udid=args.udid)
    exe = bridge.find_devpush(args.devpush)
    udid = args.udid or pick_udid(bridge.devices(exe), None)
    emitter.step("device", "ok", udid)
    if args.pack:
        emitter.step(
            "pack",
            "ok",
            "GamePack.dylib stays inside the signed IPA and is NOT pushed; --pack only fills GameInfo.pack metadata",
        )
    report = gamepush.push_game(
        exe,
        args.bundle_id,
        args.title_id,
        args.game_info,
        args.rom,
        pack=args.pack,
        udid=udid,
        launcher_version=args.launcher_version,
        game_name=args.game_name,
        container=args.container,
        emit=emitter._emit,
    )
    emitter.done(report, human=f"pushed {args.title_id.upper()} ROM+GameInfo ({len(report['files'])} files) -> {report['baseDir']}")
    return 0


def cmd_verify_game(args) -> int:
    emitter = Emitter(args.json, "verify-game")
    emitter.begin(titleID=args.title_id, bundleId=args.bundle_id)
    exe = bridge.find_devpush(args.devpush)
    udid = args.udid or pick_udid(bridge.devices(exe), None)
    report = gamepush.verify_game(exe, args.bundle_id, args.title_id, udid=udid, local_info=args.game_info, container=args.container)
    if not report["ok"]:
        raise DeviceError("verify_failed", "game files are missing or mismatched", detail=json.dumps(report["mismatches"]))
    emitter.done(report, human=f"verified {args.title_id.upper()}: {len(report['files'])} files")
    return 0


def cmd_fetch_tools(args) -> int:
    emitter = Emitter(args.json, "fetch-tools")
    emitter.begin(dest=str(args.dest), platform=args.platform or impactor.platform_key())
    emitter.step("fetch", "running", f"official Impactor v{impactor.TESTED} + plumesign (SHA-256 pinned)")

    try:
        manifest = impactor.fetch(args.dest, platform=args.platform)
    except ValueError as error:
        raise DeviceError("impactor_hash_mismatch", str(error)) from error
    if args.platform is None or args.platform == impactor.platform_key():
        for role in ("plumesign",):
            path = impactor.find_tool(role, args.dest)
            if path is not None and sys.platform != "win32":
                try:
                    os.chmod(path, 0o755)
                except OSError:
                    pass
    emitter.step("fetch", "ok", f"{len(manifest['files'])} files verified")
    emitter.done(manifest, human=f"fetched {len(manifest['files'])} official file(s) into {args.dest}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="emit NDJSON events (schema device-install/1)")
    parser = argparse.ArgumentParser(description="3ds2apple device wrapper (Impactor signing/install + game push)")
    parser.add_argument("--json", action="store_true", dest="json_root", help="emit NDJSON events")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status", parents=[common], help="readiness report (JSON)")
    status.add_argument("--devpush", help="devpush binary path")
    status.add_argument("--resources", help="launcher resources dir (bundled ThirdParty/Impactor)")
    status.add_argument("--udid")
    status.set_defaults(func=cmd_status)

    devices = subparsers.add_parser("devices", parents=[common], help="list connected devices")
    devices.add_argument("--devpush")
    devices.set_defaults(func=cmd_devices)

    sign_install = subparsers.add_parser("sign-install", parents=[common], help="sign the base shell IPA and install it")
    sign_install.add_argument("--ipa", required=True)
    sign_install.add_argument("--bundle-id")
    sign_install.add_argument("--udid")
    sign_install.add_argument("--method", choices=["auto", "plumesign", "devicectl"], default="auto")
    sign_install.add_argument("--resources")
    sign_install.add_argument("--devpush")
    sign_install.add_argument("--custom-identifier", help="override the signed bundle identifier")
    sign_install.add_argument("--auto-identifier", action="store_true", help="retry with <bundle>.<teamId> when the app id is taken")
    sign_install.set_defaults(func=cmd_sign_install)

    push_game = subparsers.add_parser("push-game", parents=[common], help="push GameRom.cci + GameInfo.json (the game pack stays in the signed IPA)")
    push_game.add_argument("--udid")
    push_game.add_argument("--bundle-id", required=True)
    push_game.add_argument("--title-id", required=True)
    push_game.add_argument("--game-info", required=True)
    push_game.add_argument("--pack", help="local GamePack.dylib embedded in the signed IPA (metadata only for GameInfo.pack; never pushed)")
    push_game.add_argument("--rom", required=True)
    push_game.add_argument("--launcher-version")
    push_game.add_argument("--game-name")
    push_game.add_argument("--container", default="app", choices=["app", "documents"])
    push_game.add_argument("--devpush")
    push_game.set_defaults(func=cmd_push_game)

    verify_game = subparsers.add_parser("verify-game", parents=[common], help="verify pushed GameRom.cci + GameInfo.json (pack is in the IPA)")
    verify_game.add_argument("--udid")
    verify_game.add_argument("--bundle-id", required=True)
    verify_game.add_argument("--title-id", required=True)
    verify_game.add_argument("--game-info")
    verify_game.add_argument("--container", default="app", choices=["app", "documents"])
    verify_game.add_argument("--devpush")
    verify_game.set_defaults(func=cmd_verify_game)

    fetch_tools = subparsers.add_parser("fetch-tools", parents=[common], help="download pinned official Impactor/plumesign + licenses")
    fetch_tools.add_argument("--dest", required=True)
    fetch_tools.add_argument("--platform", choices=sorted(impactor.ASSETS))
    fetch_tools.set_defaults(func=cmd_fetch_tools)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.json = bool(args.json or getattr(args, "json_root", False))
    emitter = Emitter(args.json, args.command)
    try:
        return args.func(args)
    except DeviceError as error:
        emitter.error(error)
        return error.exit_code
    except KeyboardInterrupt:
        return 130
    except Exception as error:  # noqa: BLE001 - keep launcher output stable
        wrapped = DeviceError("internal_error", f"{type(error).__name__}: {error}")
        emitter.error(wrapped)
        return wrapped.exit_code


if __name__ == "__main__":
    sys.exit(main())
