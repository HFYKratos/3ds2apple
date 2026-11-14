# devpush - 3ds2apple device bridge (Rust)

A small CLI that talks to an iPhone/iPad through Apple usbmuxd (USB or Wi-Fi):

- list connected devices (name/model/iOS version/transport)
- install / uninstall a signed IPA through installation_proxy
- read Info.plist attributes of an installed app
- open an app's container with house_arrest (VendContainer) + AFC and
  put / get / ls / stat / mkdir / rm / put-tar, with progress events and a
  90-second stall watchdog

It is the device side of the launcher-first architecture; the signing/install
wrapper (`builder/device/`) drives official Impactor/plumesign or Xcode and calls this
binary for container pushes. Full launcher contract: `docs/device-bridge.md`.

## Data-only policy (3ds2apple flow)

The bridge can move any container file, but the launcher flow only pushes user
data: `Documents/Games/<TITLEID>/{GameRom.cci, GameInfo.json}`. Per-game
executable code (`GamePack.dylib`) and `GameCatalog.json` are embedded in the
signed shell IPA by the launcher/build step and must never be copied into
Documents - iOS dyld refuses unsigned code. The wrapper's push-game enforces
ROM-first, GameInfo.json-last ordering; executable code is out of scope here.

## Build and test (host-side; no device required)

    cargo build --release --manifest-path tools/devpush/Cargo.toml
    cargo test --manifest-path tools/devpush/Cargo.toml

The binary is `tools/devpush/target/release/devpush` (Windows: `devpush.exe`).
Dependencies: `idevice` (MIT, pinned to the same upstream commit official
Impactor v2.7.2 uses), tokio, plist, clap, serde, sha2. See THIRD_PARTY.md.

The unit/integration tests cover the tar stream, stall watchdog, NDJSON/exit-code
contract and a full mock-device roundtrip; they do not need an iPhone.

## Mock backend (CI / launcher dry-run)

    devpush --mock-dir /tmp/devpush-mock --json devices
    devpush --mock-dir /tmp/devpush-mock --json install --ipa Shell.ipa --bundle-id com.kratos.3ds2apple
    devpush --mock-dir /tmp/devpush-mock --json put --bundle-id com.kratos.3ds2apple \
        --local GameRom.cci --remote Documents/Games/0004000000055D00/GameRom.cci

The mock keeps `state.json` (devices + installed apps) and maps container paths to
`containers/<bundleId>/` and `documents/<bundleId>/` under the mock root. Same JSON
contract and exit codes as a real device.

## Environment variables

| Variable | Meaning |
|---|---|
| `USBMUXD_SOCKET_ADDRESS` | usbmuxd address: host:port or a Unix socket path (default: local usbmuxd) |
| `DEVPUSH_MOCK_DIR` | enable the filesystem mock backend |
| `DEVPUSH_STALL_SECONDS` | stall watchdog timeout (default 90, 0 disables) |
| `DEVPUSH_PROGRESS_MS` | progress event interval (default 1000 ms) |

## Real-device manual test (agents have no device)

1. Connect the iPhone/iPad by USB, unlock it and tap Trust; enable Developer Mode on iOS 16+.
2. `devpush devices --json` must list the UDID with `paired: true`.
3. Install the base shell IPA with Impactor/plumesign (Windows) or Xcode/devicectl (macOS).
4. `devpush app-attr --bundle-id com.kratos.3ds2apple --json` must report `installed: true`.
5. Push a file with `devpush put ...`, verify with `devpush stat/ls`, pull it back with `devpush get` and compare sha256.
6. Kill the USB connection during a large put: the command must exit 6 with `stall_timeout` after the timeout, not hang.
7. `devpush put-tar --manifest ...` then `devpush tar-ok ...` must print `ok: true`.

## License

Apache-2.0 (this repository). The service usage pattern (house_arrest
VendContainer + AFC, installation_proxy) follows S2Arm's s2ap-devpush
(Apache-2.0); see NOTICE. No Apple ID handling, no custom signing.
