# Device bridge and signing/install wrapper

Status: implemented in this tree (uncommitted, awaiting Lead review) - 2026-11-14.
Owner: task-16 (device-bridge). Contract versions: devpush/1 (Rust bridge) and
device-install/1 (Python wrapper).

This document is the authoritative contract for the macOS and Windows launchers
(launcher/macos, launcher/windows) and for QA. It covers:

- **tools/devpush** - Rust device bridge: Apple usbmuxd (USB/Wi-Fi), house_arrest
  VendContainer/VendDocuments + AFC file transfer, installation_proxy
  install/uninstall/app attributes, progress events and a 90-second stall watchdog.
- **builder/device** - Python wrapper: readiness report, official Impactor
  v2.7.2 plumesign signing/install (unmodified, SHA-256 pinned), Xcode/devicectl
  install path on macOS, and the game-pack push/verify flow.
- **scripts/impactor** - fetch/verify the official Impactor + plumesign release
  files and keep their licenses.

Hard boundaries: we do not implement Apple ID authentication and never see or log
passwords/session tokens; we never modify, patch or re-sign Impactor/plumesign;
we never distribute ROMs, IPAs, dylibs or generated C in git.

## 1. Layout

| Path | What it is |
|---|---|
| tools/devpush/ | Rust CLI + tests (mock device backend included) |
| tools/devpush/README.md | build/usage quickstart |
| builder/device/device_cli.py | stable CLI/JSON API for launchers |
| builder/device/{errors,impactor,ipa,devpush,gamepush}.py | wrapper modules |
| builder/device/tests/test_device.py | host-side unit + mock integration tests |
| scripts/impactor/fetch_impactor.py | download-or-bundled official Impactor/plumesign |
| scripts/impactor/install-shell.sh | convenience wrapper around sign-install |
| scripts/impactor/licenses/ | MIT (Impactor) and MPL-2.0 (apple-codesign) texts + notice |
| docs/device-bridge.md | this contract |

## 2. Build and test (host-side; agents have no real device)

~~~
cargo build --release --manifest-path tools/devpush/Cargo.toml
cargo test --manifest-path tools/devpush/Cargo.toml
python3 builder/device/tests/test_device.py -v
python3 -m py_compile builder/device/*.py builder/device/tests/*.py
~~~

The release binary is tools/devpush/target/release/devpush (devpush.exe on Windows).
The wrapper resolves it from, in order: explicit path, DEVPUSH_EXE, the repo
release/debug target, PATH.

Mock smoke test for the launcher push split (no phone needed; safe for launcher CI):
~~~
# 1) install a dummy signed IPA into the mock device
tools/devpush/target/release/devpush --mock-dir /tmp/dp-mock --json install \
    --ipa /tmp/Shell.ipa --bundle-id com.kratos.3ds2apple
# 2) push ROM + GameInfo; --pack is metadata only (the pack is embedded in the IPA)
DEVPUSH_EXE=$PWD/tools/devpush/target/release/devpush DEVPUSH_MOCK_DIR=/tmp/dp-mock \
  python3 builder/device/device_cli.py push-game --json \
    --bundle-id com.kratos.3ds2apple --title-id 0004000000055D00 \
    --game-info /tmp/game/GameInfo.json --rom /tmp/game/GameRom.cci \
    --pack /tmp/game/GamePack.dylib
# expect: steps "1/2 GameRom.cci", "2/2 GameInfo.json"; done verified:true;
# Documents/Games/<TITLEID>/ contains exactly GameInfo.json + GameRom.cci
~~~

## 3. devpush CLI contract v1

### 3.1 Output

With **--json** (global flag, accepted before or after the subcommand) every line
on stdout is one JSON object with "schema":"devpush/1" and "type" one of:
begin | progress | warn | done | error. No other stdout output. stderr carries
human diagnostics only (no credentials, no game data names beyond paths the
launcher already knows). Without --json the CLI prints human lines.

Event shapes:

~~~
{"schema":"devpush/1","type":"begin","command":"put","bundleId":"com.kratos.3ds2apple","remote":"Documents/Games/0004000000055D00/GameRom.cci"}
{"schema":"devpush/1","type":"progress","command":"put","file":"GameRom.cci","bytesSent":1048576,"bytesTotal":4567890,"percent":23.0}
{"schema":"devpush/1","type":"done","command":"put","ok":true,"remotePath":"Documents/Games/.../GameRom.cci","bytes":4567890,"sha256":"<sha256 of local file>"}
{"schema":"devpush/1","type":"error","command":"put","ok":false,"error":{"code":"app_missing","message":"...","hint":"..."},"exitCode":5}
~~~

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
sub-code; 8 = object not found). Launchers should surface hint text and retry
push/game files after reconnect; install errors need the signing wrapper first.

### 3.5 Progress and stall watchdog

put/get/put-tar emit throttled progress (default 1 s, DEVPUSH_PROGRESS_MS).
A background watchdog exits the process with code 6 / stall_timeout when no
payload progress happened for DEVPUSH_STALL_SECONDS (default 90; 0 disables).
install/uninstall are exempt (installation_proxy can be legitimately silent).
This mirrors the field failure where AFC blocked forever at 86% after the cable
was unplugged; the launcher must show the stall error instead of hanging.

### 3.6 Mock backend

devpush --mock-dir DIR (or DEVPUSH_MOCK_DIR) runs the entire CLI against a
filesystem mock: state.json holds devices + installed apps; containers/<bundleId>/
and documents/<bundleId>/ hold container files. Same JSON, same exit codes. Use
it in launcher CI and for dry runs without a phone.

### 3.7 Examples

~~~
devpush devices --json
devpush --json app-attr --bundle-id com.kratos.3ds2apple
devpush --json put --bundle-id com.kratos.3ds2apple --local GameRom.cci \
    --remote Documents/Games/0004000000055D00/GameRom.cci
devpush --json put-tar --bundle-id com.kratos.3ds2apple --manifest files.txt \
    --root ./stage --dest Documents/Games/0004000000055D00/pack.tar
devpush --json tar-ok --bundle-id com.kratos.3ds2apple --path Documents/Games/0004000000055D00/pack.tar
~~~

## 4. Signing/install wrapper

### 4.1 Commands

| Command | Purpose |
|---|---|
| python3 builder/device/device_cli.py status --json [--resources D] [--udid U] [--devpush E] | readiness report, never fails for "not ready" (ready=false + error) |
| ... devices --json | connection list (pass-through of devpush devices) |
| ... sign-install --ipa F [--bundle-id ID] [--udid U] [--method auto\|plumesign\|devicectl] [--resources D] [--custom-identifier ID] [--auto-identifier] | sign with official Impactor plumesign and install; or devicectl for an already-signed IPA |
| ... push-game --bundle-id ID --title-id TID --game-info F --rom F [--pack F] [--udid U] [--launcher-version V] [--game-name N] | push GameRom.cci + GameInfo.json (pack stays in the signed IPA; --pack only fills GameInfo.pack metadata) and verify |
| ... verify-game --bundle-id ID --title-id TID [--game-info F] [--udid U] | verify pushed ROM + GameInfo (pack is in the IPA) |
| ... fetch-tools --dest D [--platform KEY] | download-or-bundled official Impactor/plumesign + licenses, SHA-256 verified |

All commands accept --json (NDJSON, schema device-install/1). Event types:
begin, step (name/status/detail), progress (phase/percent), done, error.
Progress during push comes from the devpush contract above, wrapped in
"phase":"push" with file/bytesSent/bytesTotal/percent and fileIndex/fileCount.

### 4.2 status payload

~~~
{"schema":"device-install/1","type":"done","command":"status","ok":true,
 "platform":"windows-x86_64","ready":false,
 "checks":[{"id":"devpush","ok":true,...},{"id":"plumesign","ok":true,...},
           {"id":"apple-id","ok":false,"code":"apple_login_required",...},
           {"id":"device","ok":true,...}],
 "paths":{"devpush":"...","plumesign":"...","impactor":null,"devicectl":null},
 "impactor":{"tested":"2.7.2","bundleOk":true,"release":"...","sourceLinks":{...}},
 "appleId":{"loggedIn":false,"selected":null,"accounts":[],"teamId":null},
 "devices":[...], "error":{"code":"apple_login_required","message":"...","hint":"..."}}
~~~

ready=true only when devpush + a signing tool + Apple ID selector (plumesign path)
+ a connected device are all OK. status always exits 0 when the query itself
worked; launchers gate on ready. sign-install/push-game/verify-game emit a terminal
error event and non-zero exit on failure.

### 4.3 Wrapper exit codes and error codes

| Exit | Codes |
|---|---|
| 0 | success |
| 1 | io_error, internal_error |
| 2 | usage, unsupported |
| 3 | tool_missing, devpush_missing, impactor_missing, impactor_hash_mismatch, impactor_version_untested, xcode_missing, devicectl_missing |
| 4 | device_not_connected, device_ambiguous, device_locked, pairing_required, developer_mode_required |
| 5 | apple_login_required, apple_session_expired, apple_id_wrong, signing_server_unreachable, free_app_limit, free_appid_limit, app_id_taken |
| 6 | ipa_invalid, ipa_needs_repack, sign_failed |
| 7 | install_failed |
| 8 | app_missing, container_unavailable, push_failed |
| 9 | verify_failed, stall_timeout |

Every error payload is {"code","message","hint"} (plus optional "detail"). The
catalog and user-facing hints live in builder/device/errors.py.
Impactor/plumesign/Xcode output is classified into these codes, so launchers do
not parse English error text themselves.
devpush codes are mapped: device_not_found -> device_not_connected,
path_not_found/afc_error -> push_failed, stall_timeout -> stall_timeout, etc.

### 4.4 Windows path: bundled official Impactor v2.7.2 + plumesign

The launcher bundles the official release files unmodified:

| File | SHA-256 (official GitHub release digest) |
|---|---|
| Impactor-windows-x86_64-portable.exe | f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef |
| plumesign-windows-x86_64.exe | b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0 |

(arm64/x86 variants and macOS/Linux assets are pinned in
builder/device/impactor.py and scripts/impactor/licenses/README-bundled-tools.txt.)

- Fetch with download-or-bundled mode: python3 scripts/impactor/fetch_impactor.py
  --dest <launcher>/ThirdParty/Impactor [--platform windows-x86_64].
- The wrapper refuses (impactor_hash_mismatch) a bundled copy whose SHA-256 does
  not match the pin. It never re-signs or patches the binaries.
- Licenses: Impactor is MIT (Copyright 2025 Samara M); embedded apple-codesign
  0.29.0 is MPL-2.0. Texts: scripts/impactor/licenses/. Sources:
  https://github.com/claration/impactor/tree/v2.7.2 and
  https://github.com/claration/impactor/tree/v2.7.2/3rdparty/apple-codesign-0.29.0
- Sign flow: plumesign sign --package Shell.ipa --apple-id --udid <udid>
  --register-and-install (plus --custom-identifier when requested), then the
  wrapper verifies the installed bundle id through devpush app-attr.
- The launcher still opens Impactor for the first Apple ID login; the wrapper
  only reads the selector (email + team id) from
  %APPDATA%\PlumeImpactor\accounts.json and never reads tokens.

### 4.5 macOS path

Preferred: the same official plumesign binary (plumesign-macos-universal,
SHA-256 f07f8d25813e6a8c1e0e5ae8cec53e795b496c7f1fb6262eb725fde36eb3dafa)
bundled by the macOS launcher; login stays in Impactor.app (or an existing
Impactor install). Fallback: xcrun devicectl device install app for an IPA that
Xcode already signed (Developer Mode + trusted computer required). Xcode
provisioning path: open ios/app project, select the user's team, build/install
to the device (Xcode handles certificates/profiles), then optionally verify with
devpush. The wrapper does not implement any signing itself.

### 4.6 Apple ID policy

This project never implements Apple ID authentication. Passwords, 2FA codes and
session tokens are handled exclusively by Impactor (Windows/macOS) or Xcode.
The wrapper reads only the account selector, never logs credentials, and reports
apple_login_required with instructions instead of prompting for a password.
Free Apple ID limits (3 apps/device; 10 App IDs/7 days) are reported as
free_app_limit / free_appid_limit / app_id_taken with actionable hints.

## 5. Base shell install flow

Prerequisites (manual, one-time):
1. iPhone/iPad: enable Developer Mode (iOS 16+), unlock, connect by USB, tap Trust.
2. Windows: install/launch the bundled Impactor, sign in with the user's Apple ID
   (password only inside Impactor). macOS: sign in to Impactor or Xcode Accounts.
3. usbmuxd must be running (Apple Mobile Device service on Windows, usbmuxd or
   Xcode on macOS); devpush devices must list the device with paired=true.

Launcher sequence (all NDJSON):
1. device_cli.py status --json --resources <launcher dir> -> gate on ready.
2. device_cli.py sign-install --json --ipa <shell.ipa> --resources <dir> [--udid U]
   (default bundle id comes from the IPA, expected com.kratos.3ds2apple).
   Windows launchers may compose the installable IPA themselves before this step:
   start from the ROM-free shell template, embed Frameworks/GamePack-<TITLEID>.dylib
   for every built game plus the generated GameCatalog schema v2, then pass that
   composed IPA to sign-install (or to their bundled official plumesign directly).
   Nested dylibs are covered by IPA signing; adding a game means rebuilding and
   reinstalling the IPA, while Documents data persists. The bridge afterwards only
   pushes GameRom.cci + GameInfo.json.
3. On app_id_taken with a free account: retry once with --auto-identifier or pass
   --custom-identifier com.kratos.3ds2apple.<teamId>; record the installed bundle id
   returned in the done event - it is needed for every push.
4. Optionally verify: python3 builder/device/device_cli.py status --json --udid U.
5. push-game for each imported title, then library refresh.

Bundle id configuration: the base shell IPA advertises com.kratos.3ds2apple
(ios/app/project.yml). The wrapper never rewrites the IPA's Info.plist; when a
signing tool re-identifies the app, the done event returns the actual installed
bundle id. Launchers must persist it per device.

## 6. Game data push layout and flow (ROM + metadata only)

Correction 2026-11-14 (supersedes the initial draft): games are split between the
signed IPA (executable code) and the app data container (user data).

~~~
Documents/                          pushed by the launcher via devpush
  Games/<TITLEID>/                  TITLEID = 16 upper-case hex
    GameInfo.json                   schemaVersion 1 (task-17 contract; last)
    GameRom.cci                     the user's decrypted ROM (never in IPA/repo)

Signed shell IPA (built/installed, never pushed by the bridge)
  Frameworks/GamePack-<TITLEID>.dylib   per-game AOT pack
  GameCatalog.json                      embedded catalog (packs + titles)
~~~

Executable code is NOT pushed: the shell loads the per-game pack and catalog from
the app bundle, and IPA signing (Impactor/plumesign or Xcode) covers nested
dylibs. Pushing executable code into the Documents container is unsupported by
design - iOS dyld refuses an unsigned copy - and push-game never sends it.

push-game behavior:
1. Validate GameInfo.json (schemaVersion 1, titleID matches --title-id) and the
   local ROM (must be named GameRom.cci). --pack is optional: when given it is
   only hashed/sized (never uploaded) so GameInfo.pack {file,size,sha256}
   describes the pack embedded in the signed IPA; it is informational and is
   not a pushed file. pack naming/metadata is not enforced by push-game or
   verify-game (they validate only titleID + ROM): the shell's embedded
   GameCatalog is authoritative for where the pack lives, so launchers that
   compose the IPA themselves may use their own form (e.g.
   Frameworks/GamePack-<TITLEID>.dylib with packBundled:true) as well.
2. Enrich GameInfo.json: rom {file,size,sha256}, pack metadata (if supplied),
   launcherVersion, pushedAt.
3. Push GameRom.cci, then GameInfo.json LAST. The shell shows a title only after
   GameInfo.json exists and the ROM verifies; an interrupted push leaves "Data
   missing" until a retry, completed files are kept and overwritten on retry.
   Pushed ROM data persists across shell reinstall/update: adding a game rebuilds
   the IPA with the pack+catalog and reinstalls, data stays.
4. Verify: stat the remote ROM (size), download GameInfo.json and compare its
   sha256, report verify_failed on any mismatch. The done payload lists the two
   pushed files plus the pack metadata and packLocation:"ipa".

Historical note: the first task-16 draft pushed GamePack.dylib into Documents.
That cannot work because iOS dyld refuses unsigned code; it was replaced by the
IPA-embedded-pack split after Lead review. The current contract has no
loose-dylib signing step at all.

## 7. Manual device test (no real device available to agents)

All host-side checks are automated (section 11). The following must be executed
once by a maintainer with a device, in order:

1. devpush devices --json: one device, paired=true, correct model/iOS.
2. app-attr on the installed shell: installed=true, fileSharingEnabled true.
3. put a 100 MB file, watch progress events, then stat/ls/get it back and compare
   sha256 with the local file.
4. During another large put, pull the USB cable: expect exit 6 stall_timeout
   within the stall timeout, no hang; reconnect and retry - completed files kept.
5. push-game a ROM + GameInfo.json for a title whose pack is embedded in the
   signed IPA; confirm the shell lists the game, clears "Data missing" and
   launches it (task-17). Optionally put-tar a larger staged ROM tree and tar-ok it.
6. sign-install a composed shell IPA (embedded GamePack dylibs + GameCatalog) on
   a clean device: first run reports apple_login_required, after Impactor login it
   installs, app-attr confirms the installed bundle id, and launching a game proves
   the nested dylibs load under IPA signing. This real-device check is still
   required - host-side tests cannot prove nested-dylib signing.
7. Verify free-account errors are reported as free_app_limit/free_appid_limit and
   the --auto-identifier retry path.
8. Confirm no Apple ID email/password/token appears in launcher logs or wrapper
   stderr/stdout (only the selected email may be shown in status).

## 8. Known limitations / follow-ups

- Launch is not implemented in devpush v1 (optional in the task). macOS launchers
  can use xcrun devicectl device process launch; Windows launch stays manual.
- Historical note only: the initial draft considered signing a loose
  GamePack.dylib for Documents. That is gone - packs now ship inside the signed
  IPA (launcher/build step), so there is no loose-dylib signing step and no
  Windows limitation. push-game never touches executable code.
- Wi-Fi devices need usbmuxd network pairing; USB is the tested default path.
- install/uninstall are exempt from the stall watchdog by design.
- The mock backend does not emulate AFC errors, pairing or signing; it is for
  contract/flow testing only.
- Apple ID accounts cannot be created or migrated by this tool (by design).

## 9. Security and privacy

- No Apple ID/password/OAuth implementation; credentials stay in Impactor/Xcode.
- Only the account selector (email/team id) is read from Impactor's store; tokens
  are never read, logged or transmitted by our code.
- Device UDIDs appear in local CLI output/status only; nothing is committed.
- No ROM/keys/IPA/dylib/generated C is written into the repository; the mock
  backend and tests use synthetic bytes under temporary directories.
- Official Impactor/plumesign files are only fetched from the pinned GitHub
  release and hash-verified; bundled copies are refused on mismatch.

## 10. Licensing

- This repository is Apache-2.0.
- idevice crate (MIT, https://github.com/jkcoxson/idevice) is used by
  tools/devpush, pinned to commit 5171e34e3a236842af1160a84d955d037ddca3af (the
  same upstream commit official Impactor v2.7.2 uses).
- The house_arrest/AFC/installation_proxy usage pattern follows S2Arm's
  s2a-devpush (Apache-2.0) as an API-usage reference; see NOTICE.
- Official Impactor v2.7.2 (MIT) + embedded apple-codesign 0.29.0 (MPL-2.0) are
  bundled unmodified at launcher packaging time, with licenses in
  scripts/impactor/licenses/ and source links in THIRD_PARTY.md. Binaries are
  not committed.
- No GPL/AGPL code is copied.

## 11. Host-side evidence (2026-11-14)

| Check | Command | Result |
|---|---|---|
| Rust unit tests | cargo test --manifest-path tools/devpush/Cargo.toml | 5 passed (tar/pax/checksum, stall math, mock manifest) |
| Rust mock CLI tests | same | 3 passed (devices, install/put/get/ls/stat/put-tar/tar-ok, stable exit codes) |
| Stall watchdog integration | same | 1 passed (silent usbmuxd -> exit 6 stall_timeout in ~2 s) |
| Wrapper unit tests | python3 builder/device/tests/test_device.py -v | 20 passed (IPA, errors, Impactor pins/licenses, ROM+GameInfo-only push/verify, fake devpush, status, mock e2e: only 2 files pushed, pack metadata only) |
| Release build | cargo build --release ... | devpush binary produced |
| Impactor release pins | GitHub API v2.7.2 assets | hashes match impactor.py |
| plumesign CLI contract | official plumesign-linux-x86_64 v2.7.2 | sign/device/account commands as used above |
