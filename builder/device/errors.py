"""Stable error codes for the 3ds2apple sign/install + device-push wrapper.

Launchers consume the JSON error object:
    {"code": "...", "message": "...", "hint": "..."}
and the wrapper's process exit code (stable per code). Never log Apple ID
credentials: this layer only reads the account *selector* (email + team id) from
Impactor's account store, never the session tokens.
"""
from __future__ import annotations

import re

# code -> (exit_code, hint)
ERRORS: dict[str, tuple[int, str]] = {
    "usage": (2, "Check the command arguments; see docs/device-bridge.md."),
    "unsupported": (2, "This method is not available on the current platform; pick another --method."),
    "tool_missing": (3, "Install the missing tool or bundle it with the launcher (see scripts/impactor/)."),
    "devpush_missing": (3, "Build tools/devpush (cargo build --release --manifest-path tools/devpush/Cargo.toml) or bundle the devpush binary with the launcher; set DEVPUSH_EXE to override."),
    "impactor_missing": (3, "The launcher must bundle official Impactor v2.7.2 + plumesign (scripts/impactor/fetch_impactor.py --dest <dir>) or the user must install Impactor."),
    "impactor_hash_mismatch": (3, "A bundled Impactor/plumesign file does not match the pinned SHA-256. Re-fetch the official v2.7.2 release files; never re-sign or patch them."),
    "impactor_version_untested": (3, "A bundled or installed Impactor/plumesign is not the tested v2.7.2; re-fetch the pinned official release files."),
    "xcode_missing": (3, "Install Xcode and run 'xcode-select --install'; macOS signing needs Xcode provisioning."),
    "devicectl_missing": (3, "Xcode 15+ is required for xcrun devicectl (App Store) on macOS 13+."),
    "device_not_connected": (4, "Connect the iPhone/iPad with a USB cable, unlock it, tap Trust, and retry."),
    "device_ambiguous": (4, "Several devices are connected; pass --udid (device_cli.py devices lists them)."),
    "device_locked": (4, "Unlock the iPhone/iPad and keep it unlocked during install/push."),
    "pairing_required": (4, "Unlock the device and tap Trust on the Trust This Computer prompt; for Wi-Fi debugging the device must be on the same network."),
    "developer_mode_required": (4, "On iOS 16+ enable Settings > Privacy & Security > Developer Mode, reboot and confirm."),
    "apple_login_required": (5, "Sign in to your own Apple ID in official Impactor (or Xcode Accounts) once; the password is typed only into Impactor/Xcode and never passes through this tool."),
    "apple_session_expired": (5, "The saved Apple ID session expired. Open Impactor > Settings, remove and re-add the account, then retry."),
    "apple_id_wrong": (5, "Impactor reported a rejected Apple ID / password. Re-enter the credentials inside Impactor; this tool never sees them."),
    "signing_server_unreachable": (5, "Impactor's login helper server (mac-ani.jkcoxson.com) is unreachable. Check the network/DNS or proxy and retry."),
    "free_app_limit": (5, "Free Apple IDs can have at most 3 self-signed apps on a device; delete an app and retry."),
    "free_appid_limit": (5, "Free Apple IDs can register at most 10 App IDs per 7 days; reuse an existing identifier (--custom-identifier) or wait."),
    "app_id_taken": (5, "The app's bundle identifier is already registered to another team; retry with --custom-identifier <base>.<teamId> (the wrapper can retry automatically)."),
    "ipa_invalid": (6, "The file is not a valid IPA (Payload/<App>.app/Info.plist missing or corrupted). Rebuild the shell IPA."),
    "ipa_needs_repack": (6, "Impactor could not read the IPA (zip64/long paths); repack it as a regular zip."),
    "sign_failed": (6, "Signing failed. Check the Apple ID session, free-app slot and the tool output above; the IPA was not modified."),
    "install_failed": (7, "Signing succeeded but installation failed. Check the cable, unlock the device, and check the 3-app limit for free accounts."),
    "app_missing": (8, "The shell app is not installed on the device (or it was signed by another team). Install the base shell IPA first."),
    "container_unavailable": (8, "The app must be developer-signed (get-task-allow) to open its container; whole-container push requires Impactor/Xcode development signing."),
    "push_failed": (8, "File push failed; reconnect the device and retry. Files already pushed are kept, and GameInfo.json is written last so a partial push is ignored by the shell."),
    "verify_failed": (9, "Post-push verification failed (missing file or size/sha256 mismatch). Re-run push-game; if it repeats, check device free space."),
    "stall_timeout": (9, "The transfer stalled (no progress for the devpush stall timeout). Reconnect the cable/Wi-Fi and retry; do not leave the device locked."),
    "io_error": (1, "Local I/O failed; check paths, permissions and disk space."),
    "internal_error": (1, "Unexpected internal error; re-run with the same arguments and report the diagnostic text."),
}


class DeviceError(Exception):
    """Structured, user-facing failure with a stable code."""

    def __init__(self, code: str, message: str, hint: str | None = None, detail: str | None = None):
        self.code = code if code in ERRORS else "internal_error"
        self.message = message
        self.hint = hint or ERRORS[self.code][1]
        self.detail = detail
        super().__init__(message)

    @property
    def exit_code(self) -> int:
        return ERRORS[self.code][0]

    def payload(self) -> dict:
        payload = {"code": self.code, "message": self.message, "hint": self.hint}
        if self.detail:
            payload["detail"] = self.detail
        return payload


# devpush error code -> wrapper error code
_DEVPUSH_MAP = {
    "usage": "usage",
    "invalid_argument": "usage",
    "device_not_found": "device_not_connected",
    "device_ambiguous": "device_ambiguous",
    "usbmuxd_unavailable": "device_not_connected",
    "pairing_required": "pairing_required",
    "device_locked": "device_locked",
    "developer_mode_required": "developer_mode_required",
    "app_missing": "app_missing",
    "container_unavailable": "container_unavailable",
    "stall_timeout": "stall_timeout",
    "path_not_found": "push_failed",
    "afc_error": "push_failed",
    "io_error": "io_error",
    "install_failed": "install_failed",
    "unsupported": "unsupported",
    "internal_error": "internal_error",
}

_CLASSIFY = [
    # (regex, code) - applied to lowercase tool output; first match wins.
    (r"-80046|incorrect|entered incorrectly|invalid credentials|bad credentials", "apple_id_wrong"),
    (r"anisette[\s\S]{0,400}?(dns error|os error 1100[1-4]|connection (refused|reset|timed out)|error sending request)", "signing_server_unreachable"),
    (r"developer api error 1100\b|session has expired|please log ?in again|not logged in", "apple_session_expired"),
    (r"no account selected", "apple_session_expired"),
    (r"app id limit|\b10 app ids\b|maximum number of app ids|\b9120\b", "free_appid_limit"),
    (r"maximum number of (installed )?apps|\b3 apps\b", "free_app_limit"),
    (r"\b9401\b|app id with identifier[^\n]{0,120}is not available", "app_id_taken"),
    (r"mismatchedapplicationidentifierentitlement|application-identifier entitlement[^\n]{0,240}does not match", "sign_failed"),
    (r"unknown error occured while reading the file|unknown error occurred while reading the file|zip64", "ipa_needs_repack"),
    (r"name for this app is invalid", "ipa_needs_repack"),
    (r"developer mode", "developer_mode_required"),
    (r"device is locked|passcode|unlock", "device_locked"),
    (r"pairing|not paired|invalidhostid|trust", "pairing_required"),
    (r"no device|not connected|usbmux", "device_not_connected"),
]


def classify_tool_output(text: str, default: str = "sign_failed") -> str:
    """Map Impactor/plumesign/Xcode output text to a stable error code."""
    lowered = (text or "").lower()
    for pattern, code in _CLASSIFY:
        if re.search(pattern, lowered):
            return code
    return default


def map_devpush_error(code: str) -> str:
    return _DEVPUSH_MAP.get(code, "internal_error")


def error_event(command: str, err: DeviceError) -> dict:
    return {
        "schema": "device-install/1",
        "type": "error",
        "command": command,
        "ok": False,
        "error": err.payload(),
        "exitCode": err.exit_code,
    }
