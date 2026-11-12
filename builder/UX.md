# Builder user experience

> **Status: design.** These are the intended v1 screens and flows for the
> Windows/Linux Builder. The protocol they sit on is in
> [PROTOCOL.md](PROTOCOL.md); the technology behind them is in
> [STACK.md](STACK.md).

The Builder has one job: take a ROM the user owns from a Windows or Linux
desktop, build it on a macOS host the user controls, and hand back an unsigned
IPA with a verifiable checksum and honest installation instructions. Everything
else is in service of trust and recovery: the user must always know where their
ROM is, what the Mac is doing, and what to do when a step fails.

## 1. Personas and starting points

| Persona | Builder | macOS host | What they need to succeed |
|---|---|---|---|
| **Windows-only user** | Windows GUI | Cloud Mac (rented by the user) or a Mac on the LAN | Host setup guidance, clear "what is running where", Sideloadly/Store steps |
| **Linux desktop user** | Linux GUI or CLI | Local macOS VM or cloud Mac | SSH host setup, big-file transfer that resumes, a signing path (Windows/macOS machine) |
| **Headless/scripted user** | CLI | Any | `--json`, stable exit codes, resumable downloads, no GUI dependency |
| **Repeat builder** | GUI or CLI | Same host | Job history, re-run with the same game name, cached toolchain, fast path |

The flows below are the same in GUI and CLI; the CLI equivalents are listed in
§8.

## 2. First run

```text
┌─────────────────────────────────────────────────────────────────────┐
│  3ds2apple Builder                                       [–] [□] [×] │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Build your own game on a Mac you control                          │
│                                                                     │
│   The Builder turns your own decrypted .3ds / .cci into an          │
│   unsigned iOS app. The heavy build runs on a macOS host (a VM,     │
│   a Mac on your network, or a cloud Mac you rent). The ROM goes     │
│   only to that host and is deleted when the build ends.             │
│                                                                     │
│   [ Set up a build host ]              [ What do I need? ]          │
│                                                                     │
│   • Only use ROMs you legally own and have decrypted.               │
│   • This app never asks for an Apple ID or device UDID.             │
│   • The IPA it makes is unsigned; you sign it yourself.             │
└─────────────────────────────────────────────────────────────────────┘
```

"What do I need?" explains the two sides:

- **A macOS build host** with Xcode 16, Rust with `aarch64-apple-ios`,
  `xcodegen`, Python 3, git and ~20–30 GB free. The Agent's `doctor` checks all
  of it. The host can be headless.
- **About the ROM**: a decrypted base-game `.3ds`/`.cci` the user owns;
  1–4 GB typical. The project provides no ROM or keys. The current pipeline
  does not use a keys file; the optional keys slot exists for supplementary
  files.
- **Signing**: Sideloadly/AltStore/SideStore on Windows (or macOS); on Linux
  the IPA is copied to such a machine. Free Apple ID certificates expire after
  7 days; a paid developer account is optional.

This screen is the project's BYO-ROM statement, shown once before any file
selection. It is not a legal disclaimer to click through mindlessly; the build
review screen repeats the privacy facts.

## 3. Add a build host

The host wizard offers two connection modes, SSH (recommended for any remote
host) and HTTP (same machine or SSH tunnel).

### 3.1 SSH flow

```text
Step 1/4  Connect to the Mac
  Host:      [ mac-mini.local          ]
  Port:      [ 22      ]
  User:      [ builder                ]
  Key:       ( ) Use a new dedicated key  (recommended)
             ( ) Use an existing key: [ ~/.ssh/id_ed25519 ] ...

Step 2/4  Authorise the Builder on the Mac
  Add this line to ~/.ssh/authorized_keys on the Mac:

  command="/Users/builder/.local/bin/builder-agent ssh-dispatch",restrict
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... 3ds2apple-builder <profile-id>

  The command restriction means this key can only run the Build Agent —
  it can not open a shell or read other files.              [ Copy ]

  Host key fingerprint (verify on the Mac with ssh-keygen -lf):
  SHA256:AbCdEf...                                          [ Match ]

Step 3/4  Checking the Mac
  ✓ SSH connection and host key
  ✓ builder-agent 0.1.0 (protocol 1)
  ✓ Xcode 16.4, iOS 18.5 SDK
  ✓ Rust 1.99.1 with aarch64-apple-ios
  ✓ xcodegen 2.44.1, Python 3.11, git 2.46
  ✓ Source checkout: ~/src/3ds2apple @ 4cc6186 (clean)
  ✓ 84 GB free on the build volume
  ! MoltenVK not cached yet — the Agent will download it once
    (pinned v1.4.2, SHA256 verified) before the first packaging step.

Step 4/4  Name this host
  [ Mac mini in the office ]

  [ Test again ]                                   [ Save host ]
```

Failure cases on this screen are explicit and fixable:

| Check | Failure message and next step |
|---|---|
| SSH unreachable | "Can't reach mac-mini.local:22. Is Remote Login enabled? (System Settings → General → Sharing → Remote Login)". |
| Host key mismatch | Hard stop: "The host key changed. If you reinstalled the Mac, remove the old entry and pair again; otherwise stop and investigate." |
| Key not authorised | Shows the exact line to add again, with a hint to check `~/.ssh` ownership/permissions. |
| Agent missing | "`builder-agent` was not found on the PATH. Install the Agent on the Mac (see the host guide), then test again." |
| Toolchain missing | Lists each missing item, flags it red, links the host setup checklist. Saving is allowed in a "not ready" state; builds are blocked with the same list. |
| Repo dirty/wrong revision | Shows expected vs actual revision; offers "use this checkout anyway" only behind an explicit reproducibility warning. |
| Low disk | Shows required vs available; asks to free space. |

### 3.2 HTTP flow

Only offered for "this Mac" (Builder running on the Mac) or "SSH tunnel"
(recommended remote), with a note that a directly exposed Agent over the
internet is not recommended.

```text
1. On the Mac run:   builder-agent pair
   It prints a pairing line (host, port, token, TLS fingerprint).
2. Paste it here:    [ 3ds2apple-builder://pair?...              ]
3. Confirm the TLS fingerprint shown on the Mac matches.
```

If the clipboard path is unavailable, the same fields can be typed. The token
is stored in the OS credential store; the screen says so.

## 4. Build flow

### 4.1 Select the game

```text
┌─────────────────────────────────────────────────────────────────────┐
│  New build                                                          │
│                                                                     │
│  Game file                                                          │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Drop a .3ds or .cci here, or  [ Choose file… ]               │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  Pokemon Y.cci · 3.8 GB · SHA256 9f2c…d41b   ✓ ROM validated       │
│                                                                     │
│  Name for this build:   [ pokemon-y                      ]          │
│  Home-screen name:      [ Pokemon Y                      ]          │
│  Bundle identifier:     [ com.kratos.3ds2apple.pokemon-y ] (advanced)│
│  Title ID:              [ (detected during build)        ] (advanced)│
│                                                                     │
│  Options                                                            │
│  ☑ Embed MoltenVK (hardware rendering; recommended)                 │
│  ☐ Force clean build                                                │
│  ☐ Keep the ROM on the Mac after the build   ⚠ privacy             │
└─────────────────────────────────────────────────────────────────────┘
│  Build on:  Mac mini in the office  ·  SSH  ·  ready               │
│                                            [ Build ]  [ Cancel ]    │
└─────────────────────────────────────────────────────────────────────┘
```

Details:

- The file picker filters `.3ds`/`.cci`; other files are selectable only with
  an explicit "any file" override and a warning (the scripts will reject
  non-game data with a build failure).
- The SHA256 is computed in the background with progress and a Cancel button;
  the value is shown and transferred so the Agent can verify the upload.
- `Name for this build` is slugified from the ROM file name and editable
  within the scripts' rules (`A–Z a–z 0–9 . _ -`). It is what the build cache
  directories use; the UI warns that changing it changes cache reuse.
- `Home-screen name` becomes the app's display name.
- `Title ID` is optional; the build detects it and the result screen shows the
  value used. Advanced users can pre-set it to catch a wrong ROM early.
- `Keep the ROM on the Mac` is off by default. Turning it on shows the warning
  box inline: "The ROM will stay in the Agent's job directory until you delete
  the job. Only do this if you are debugging on a machine you control."
- Non-ASCII and CJK file names are supported (display name/labels), but the
  slug is ASCII. Windows path length and spaces are tested
 .

### 4.2 Transfer

```text
Uploading to Mac mini in the office
  Pokemon Y.cci · 2.1 GB of 3.8 GB (55%) · 34 MB/s · about 50 s left
  [ pause ]  [ cancel ]                                    (resumable)
```

- The upload is resumable; a drop, laptop sleep or Wi-Fi change shows
  "Interrupted — Resuming from 2.1 GB" and continues.
- The screen states the destination: "Sent only to *Mac mini in the office*.
  Deleted there when the build ends." No project server appears anywhere.
- Cancel during transfer offers "cancel build" and cleans up the partial upload
  on both sides.
- Path mode (same machine / shared folder) replaces the transfer screen with a
  one-line check: "The Agent will copy the file from `/Volumes/Share/Pokemon
  Y.cci`; your original stays untouched."

### 4.3 Build

```text
Building Pokemon Y · started 19:34 · 12:41 elapsed
┌─────────────────────────────────────────────────────────────────────┐
│ ✓ Preparing        source + toolchain + runtime library   (2 s)     │
│ ✓ Recompiling      3dsrecomp → C → arm64 objects        (11:02)     │
│ ● Linking          linked runtime + game archive                    │
│ ○ Packaging        xcodebuild + unsigned IPA                        │
│ ○ Verifying        SHA256 + manifest checks                        │
├─────────────────────────────────────────────────────────────────────┤
│ [build-linked-ios-lib] building linked runtime for title 0004…      │
│ [build-linked-ios-lib] cargo build --release --features linked      │
│ [build-game-ipa] xcodegen generate: ok                              │
│ … (live log, collapsible, follow tail on/off)                       │
└─────────────────────────────────────────────────────────────────────┘
                              [ Cancel build ]   [ Show full log ]
```

- The stage list is the honest summary; the log is the detail. A stage that
  can report file counts shows them ("compiling 318/761"); otherwise the UI
  shows activity (bytes of log, last line time) instead of a fake percentage.
- "What is happening?" tooltips explain each stage in one sentence
  (recompiling = translating the game's code to C and compiling it; packaging =
  building and zipping the app).
- Cancel: confirmation says what happens ("The Mac will stop the build and
  delete the job's files. This cannot resume; you will start over."). The job
  ends as canceled; partial data is cleaned.
- Closing the window does not cancel: a note says the build continues on the
  Mac and can be reattached from the job list (the GUI minimises to tray or
  shows a "build running" state; the CLI prints the job id and how to
  reattach).
- The first build on a fresh host can take longer in `preparing` (the Agent
  clones and builds the runtime once and caches it; MoltenVK is downloaded
  once). The UI explains that on the first run instead of looking stuck.

### 4.4 Result

```text
┌─────────────────────────────────────────────────────────────────────┐
│  ✓ Build succeeded                                   19:58           │
│                                                                     │
│  Pokemon Y                                                          │
│  pokemon-y-AOT.ipa · 96.4 MB                                        │
│  SHA256  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 │
│          [ Copy ]   [ Verify again ]                                │
│                                                                     │
│  Title 0004000000055E00 · Xcode 16.4 · source 4cc6186               │
│  Build host: Mac mini in the office                                 │
│  ROM on the host: deleted ✓                                         │
│                                                                     │
│  [ Open folder ]  [ Install guide ]  [ Build another ]              │
│                                                                     │
│  This IPA is unsigned and contains code derived from your game.     │
│  Sign and install it yourself; do not redistribute it.              │
└─────────────────────────────────────────────────────────────────────┘
```

- SHA256 is the first-class result (copy button, monospace, verify again
  recomputes the local file). The manifest summary shows the title ID, Xcode
  version and source revision used, so a support report has facts.
- "ROM on the host: deleted ✓" is the privacy confirmation. If cleanup failed,
  a warning with a "clean up now" action is shown instead.
- "Install guide" opens §6 with the user's platform-specific steps.
- The artifact stays in the Builder's local artifacts directory until the user
  deletes the job or a retention cleanup runs. The Agent's copy expires after
  the configured TTL; "Delete job from host" purges it immediately.

## 5. Jobs and history

```text
┌─────────────────────────────────────────────────────────────────────┐
│  Builds                                             [ New build ]   │
├─────────────────────────────────────────────────────────────────────┤
│  ✓ Pokemon Y        19:58 today   pokemon-y-AOT.ipa   96.4 MB       │
│  ✗ Pokemon X        18:12 today   failed · build_failed (link)      │
│  ⊘ Pokemon Alpha    11:40 today   canceled                          │
└─────────────────────────────────────────────────────────────────────┘
```

- History is local metadata + downloaded artifacts. Opening a job shows its
  stage timeline, logs (retained by the Builder), the artifact and the host
  actions: re-run, copy install guide, delete local, delete from host.
- "Re-run" reuses the game settings but creates a new job and uploads the ROM
  again; it never silently reuses an Agent-side partial build. If the previous
  job used `keep_input`, the UI reminds the user that a copy of that ROM is
  still in the old job directory until they delete it.
- A job whose Agent is unreachable shows "host offline"; logs and artifact
  actions stay available locally.

## 6. Installation guide

The guide is generated with the artifact path, SHA256 and the user's platform
filled in. It never asks for an Apple ID inside the Builder.

### Windows

1. Install [Sideloadly](https://sideloadly.io/) (or AltStore/SideStore) on the
   Windows PC. When Sideloadly needs Apple's mobile-device drivers, follow its
   own instructions.
2. Connect the iPhone/iPad by USB and trust the computer on the device.
3. Drag `<name>-AOT.ipa` into Sideloadly (or pick it), select the device, enter
   your own Apple ID in Sideloadly and press Start.
4. The device must trust the developer certificate after the first install:
   Settings → General → VPN & Device Management.
5. A free Apple ID certificate expires after 7 days; a paid developer account
   keeps it for a year. This is Apple's limit, not the Builder's.

### Linux

Official Sideloadly/AltStore builds do not run on Linux. Copy the IPA to a
Windows or macOS machine and follow the steps above, or use the community
Linux tooling *at your own risk* — it is not tested or supported by this
project. The Builder never signs anything and cannot install to a device.

### macOS

Sideloadly/AltStore work on macOS. If the user has a Mac for signing, they can
also use Xcode's Devices window with their own developer account; that path is
outside the Builder.

## 7. Error recovery

| Situation | What the user sees | One action |
|---|---|---|
| Host unreachable | "The Mac is offline" with last-seen time | Retry connection |
| Host key changed | Hard error, explanation | Stop and investigate / re-pair after reinstall |
| "Re-pair required" | Token/key invalid | Re-pair host |
| Toolchain missing | List of missing pieces with versions | "Run doctor on the Mac" + copy command |
| Source revision mismatch | Expected vs actual commit | Update the Mac checkout, or use it anyway with a warning |
| Host busy | Queue position / retry-after | Wait or cancel other job |
| Disk full | Required vs available | Free space on the Mac, retry |
| ROM rejected (hash/size) | "The upload was corrupted or the file changed" | Re-upload; verify SHA256 locally |
| Build failed | Stage, hint, last 40 log lines, copy redacted log | "Start new build" after fixing (with a note that the ROM must be uploaded again unless kept) |
| Canceled | Job canceled; no artifact | New build |
| Agent restarted | "The Mac restarted during the build" | New build |
| Network dropped mid-build | Build keeps running; "reconnecting…" | Reattach from the job list |
| Network dropped mid-download | Resumes from received bytes | — |
| Artifact checksum mismatch | "Download corrupted; retrying" | automatic retry, manual report after repeat |

Every failure message names the side that failed (your PC / the Mac / the
game file) and whether data was left behind.

## 8. CLI experience

The CLI is the reference client and the Linux/headless path. It follows the
same states and messages; human output is concise, `--json` emits the protocol
frames for scripting.

```bash
# host setup (prints the authorized_keys line and fingerprint)
zkb host add --ssh builder@mac-mini.local --port 22 --name office
zkb host doctor office

# build one game (prints stages, streams logs, downloads and verifies)
zkb build --host office --rom "./ROM/Pokemon Y.cci" \
          --name pokemon-y --display-name "Pokemon Y" \
          --out ./out

# reattach / inspect / cancel
zkb jobs --host office
zkb status --host office <job-id> --follow
zkb logs --host office <job-id> --since 0 > build.log
zkb cancel --host office <job-id>

# download later (resumable, verified)
zkb download --host office <job-id> --out ./out --verify

# cleanup
zkb delete --host office <job-id>
```

Conventions:

- Exit codes: `0` success; `1` build failed; `2` usage/config; `3` host/auth/
  transport; `4` canceled by user; `5` local I/O (disk, write); `64+` internal
  errors. The `--json` mode includes the error code from the protocol.
- `--json` writes NDJSON events to stdout and diagnostics to stderr, so the CLI
  composes with `jq`.
- `zkb build` prints the artifact path and SHA256 on the last lines (the same
  convention the existing build scripts use) and exits non-zero on failure.
- Non-interactive use never prompts: missing host credentials or confirmation
  flags are usage errors.
- The CLI never prints the token, and `zkb config` redacts it.

## 9. Guardrails and copy rules

Things the UI must do or say, and things it must never do:

| Must | Must never |
|---|---|
| State where the ROM goes and when it is deleted, before the upload | Upload the ROM to the project or any host not configured by the user |
| Ask for confirmation before canceling a running build, deleting host data, or keeping inputs | Ask for an Apple ID, password, 2FA code, UDID or certificate |
| Show the exact artifact SHA256 and verify it | Claim the IPA is "signed", "ready to install" or "tested" |
| Show toolchain/source versions used for the build | Hide a source/revision mismatch behind a warning-only flow for a normal build |
| Offer a redacted-log export that strips local paths and the ROM file name | Include ROM contents, keys or tokens in any log or bug report |
| Explain that free-Apple-ID installs expire and that sideloading is required | Suggest App Store distribution or claim Nintendo affiliation |
| Warn when a remote host is rented/third-party and can access the Mac's disk | Automate signing, install or device provisioning |
| Localise UI strings (the project's primary audience includes Chinese users; zh-CN first) | Use game screenshots in the repository or the UI's shipped assets |

## 10. Accessibility and platform details

- **Keyboard:** every action reachable without a mouse; file drop has a picker
  fallback; focus order follows the visual flow; Escape cancels dialogs only.
- **Screen readers:** stage list is a list with status text (not colour-only);
  progress has textual values; log viewer is copyable text.
- **Colour:** state is encoded by icon + text, not only green/red; contrast
  meets WCAG AA.
- **Large files:** progress events are rate-limited (4/s) so the UI stays
  responsive on multi-GB uploads; logs are virtualised.
- **DPI/scaling:** GUI respects system scaling on Windows and fractional
  scaling on Linux.
- **Paths:** long Windows paths (`\\?\`), spaces, Unicode and CJK file names
  are first-class; the data directory is configurable if the default is in a
  synced folder.
- **Offline:** the Builder works offline once a host is paired; only the build
  host needs network access for first-run provisioning (Zakuro/3dsrecomp
  clones, MoltenVK download).
