# Device bridge, signing and the Documents data layout

Status: implemented in this tree · last updated 2026-11-16 · contract version
`devpush/1`. This document is the device-side contract for the Windows and macOS
launchers and for QA. It covers:

- **tools/devpush** — Rust device bridge: Apple usbmuxd (USB/Wi-Fi), house_arrest
  VendContainer/VendDocuments + AFC file transfer, installation_proxy
  install/uninstall/app attributes, progress events and a 90-second stall watchdog.
- **the launchers** — signing/install with the bundled official Impactor +
  plumesign (Windows) or Xcode/devicectl (macOS), then the game-data push.
- **licenses/impactor** — the Impactor MIT and apple-codesign MPL-2.0 texts plus
  the pinned release hashes and source links.

Hard boundaries: we do not implement Apple ID authentication and never see or log
passwords/session tokens; we never modify, patch or re-sign Impactor/plumesign; we
never distribute ROMs, IPAs, dylibs or generated C in git.

## 1. Layout

| Path | What it is |
|---|---|
| tools/devpush/ | Rust CLI + tests (mock device backend included) |
| tools/devpush/README.md | build/usage quickstart |
| licenses/impactor/ | Impactor MIT + apple-codesign MPL-2.0 texts, SHA-256 pins and source links |
| launcher/windows/src/.../Device/DevPushClient.cs | Windows launcher client for the `devpush/1` contract |
| launcher/macos/Sources/ | macOS launcher: Xcode signing/install + devpush pushes |
| docs/device-bridge.md | this contract |

## 2. Build and test (host-side; no device required)

```bash
cargo build --release --manifest-path tools/devpush/Cargo.toml
cargo test --manifest-path tools/devpush/Cargo.toml
```

The release binary is `tools/devpush/target/release/devpush` (`devpush.exe` on
Windows). The launchers resolve it from the app/launcher bundle first, then the
checkout, then `PATH` (or an explicit `DEVPUSH_EXE`).

Mock smoke test for the push split (no phone needed; safe for launcher CI):

```bash
# 1) install a dummy signed IPA into the mock device
tools/devpush/target/release/devpush --mock-dir /tmp/dp-mock --json install \
    --ipa /tmp/Shell.ipa --bundle-id com.kratos.3ds2apple
# 2) push ROM + GameInfo; the pack is metadata only (it is embedded in the IPA)
tools/devpush/target/release/devpush --mock-dir /tmp/dp-mock --json put \
    --bundle-id com.kratos.3ds2apple --local /tmp/game/GameRom.cci \
    --remote Documents/Games/0004000000055D00/GameRom.cci
tools/devpush/target/release/devpush --mock-dir /tmp/dp-mock --json put \
    --bundle-id com.kratos.3ds2apple --local /tmp/game/GameInfo.json \
    --remote Documents/Games/0004000000055D00/GameInfo.json
# expect: one begin/progress/done per file; Documents/Games/<TITLEID>/ contains
# exactly GameInfo.json + GameRom.cci
```

## 3. devpush CLI contract v1

### 3.1 Output

With **--json** (global flag, accepted before or after the subcommand) every line
on stdout is one JSON object with "schema":"devpush/1" and "type" one of:
begin | progress | warn | done | error. No other stdout output. stderr carries
human diagnostics only (no credentials, no game data names beyond paths the
launcher already knows). Without --json the CLI prints human lines.

Event shapes:

```
{"schema":"devpush/1","type":"begin","command":"put","bundleId":"com.kratos.3ds2apple","remote":"Documents/Games/0004000000055D00/GameRom.cci"}
{"schema":"devpush/1","type":"progress","command":"put","file":"GameRom.cci","bytesSent":1048576,"bytesTotal":4567890,"percent":23.0}
{"schema":"devpush/1","type":"done","command":"put","ok":true,"remotePath":"Documents/Games/.../GameRom.cci","bytes":4567890,"sha256":"<sha256 of local file>"}
{"schema":"devpush/1","type":"error","command":"put","ok":false,"error":{"code":"app_missing","message":"...","hint":"..."},"exitCode":5}
```

### 3.2 Commands

| Command | Purpose |
|---|---|
| devpush capabilities --json | version, schema, backend, commands, features, stallSeconds |
| devpush devices --json | [{udid,name,model,iosVersion,connection,paired}] (USB first) |
| devpush install --ipa FILE [--bundle-id ID] [--udid U] | install an already-signed IPA |
| devpush uninstall --bundle-id ID [--udid U] | uninstall app + container |
| devpush app-attr --bundle-id ID [--key K] [--udid U] | Info.plist attributes; no --key returns scalar keys + convenience fields |
| devpush ls --bundle-id ID --path P [--container app\|documents] | directory entries |
| devpush stat --bundle-id ID --path P [--container ...] | size/isDir/mtime |
| devpush put --bundle-id ID --local F --remote P [--container ...] | stream one file in |
| devpush get --bundle-id ID --remote P --local F [--container ...] | stream one file out |
| devpush put-tar --bundle-id ID (--tar F \| --manifest L --root D) --dest P | stream tar in |
| devpush tar-ok --bundle-id ID --path P | archive completeness check |
| devpush mkdir / rm --bundle-id ID --path P | container directories |
| devpush free --bundle-id ID | free/total bytes from AFC device info |
| devpush tar-local / tar-ok-local | host-side helpers, no device |

Paths are container-relative (for example Documents/Games/<TITLEID>/GameRom.cci),
never absolute and never contain "..". --container app is house_arrest
VendContainer (whole app data container, requires a developer-signed app);
--container documents is VendDocuments (requires UIFileSharingEnabled).

### 3.3 Device selection

--udid is optional. Exactly one connected device is auto-selected; none exits 3
device_not_found; several without --udid exits 3 device_ambiguous (launchers show a
picker, or call devices and pass --udid).

### 3.4 Exit codes and error codes (stable)

| Exit | Codes |
|---|---|
| 0 | success |
| 1 | internal_error |
| 2 | usage, invalid_argument |
| 3 | device_not_found, device_ambiguous, usbmuxd_unavailable |
| 4 | pairing_required, device_locked |
| 5 | app_missing, container_unavailable |
| 6 | stall_timeout |
| 7 | afc_error, path_not_found, io_error |
| 8 | install_failed |
| 9 | developer_mode_required, unsupported |

Error objects may include "hint" and, for AFC failures, "afcCode" (AFC protocol
sub-code; 8 = object not found). Launchers surface hint text and retry push/game
files after reconnect; install errors need the signing step first.

### 3.5 Progress and stall watchdog

put/get/put-tar emit throttled progress (default 1 s, DEVPUSH_PROGRESS_MS).
A background watchdog exits the process with code 6 / stall_timeout when no
payload progress happened for DEVPUSH_STALL_SECONDS (default 90; 0 disables).
install/uninstall are exempt (installation_proxy can be legitimately silent).
This mirrors the field failure where AFC blocked forever at 86% after the cable
was unplugged; the launcher shows the stall error instead of hanging.

### 3.6 Mock backend

devpush --mock-dir DIR (or DEVPUSH_MOCK_DIR) runs the entire CLI against a
filesystem mock: state.json holds devices + installed apps; containers/<bundleId>/
and documents/<bundleId>/ hold container files. Same JSON, same exit codes. Use
it in launcher CI and for dry runs without a phone.

### 3.7 Examples

```bash
devpush devices --json
devpush --json app-attr --bundle-id com.kratos.3ds2apple
devpush --json put --bundle-id com.kratos.3ds2apple --local GameRom.cci \
    --remote Documents/Games/0004000000055D00/GameRom.cci
devpush --json put-tar --bundle-id com.kratos.3ds2apple --manifest files.txt \
    --root ./stage --dest Documents/Games/0004000000055D00/pack.tar
devpush --json tar-ok --bundle-id com.kratos.3ds2apple --path Documents/Games/0004000000055D00/pack.tar
```

## 4. Signing and install in the launchers

### 4.1 Windows: bundled official Impactor v2.7.2 + plumesign

The launcher bundles the official release files unmodified:

| File | SHA-256 (official GitHub release digest) |
|---|---|
| Impactor-windows-x86_64-portable.exe | f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef |
| plumesign-windows-x86_64.exe | b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0 |

(All platform pins are recorded in `launcher/windows/vendor/impactor/PINS.json`
and [licenses/impactor/README-bundled-tools.txt](../licenses/impactor/README-bundled-tools.txt).)

- Fetch/verify the files with `launcher/windows/tools/fetch-impactor.sh`
  (`fetch-impactor.ps1` on Windows); packaging runs the same check.
- The launcher refuses (impactor_hash_mismatch) a bundled copy whose SHA-256 does
  not match the pin. It never re-signs or patches the binaries.
- Licenses: Impactor is MIT (Copyright 2025 Samara M); embedded apple-codesign
  0.29.0 is MPL-2.0. Texts: `licenses/impactor/`. Sources:
  <https://github.com/claration/impactor/tree/v2.7.2> and
  <https://github.com/claration/impactor/tree/v2.7.2/3rdparty/apple-codesign-0.29.0>.
- Sign flow: plumesign sign --package Shell.ipa --apple-id --udid <udid>
  --register-and-install (plus --custom-identifier when requested); the launcher
  then verifies the installed bundle id through `devpush app-attr`.
- The user still signs in inside Impactor; the launcher only reads the account
  selector (email + team id) from `%APPDATA%\PlumeImpactor\accounts.json` and
  never reads tokens.

### 4.2 macOS: Xcode signing + devicectl

The macOS launcher builds the shell with Xcode and installs it with
`xcrun devicectl device install app` using the user's automatic signing team.
Xcode owns certificates and provisioning profiles; the launcher never implements
signing itself. After installation the launcher verifies the installed bundle via
devpush and then pushes the game data. A signed IPA may also be installed with
`devpush install` (installation_proxy) when it was signed elsewhere.

### 4.3 Apple ID policy

This project never implements Apple ID authentication. Passwords, 2FA codes and
session tokens are handled exclusively by Impactor (Windows) or Xcode (macOS).
The launcher reads only the account selector, never logs credentials, and reports
apple_login_required with instructions instead of prompting for a password. Free
Apple ID limits (3 apps/device; 10 App IDs/7 days) are reported as
free_app_limit / free_appid_limit / app_id_taken with actionable hints.

### 4.4 Install sequence (launcher view)

Prerequisites (manual, one-time):
1. iPhone/iPad: enable Developer Mode (iOS 16+), unlock, connect by USB, tap Trust.
2. Windows: sign in inside the bundled Impactor. macOS: sign in to Xcode Accounts.
3. usbmuxd must be running (Apple Mobile Device service on Windows, usbmuxd or
   Xcode on macOS); `devpush devices` must list the device with paired=true.

Deploy, in order:
1. Readiness gate: devpush + signing tool + Apple ID selector + connected device.
2. Compile a GamePack for every selected game (Windows: local 3dsrecomp + LLVM/LLD;
   macOS: 3dsrecomp + Apple clang).
3. Compose the ROM-free shell IPA: shell template + `Frameworks/GamePack-<TITLEID>.dylib`
   per selected game + generated schema-2 `GameCatalog.json` (the template's
   MoltenVK framework is already inside). Nested dylibs are covered by IPA signing;
   adding a game means recomposing and reinstalling the IPA, while Documents data
   persists.
4. Sign and install. On app_id_taken with a free account the Windows launcher
   retries with `--auto-identifier` or a custom identifier
   `com.kratos.3ds2apple.<teamId>`; the installed bundle id is read back from the
   device.
5. Push each selected title's ROM + GameInfo.json (section 5), then verify.

### 4.5 Bundle id

The base shell IPA advertises `com.kratos.3ds2apple` (`ios/app/project.yml`). The
launcher never rewrites the IPA's Info.plist; when a signing tool re-identifies the
app, the installed bundle id is read from the device and used for every push.

## 5. Game data push layout and flow (ROM + metadata only)

Games are split between the signed IPA (executable code) and the app data
container (user data):

```text
Documents/                          pushed by the launcher via devpush
  Games/<TITLEID>/                  TITLEID = 16 upper-case hex
    GameInfo.json                   schemaVersion 1 (written last)
    GameRom.cci                     the user's decrypted ROM (never in IPA/repo)

Signed shell IPA (built/installed, never pushed by the bridge)
  Frameworks/GamePack-<TITLEID>.dylib   per-game AOT pack
  GameCatalog.json                      embedded catalog (packs + titles)
```

Executable code is NOT pushed: the shell loads the per-game pack and catalog from
the app bundle, and IPA signing covers nested dylibs. Pushing executable code into
the Documents container is unsupported by design — iOS dyld refuses an unsigned
copy — and the launcher never sends it.

Push behavior:
1. Validate GameInfo.json (schemaVersion 1, titleID matches) and the local ROM
   (canonical `GameRom.cci` name). The pack is embedded in the signed IPA; the
   launcher records its bundle-relative path in GameInfo.pack metadata as
   informational data (file/size/sha256, packBundled:true). The shell's embedded
   GameCatalog is authoritative for where the pack lives.
2. Enrich GameInfo.json: rom {file,size,sha256}, pack metadata, launcherVersion,
   pushedAt.
3. Push GameRom.cci, then GameInfo.json LAST. The shell shows a title only after
   GameInfo.json exists and the ROM verifies; an interrupted push leaves "Data
   missing" until a retry, completed files are kept and overwritten on retry.
   Pushed ROM data persists across shell reinstall/update: adding a game rebuilds
   and reinstalls the IPA, data stays.
4. Verify: stat the remote ROM (size), download GameInfo.json and compare its
   sha256, report verify_failed on any mismatch. The done payload lists the two
   pushed files plus the pack metadata and packLocation:"ipa".

Historical note: the first device-bridge draft pushed GamePack.dylib into
Documents. That cannot work because iOS dyld refuses unsigned code; it was
replaced by the IPA-embedded-pack split. The current contract has no loose-dylib
signing step at all.

## 6. Manual device test (no real device available to agents)

All host-side checks are automated (section 10). The following must be executed
once by a maintainer with a device, in order:

1. `devpush devices --json`: one device, paired=true, correct model/iOS.
2. app-attr on the installed shell: installed=true, fileSharingEnabled true.
3. Put a 100 MB file, watch progress events, then stat/ls/get it back and compare
   sha256 with the local file.
4. During another large put, pull the USB cable: expect exit 6 stall_timeout
   within the stall timeout, no hang; reconnect and retry — completed files kept.
5. Deploy a composed shell IPA (embedded GamePack dylibs + GameCatalog) on a clean
   device: first run reports the Apple ID requirement, after signing in it
   installs, app-attr confirms the installed bundle id, and launching a game
   proves the nested dylibs load under IPA signing. This real-device check is
   still required — host-side tests cannot prove nested-dylib signing.
6. Push a ROM + GameInfo.json for a title whose pack is embedded in the signed
   IPA; confirm the shell lists the game, clears "Data missing" and launches it.
7. Verify free-account errors are reported as free_app_limit/free_appid_limit and
   the auto-identifier retry path.
8. Confirm no Apple ID email/password/token appears in launcher logs or devpush
   stderr/stdout (only the selected email may be shown in the launcher's Settings).

## 7. Known limitations / follow-ups

- Launch is not implemented in devpush v1: macOS uses `devicectl device process
  launch`, Windows launch stays manual.
- Wi-Fi devices need usbmuxd network pairing; USB is the tested default path.
- install/uninstall are exempt from the stall watchdog by design.
- The mock backend does not emulate AFC errors, pairing or signing; it is for
  contract/flow testing only.
- Apple ID accounts cannot be created or migrated by this tool (by design).

## 8. Security and privacy

- No Apple ID/password/OAuth implementation; credentials stay in Impactor/Xcode.
- Only the account selector (email/team id) is read from Impactor's store; tokens
  are never read, logged or transmitted by our code.
- Device UDIDs appear in local CLI output/status only; nothing is committed.
- No ROM/keys/IPA/dylib/generated C is written into the repository; the mock
  backend and tests use synthetic bytes under temporary directories.
- Official Impactor/plumesign files are only fetched from the pinned GitHub
  release and hash-verified; bundled copies are refused on mismatch.

## 9. Licensing

- This repository is Apache-2.0.
- idevice crate (MIT, <https://github.com/jkcoxson/idevice>) is used by
  tools/devpush, pinned to commit 5171e34e3a236842af1160a84d955d037ddca3af (the
  same upstream commit official Impactor v2.7.2 uses).
- The house_arrest/AFC/installation_proxy usage pattern follows S2Arm's
  s2a-devpush (Apache-2.0) as an API-usage reference; see NOTICE.
- Official Impactor v2.7.2 (MIT) + embedded apple-codesign 0.29.0 (MPL-2.0) are
  bundled unmodified at launcher packaging time, with licenses in
  [licenses/impactor](../licenses/impactor/README-bundled-tools.txt) and source
  links in THIRD_PARTY.md. Binaries are not committed.
- No GPL/AGPL code is copied.

## 10. Host-side evidence (2026-11-16)

| Check | Command | Result |
|---|---|---|
| Rust unit tests | cargo test --manifest-path tools/devpush/Cargo.toml | 5 passed (tar/pax/checksum, stall math, mock manifest) |
| Rust mock CLI tests | same | 3 passed (devices, install/put/get/ls/stat/put-tar/tar-ok, stable exit codes) |
| Stall watchdog integration | same | 1 passed (silent usbmuxd -> exit 6 stall_timeout in ~2 s) |
| Windows launcher client tests | cd launcher/windows && dotnet test Launcher.slnx -c Debug | DevPushClient contract covered by the launcher test suite |
| Release build | cargo build --release ... | devpush binary produced |
| Impactor release pins | launcher/windows/vendor/impactor/PINS.json + GitHub API v2.7.2 assets | hashes match the official release digests |
| plumesign CLI contract | official plumesign-linux-x86_64 v2.7.2 | sign/device/account commands as used above |
