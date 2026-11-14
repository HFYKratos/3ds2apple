"""Unit tests for the device wrapper (host-side; no device required).

Run: python3 builder/device/tests/test_device.py -v
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import devpush  # noqa: E402
import errors  # noqa: E402
import gamepush  # noqa: E402
import impactor  # noqa: E402
import ipa as ipa_tools  # noqa: E402
from errors import DeviceError  # noqa: E402


def make_ipa(path: Path, bundle_id: str = "com.kratos.3ds2apple") -> Path:
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "9",
        "CFBundleDisplayName": "3ds2apple",
        "CFBundleExecutable": "3ds2apple",
    }
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/3ds2apple.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/3ds2apple.app/3ds2apple", b"binary")
        archive.writestr("Payload/3ds2apple.app/_CodeSignature/CodeResources", b"sig")
    return path


class IpaTests(unittest.TestCase):
    def test_inspect_ipa(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = make_ipa(Path(temp) / "shell.ipa")
            info = ipa_tools.inspect_ipa(path)
            self.assertEqual(info["bundleId"], "com.kratos.3ds2apple")
            self.assertEqual(info["version"], "0.2.0")
            self.assertTrue(info["signed"])
            self.assertGreater(info["size"], 0)

    def test_invalid_ipa_is_structured_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            bad = Path(temp) / "bad.ipa"
            bad.write_bytes(b"not a zip")
            with self.assertRaises(DeviceError) as caught:
                ipa_tools.inspect_ipa(bad)
            self.assertEqual(caught.exception.code, "ipa_invalid")
            with self.assertRaises(DeviceError):
                ipa_tools.inspect_ipa(Path(temp) / "missing.ipa")

    def test_extract_app(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = make_ipa(Path(temp) / "shell.ipa")
            out = Path(temp) / "out"
            app = ipa_tools.extract_app(path, out)
            self.assertEqual(app.name, "3ds2apple.app")
            self.assertTrue((app / "Info.plist").is_file())
            self.assertTrue((app / "3ds2apple").is_file())


class ErrorTests(unittest.TestCase):
    def test_every_code_has_exit_code_and_hint(self) -> None:
        for code, (exit_code, hint) in errors.ERRORS.items():
            self.assertIsInstance(exit_code, int, code)
            self.assertTrue(hint, code)
            error = DeviceError(code, "message")
            self.assertEqual(error.exit_code, exit_code)
            payload = error.payload()
            self.assertEqual(payload["code"], code)
            self.assertIn("hint", payload)

    def test_classify_tool_output(self) -> None:
        cases = {
            "No account selected. Please login first": "apple_session_expired",
            "Your session has expired. Please log in.": "apple_session_expired",
            "maximum number of installed apps": "free_app_limit",
            "maximum number of app ids": "free_appid_limit",
            "The app ID with identifier com.x is not available": "app_id_taken",
            "Anisette error: dns error while resolving host": "signing_server_unreachable",
            "developer mode is not enabled": "developer_mode_required",
            "device is locked": "device_locked",
            "InvalidHostID": "pairing_required",
            "unknown error occured while reading the file": "ipa_needs_repack",
            "totally unrelated failure": "sign_failed",
        }
        for text, expected in cases.items():
            self.assertEqual(errors.classify_tool_output(text), expected, text)

    def test_map_devpush_codes(self) -> None:
        self.assertEqual(errors.map_devpush_error("device_not_found"), "device_not_connected")
        self.assertEqual(errors.map_devpush_error("stall_timeout"), "stall_timeout")
        self.assertEqual(errors.map_devpush_error("app_missing"), "app_missing")
        self.assertEqual(errors.map_devpush_error("never_heard_of_it"), "internal_error")


class ImpactorTests(unittest.TestCase):
    def test_sha256_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "x"
            path.write_bytes(b"hello world")
            self.assertEqual(impactor.sha256_file(path), "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")

    def test_verify_bundle_mismatch_and_match(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "fake-portable.exe").write_bytes(b"tampered")
            fake_assets = {"test-platform": {"plumesign": ("fake-portable.exe", "0" * 64)}}
            with mock.patch.dict(impactor.ASSETS, fake_assets, clear=True):
                result = impactor.verify_bundle(directory, "test-platform")
                self.assertFalse(result["ok"])
                self.assertEqual(result["mismatched"], ["fake-portable.exe"])
            good_assets = {"test-platform": {"plumesign": ("fake-portable.exe", impactor.sha256_file(directory / "fake-portable.exe"))}}
            with mock.patch.dict(impactor.ASSETS, good_assets, clear=True):
                self.assertTrue(impactor.verify_bundle(directory, "test-platform")["ok"])

    def test_account_status_reads_selector_only(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            store = Path(temp) / "accounts.json"
            store.write_text(json.dumps({
                "selected_account": "user@example.com",
                "accounts": {
                    "user@example.com": {"team_id": "ABCDE12345", "session": "SECRET-TOKEN"},
                    "other@example.com": {"team_id": "ZZZZZ99999"},
                },
            }), encoding="utf-8")
            with mock.patch.dict(os.environ, {"PLUME_ACCOUNT_STORE": str(store)}):
                status = impactor.account_status()
            self.assertTrue(status["logged_in"])
            self.assertEqual(status["selected"], "user@example.com")
            self.assertEqual(status["team_id"], "ABCDE12345")
            self.assertNotIn("SECRET-TOKEN", json.dumps(status))
            self.assertNotIn("session", status)

    def test_platform_key_is_known(self) -> None:
        self.assertIn(impactor.platform_key(), impactor.ASSETS)


class GameTests(unittest.TestCase):
    def make_game(self, temp: Path):
        pack = temp / "GamePack.dylib"
        rom = temp / "GameRom.cci"
        pack.write_bytes(b"pack-bytes")
        rom.write_bytes(b"rom-bytes")
        info = temp / "GameInfo.json"
        info.write_text(json.dumps({"schemaVersion": 1, "titleID": "0004000000055D00", "displayName": "Test"}), encoding="utf-8")
        return pack, rom, info

    def test_prepare_game_info_fills_hashes_and_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pack, rom, info = self.make_game(Path(temp))
            prepared = gamepush.prepare_game_info(info, "0004000000055D00", rom, pack=pack, launcher_version="0.2.0")
            self.assertEqual(prepared["pack"]["file"], "GamePack.dylib")
            self.assertEqual(prepared["pack"]["size"], len(b"pack-bytes"))
            self.assertEqual(prepared["pack"]["sha256"], gamepush.sha256_file(pack))
            self.assertEqual(prepared["rom"]["sha256"], gamepush.sha256_file(rom))
            self.assertEqual(prepared["launcherVersion"], "0.2.0")
            self.assertIn("pushedAt", prepared)

    def test_title_id_validation(self) -> None:
        self.assertEqual(gamepush.game_dir("0004000000055d00"), "Documents/Games/0004000000055D00")
        for bad in ("", "XYZ", "0004000000055D0"):
            with self.assertRaises(DeviceError):
                gamepush.game_dir(bad)

    def test_push_plan_puts_gameinfo_last(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pack, rom, info = self.make_game(Path(temp))
            plan = gamepush.push_plan("0004000000055D00", rom, info)
            self.assertEqual([Path(remote).name for remote, _ in plan], ["GameRom.cci", "GameInfo.json"])
            self.assertTrue(all(remote.startswith("Documents/Games/0004000000055D00/") for remote, _ in plan))

    def test_push_game_order_and_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pack, rom, info = self.make_game(Path(temp))
            calls: list[tuple[str, str]] = []
            sizes: dict[str, int] = {}
            pushed: dict[str, bytes] = {}

            def fake_put(exe, bundle, local, remote, container="app", udid=None, on_event=None):
                data = Path(local).read_bytes()
                calls.append((remote, Path(local).name))
                sizes[remote] = len(data)
                pushed[remote] = data
                if on_event:
                    on_event({"schema": "devpush/1", "type": "progress", "bytesSent": 1, "bytesTotal": 2, "percent": 50.0})
                return {"bytes": len(data), "sha256": "0" * 64}

            def fake_stat(exe, bundle, path, container="app", udid=None):
                return {"size": sizes[path], "isDir": False}

            def fake_get(exe, bundle, remote, local, container="app", udid=None, on_event=None):
                data = pushed[remote]
                Path(local).write_bytes(data)
                return {"bytes": len(data)}

            with mock.patch.object(gamepush.bridge, "put", fake_put), mock.patch.object(gamepush.bridge, "stat", fake_stat), mock.patch.object(gamepush.bridge, "get", fake_get):
                report = gamepush.push_game("devpush", "com.kratos.3ds2apple", "0004000000055D00", info, rom, pack=pack, launcher_version="0.2.0")
            self.assertTrue(report["verified"])
            self.assertEqual([Path(remote).name for remote, _ in calls], ["GameRom.cci", "GameInfo.json"])
            self.assertNotIn("GamePack.dylib", [name for _, name in calls])
            self.assertEqual(report["pack"]["sha256"], gamepush.sha256_file(pack))
            self.assertEqual(report["packLocation"], "ipa")

    def test_verify_game_semantic_mode_accepts_enriched_remote_info(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pack, rom, info = self.make_game(Path(temp))
            enriched = gamepush.prepare_game_info(info, "0004000000055D00", rom, pack=pack)

            def fake_stat(exe, bundle, path, container="app", udid=None):
                size = len(b"rom-bytes") if path.endswith("GameRom.cci") else 0
                return {"size": size, "isDir": False}

            def fake_get(exe, bundle, remote, local, container="app", udid=None, on_event=None):
                Path(local).write_text(json.dumps(enriched), encoding="utf-8")
                return {"bytes": 1}

            with mock.patch.object(gamepush.bridge, "stat", fake_stat), mock.patch.object(gamepush.bridge, "get", fake_get):
                report = gamepush.verify_game("devpush", "com.kratos.3ds2apple", "0004000000055D00", local_info=info)
            self.assertTrue(report["ok"], report["mismatches"])
            self.assertEqual(report["pack"]["sha256"], gamepush.sha256_file(pack))
            self.assertEqual(report["files"][0]["remote"].rsplit("/", 1)[-1], "GameRom.cci")
            self.assertEqual([Path(item["remote"]).name for item in report["files"]], ["GameRom.cci", "GameInfo.json"])


@unittest.skipIf(sys.platform == "win32", "fake devpush script needs a POSIX shebang")
class DevpushClientTests(unittest.TestCase):
    SCRIPT = """#!/usr/bin/env python3
import json, sys
args = [a for a in sys.argv[1:] if a != "--json"]
command = args[0] if args else ""
if command == "capabilities":
    print(json.dumps({"schema": "devpush/1", "type": "done", "command": "capabilities", "ok": True, "version": "0.1.0", "backend": "mock"}))
elif command == "devices":
    print(json.dumps({"schema": "devpush/1", "type": "done", "command": "devices", "ok": True, "devices": [{"udid": "FAKE-1", "connection": "usb", "paired": True}]}))
elif command == "fail":
    print(json.dumps({"schema": "devpush/1", "type": "error", "command": "put", "ok": False, "error": {"code": "app_missing", "message": "not installed", "hint": "install first"}, "exitCode": 5}))
    sys.exit(5)
"""

    def make_exe(self, temp: str) -> Path:
        path = Path(temp) / "fake-devpush"
        path.write_text(self.SCRIPT, encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_capabilities_and_devices(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            exe = self.make_exe(temp)
            self.assertEqual(devpush.capabilities(exe)["backend"], "mock")
            devices = devpush.devices(exe)
            self.assertEqual(devices[0]["udid"], "FAKE-1")

    def test_error_event_maps_to_wrapper_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            exe = self.make_exe(temp)
            with self.assertRaises(DeviceError) as caught:
                devpush.run(exe, ["fail"])
            self.assertEqual(caught.exception.code, "app_missing")
            self.assertEqual(caught.exception.exit_code, 8)
            self.assertIn("install first", caught.exception.hint)


class CliTests(unittest.TestCase):
    def test_status_without_tools_is_structured_and_not_ready(self) -> None:
        import device_cli

        with tempfile.TemporaryDirectory() as temp:
            buffer = io.StringIO()
            with mock.patch.object(device_cli.bridge, "find_devpush", side_effect=DeviceError("devpush_missing", "devpush not found")), \
                 mock.patch.object(device_cli.impactor, "find_tool", return_value=None), \
                 mock.patch.object(device_cli.impactor, "bundled_dir", return_value=None), \
                 mock.patch.dict(os.environ, {"DEVPUSH_EXE": "", "DEVPUSH_IMPACTOR_DIR": ""}):
                with contextlib.redirect_stdout(buffer):
                    code = device_cli.main(["status", "--json", "--resources", temp])
            self.assertEqual(code, 0)
            events = [json.loads(line) for line in buffer.getvalue().splitlines() if line.strip()]
            self.assertEqual(events[0]["schema"], "device-install/1")
            self.assertEqual(events[0]["type"], "begin")
            done = [event for event in events if event["type"] == "done"][-1]
            self.assertFalse(done["ready"])
            self.assertEqual(done["error"]["code"], "devpush_missing")

    def test_status_with_fake_devpush_and_mock(self) -> None:
        import device_cli

        script = DevpushClientTests.SCRIPT
        with tempfile.TemporaryDirectory() as temp:
            exe = Path(temp) / "fake-devpush"
            exe.write_text(script, encoding="utf-8")
            exe.chmod(0o755)
            buffer = io.StringIO()
            with mock.patch.dict(os.environ, {"DEVPUSH_EXE": str(exe), "DEVPUSH_IMPACTOR_DIR": temp}):
                with contextlib.redirect_stdout(buffer):
                    code = device_cli.main(["status", "--json", "--resources", temp])
            events = [json.loads(line) for line in buffer.getvalue().splitlines() if line.strip()]
            done = [event for event in events if event["type"] == "done"][-1]
            checks = {check["id"]: check for check in done["checks"]}
            self.assertEqual(code, 0)
            self.assertTrue(checks["devpush"]["ok"])
            self.assertTrue(checks["device"]["ok"])
            self.assertFalse(done["ready"])


@unittest.skipUnless(
    (devpush.REPO_ROOT / "tools" / "devpush" / "target" / "debug" / "devpush").exists()
    or (devpush.REPO_ROOT / "tools" / "devpush" / "target" / "release" / "devpush").exists(),
    "devpush binary not built yet",
)
@unittest.skipIf(sys.platform == "win32", "mock integration test runs the host devpush binary")
class WrapperMockIntegrationTests(unittest.TestCase):
    def find_bridge(self) -> Path:
        for profile in ("debug", "release"):
            path = devpush.REPO_ROOT / "tools" / "devpush" / "target" / profile / "devpush"
            if path.is_file():
                return path
        raise unittest.SkipTest("devpush binary not built")

    def test_push_game_end_to_end_against_mock_device(self) -> None:
        import device_cli

        binary = self.find_bridge()
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            mock_dir = temp_path / "mock"
            shell = temp_path / "Shell.ipa"
            shell.write_bytes(b"fake ipa for the mock device")
            env = {"DEVPUSH_EXE": str(binary), "DEVPUSH_MOCK_DIR": str(mock_dir), "DEVPUSH_IMPACTOR_DIR": ""}
            with mock.patch.dict(os.environ, env):
                devpush.install(binary, shell, bundle_id="com.kratos.3ds2apple")
                game = temp_path / "game"
                game.mkdir()
                (game / "GamePack.dylib").write_bytes(b"pack-bytes")
                (game / "GameRom.cci").write_bytes(b"rom-bytes")
                (game / "GameInfo.json").write_text(
                    json.dumps({"schemaVersion": 1, "titleID": "0004000000055D00", "displayName": "Mock Game"}),
                    encoding="utf-8",
                )
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer):
                    code = device_cli.main([
                        "push-game", "--json",
                        "--bundle-id", "com.kratos.3ds2apple",
                        "--title-id", "0004000000055D00",
                        "--game-info", str(game / "GameInfo.json"),
                        "--pack", str(game / "GamePack.dylib"),
                        "--rom", str(game / "GameRom.cci"),
                    ])
            self.assertEqual(code, 0, buffer.getvalue())
            events = [json.loads(line) for line in buffer.getvalue().splitlines() if line.strip()]
            done = [event for event in events if event["type"] == "done"][-1]
            self.assertTrue(done["verified"])
            pushed = mock_dir / "containers" / "com.kratos.3ds2apple" / "Documents" / "Games" / "0004000000055D00"
            self.assertEqual(sorted(path.name for path in pushed.iterdir()), ["GameInfo.json", "GameRom.cci"])
            self.assertFalse((pushed / "GamePack.dylib").exists(), "executable code must never be pushed into Documents")
            info = json.loads((pushed / "GameInfo.json").read_text(encoding="utf-8"))
            self.assertEqual(info["pack"]["size"], len(b"pack-bytes"))
            self.assertEqual(info["pack"]["sha256"], gamepush.sha256_file(game / "GamePack.dylib"))
            self.assertEqual(info["rom"]["sha256"], gamepush.sha256_file(game / "GameRom.cci"))


if __name__ == "__main__":
    unittest.main()
