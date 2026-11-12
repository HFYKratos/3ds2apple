# 3ds2apple Builder for Windows

The Windows frontend of the 3ds2apple Builder. It turns a **decrypted ROM you
own** into an **unsigned iOS app (IPA)** by driving the Build Agent on a macOS
host you control — a macOS VM, a Mac on your network, or a cloud Mac you rent.
The Windows PC never needs Xcode: it hashes the ROM, sends it only to your own
host, streams the build, downloads the IPA and verifies its SHA256.

The heavy lifting is unchanged from the rest of the project: `scripts/` runs
3dsrecomp, the iOS clang and `xcodebuild` on the macOS host, and the Builder
never re-implements that pipeline.

> **Status: working first slice, CLI-first.** `builder-windows.exe` is a
> self-contained Windows executable with a guided session and full build
> commands. It shares the wire protocol, the client logic, the hashing and the
> host configuration with the `zkb` CLI through `builder-core`; there is no
> second protocol implementation. A graphical shell is **not part of this
> slice** — see [GUI status](#gui-status).

```text
┌──────────── Windows PC ────────────┐        ┌──────────── macOS host ────────────┐
│ builder-windows.exe                │  SSH   │ builder-agent                      │
│  guided session / commands         │───────►│  job queue · build · cleanup       │
│  builder-core (protocol/client)    │        │  scripts/: recomp → link → IPA     │
│  ROM hashing · transfer progress   │◄───────│  events, log, artifact + SHA256    │
└──────────────┬─────────────────────┘        └──────────────┬─────────────────────┘
               │                                              │
               ▼                                              ▼
        unsigned IPA + manifest.txt + artifact.json     ROM deleted after the job
               │
               ▼
        Sideloadly / AltStore / SideStore (your own Apple ID)
```

## Requirements

| Piece | Requirement |
|---|---|
| Windows | Windows 10 22H2 or newer, or Windows 11; x86_64 |
| OpenSSH client | Required for a remote host: Settings → Apps → Optional features → **OpenSSH Client**, or as administrator `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` |
| PowerShell | Used for one read-only free-space probe; present on every supported Windows |
| macOS host | A macOS machine you own running `builder-agent` (see [../README.md](../README.md)); headless is fine, no Apple ID or device needed there |
| Disk | A few hundred MiB for the IPA; the frontend refuses to download below 256 MiB free |
| Signing | Sideloadly / AltStore / SideStore on this Windows PC with your own Apple ID; the Builder never signs, installs or asks for credentials |

## Install and run

### From a release ZIP

1. Download `builder-windows-<version>-windows-x86_64.zip` and its `SHA256SUMS`
   from the project's GitHub Releases. No release is made from this slice yet;
   `packaging/package.ps1` produces exactly this layout.
2. Verify the download before running it (the executable is **unsigned**, so
   SmartScreen will warn — verify instead of disabling SmartScreen):

   ```powershell
   # PowerShell: compare with the value in SHA256SUMS
   (Get-FileHash -Algorithm SHA256 .\builder-windows.exe).Hash.ToLower()
   # or with built-in certutil
   certutil -hashfile .\builder-windows.exe SHA256
   ```

   If the hash matches `SHA256SUMS`, the download is intact. The project has no
   code-signing certificate, so a "Windows protected your PC" prompt is expected:
   choose **More info → Run anyway** only for a hash you verified.
3. Run `builder-windows.exe` with no arguments for the guided session.

### From source

```powershell
cd builder
cargo build -p builder-windows --release
.\target\release\builder-windows.exe
```

Rust 1.80+ for Windows (MSVC or GNU toolchain). The frontend has no runtime
dependency: no Rust, Python or Node is needed on the machine that runs it.

Building the release ZIP:

```powershell
.\builder\windows\packaging\package.ps1 `
    -ExePath .\builder\target\release\builder-windows.exe `
    -Version 0.1.0 -OutDir .\dist
```

See [packaging/README.md](packaging/README.md) for installer and signing status.

## First run

Running `builder-windows.exe` with no arguments starts the guided session:

1. **What this does** — the ROM is sent only to the host you configure and is
   deleted there when the build ends; no Apple ID, no device UDID, unsigned IPA.
2. **Build host** — if none is configured, the session walks through SSH
   pairing: it creates a dedicated key, reads the host's key fingerprints, asks
   you to confirm one on the Mac, and prints the exact `authorized_keys` line to
   paste there. Nothing is written on the Mac by the Builder.
3. **ROM** — drag the `.3ds`/`.cci` into the window or paste its path
   ("Copy as path" quoting is accepted). The file is checked locally first.
4. **Names** — the build name (ASCII, used in build directories) and the
   home-screen name (any language) are prefilled from the file name.
5. **Summary** — what will be sent where, then the build starts. Type `c` and
   press Enter to cancel.
6. **Result** — IPA path, SHA256, manifest, artifact record, installation guide,
   and the ROM cleanup status on the host.

Everything the wizard does is also available as a command for shortcuts and
scripted use.

## Commands

```text
builder-windows [--config <file>] [--json] <command>

  (no command)              guided session
  app                       guided session with optional pre-filled values
  doctor [--host <name>]    check this PC (and optionally the Mac)
  host add|list|test|remove manage build hosts (shared with the zkb CLI)
  build                     build one game and download the IPA
  status --host <host> <job-id> [--follow]
  logs   --host <host> <job-id> [--since <seq>] [--no-follow]
  cancel --host <host> <job-id> [--reason <text>]
  download --host <host> <job-id> [--out <dir>]
  jobs   --host <host> [--limit <n>]
  delete --host <host> <job-id>
  install-guide --ipa <file> --sha256 <hex> [--display-name <name>] [--out <file>]
  self-test                 on-PC compatibility checks (no Mac, no ROM)
  config                    show the configuration
  open <path>               open a folder in Explorer
```

Useful flags:

- `--json` prints machine-readable JSON/NDJSON (protocol events during a build,
  structured `doctor`/`self-test`/`status`/`host list` output, an error object on
  failure).
- `build --host office --rom "D:\ROM\Pokemon Y.cci" --name pokemon-y
  --display-name "Pokemon Y" --out .\out` is the non-interactive path.
- `build --keys <file>` uploads an optional supplementary file. The current
  per-game pipeline builds from a decrypted ROM and does not read it; it is
  uploaded only to your host and deleted with the job.
- `build --keep-input` leaves the ROM on the Mac until you delete the job.
  Off by default, with a warning.
- `app --dry-run` validates the whole plan without connecting; `--yes` accepts
  the defaults for scripted use.

Exit codes match the `zkb` CLI: `0` success, `1` build failed, `2` usage/config,
`3` host/auth/transport, `4` canceled, `5` local I/O, `64+` internal.

The configuration file is the **same** one `zkb` uses
(`%APPDATA%\3ds2apple\builder\config.toml`, override with `--config`), and each
host profile keeps its dedicated key and `known_hosts` under
`%APPDATA%\3ds2apple\builder\profiles\<host-id>\`. Pair a host once with either
tool and both can build on it. Downloaded artifacts default to
`%LOCALAPPDATA%\3ds2apple\builder\artifacts`.

## Windows-specific behavior

### Long paths, spaces, Unicode and CJK

- ROMs, output folders and profiles may exceed the classic 260-character limit:
  the frontend converts them to extended-length (`\\?\`) paths for its own file
  operations, so no system-wide registry change is required. A path over 260 is
  reported once as a note, because other tools (Explorer, some archivers) may
  still refuse it.
- Spaces, Unicode and CJK are supported. The build name is always an ASCII slug
  (the build scripts use it as a directory name); the home-screen name and log
  text keep Unicode.
- Windows-reserved names (`CON`, `NUL`, `COM1`, ...), trailing dots/spaces and
  forbidden characters are detected before uploading with a fixable message.
- The console is UTF-8 by nature, but `conhost` renders using the active code
  page. On a CJK code page (for example 936) logs may look garbled, and
  `doctor` warns about it: run `chcp 65001` first or use Windows Terminal.
- "Copy as path" wraps a path in double quotes and drag and drop can add a
  trailing space; both are accepted.

### OpenSSH client

- The frontend uses the system OpenSSH client (`ssh`, `ssh-keygen`,
  `ssh-keyscan`) — there is no bundled crypto stack, and no password is ever
  stored or prompted for.
- If `ssh-keyscan` cannot read a host key (observed with the Windows OpenSSH
  9.5 client against a newer sshd that offers a post-quantum key exchange
  first), a throwaway `ssh` connection learns the host key instead and the
  fingerprint must still be confirmed by you.
- Paths that contain spaces (a Windows user name like `John Smith` puts them in
  `%APPDATA%`) are quoted for ssh's option parser; without quoting, host key
  verification silently fails.
- Private keys created by the onboarding flow have the ACLs the Windows OpenSSH
  client requires. A key copied from elsewhere can trigger
  "UNPROTECTED PRIVATE KEY FILE"; restrict it with
  `icacls <key> /inheritance:r /grant:r "%USERNAME%:R"`.
- Connection multiplexing is disabled on Windows: the Win32 client has no
  Unix-domain control sockets. Each data channel opens its own short SSH
  connection.

### WebView2

Only a future **graphical** build needs the WebView2 runtime. `doctor` reports
whether it is present, but the CLI-first frontend has no webview dependency and
works with it absent. Windows 10/11 normally ships it.

### Free space and disks

`doctor` and the download step probe free space through a read-only PowerShell
call (the path is passed as an environment variable, never interpolated into a
command). The frontend refuses to start a download below 256 MiB free and warns
below 2 GiB. Network drives work but hashing a multi-gigabyte ROM from a slow
share is, naturally, slow; a local copy is faster.

### SmartScreen and unsigned binaries

The executable is unsigned. Windows SmartScreen therefore warns on first run.
The project cannot fix that without a code-signing certificate; instead the
release ships `SHA256SUMS` and this README explains how to verify a download.
Do not disable SmartScreen or add broad exclusion rules: verify the hash.

### Sleep, network changes and antivirus

- The build runs on the Mac, so the PC may sleep or the connection may drop
  mid-build: the job keeps running. Reattach with `status --host <host> <job-id>
  --follow`; a dropped download can be retried with `download`, which resumes
  from the Agent's artifact.
- Corporate antivirus/proxies sometimes block `ssh.exe` or PowerShell; the
  `doctor` output tells you which piece is missing. No separate port or service
  is opened by the Builder.

### Installer packaging

The first release format is a portable folder/ZIP with `SHA256SUMS`, produced
by [`packaging/package.ps1`](packaging/package.ps1). An MSI/NSIS installer and
code signing are not available in this slice; [packaging/README.md](packaging/README.md)
records the status.

## Installing the IPA

The Builder produces an **unsigned** IPA and never handles Apple IDs or devices.
The result screen and `<build-name>-INSTALL.txt` repeat the steps with the exact
file and SHA256 filled in:

1. Verify the file:
   `certutil -hashfile "<ipa>" SHA256` or
   `Get-FileHash -Algorithm SHA256 "<ipa>"`.
2. Install Sideloadly from <https://sideloadly.io/>, connect the iPhone/iPad by
   USB and trust the computer.
3. Drag the `.ipa` into Sideloadly, select the device, and enter your own Apple
   ID inside Sideloadly.
4. On the device: Settings → General → VPN & Device Management → trust the
   developer certificate.
5. A free Apple ID certificate expires after 7 days; a paid Apple developer
   account lasts about a year. This is Apple's limit.

Alternatives: [AltStore](https://altstore.io/) and
[SideStore](https://sidestore.io/). The IPA contains code derived from your own
game: do not redistribute it.

## Troubleshooting

| Symptom | Meaning and fix |
|---|---|
| `builder-windows: transport error: ... exited with code 255` | SSH could not connect. Check the host address/port, Remote Login on the Mac, and that the printed `authorized_keys` line was pasted into `~/.ssh/authorized_keys` with the right ownership. |
| `Host key verification failed` / "No ED25519 host key is known" | The host key changed, or the pinned profile is stale. If the Mac was reinstalled, remove and re-add the host; otherwise stop and investigate. Also update the Builder if the profile path contains spaces (fixed in core). |
| `the Mac is not ready to build: toolchain_missing, ...` | Run `builder-windows host test <host>` and fix the listed items on the Mac (Xcode + iOS SDK, Rust with the iOS target, xcodegen, Python 3, disk space). |
| `openssh: the OpenSSH client (ssh) is not installed` from `doctor` | Install the OpenSSH Client optional feature (see requirements). |
| Build fails with a stage and hint | The message names the failing stage and shows the Agent's hint plus the last log lines; the ROM must be uploaded again for a retry unless `--keep-input` was used. |
| `only ... free on the volume ...` | Free disk space on this PC, or pass `--out` to another drive. |
| CJK text looks garbled in the console | `chcp 65001`, or use Windows Terminal. |
| `UNPROTECTED PRIVATE KEY FILE` | Restrict the key ACL (see OpenSSH above). |
| `self-test` reports a failure | Copy the `[FAIL]` line into a bug report; it names the broken area (paths, hashing, config, ...). |

## GUI status

A Tauri 2 graphical shell (ROM picker, host wizard pages, stage list, live log
viewer, result page with install guide) is **designed but not implemented or
shipped** in this slice. It was deliberately deferred rather than committed
unverified:

- it needs a Windows build host with the Tauri toolchain (Rust + Node + WiX/NSIS)
  and runtime-tests against WebView2, none of which this repository can verify
  from its Linux/macOS build hosts;
- the CLI-first frontend already covers the whole user flow, including a guided
  session, and keeps working on machines where a webview is unavailable or
  blocked.

The frontend is structured so the GUI is thin: `builder-windows` is a library
crate whose build engine reports through a `Progress` trait, and the same engine
already emits protocol events (`--json` mode uses exactly those). A Tauri shell
would add file dialogs, the screens from [../UX.md](../UX.md), and the installer,
without touching the protocol or build code.

## Verification status

Verified for this slice:

| Area | How |
|---|---|
| Compiles for Windows and Linux | `cargo check`/`cargo build`/`cargo test` for the host and `x86_64-pc-windows-gnu` targets |
| Protocol path end to end | Integration tests run the real Agent (fake-build mode) through the production `ssh-dispatch` local transport: build, stream, download, SHA256, cleanup, failure exit code 1, cancel exit code 4, usage errors |
| Windows executable on Windows 11 x86_64 | `doctor` (OpenSSH 9.5p2, WebView2 157.x, code page 936 warning, long-path registry, 31.8 GiB disk), `self-test` incl. a 378-character path and CJK file names, guided session with piped input, host add/list/config with a CJK config path, dry runs with CJK and 330-character ROM paths, `install-guide`, exit codes 2/5 |
| Cross-machine build over SSH | Windows frontend → Windows OpenSSH → Linux sshd → Agent in fake-build mode: upload, stages, log, artifact download, SHA256 verified, ROM deleted on the host |
| Packaging | `packaging/package.ps1` run on Windows 11: ZIP with `builder-windows.exe`, licence/notice/README, `SHA256SUMS` matching the executable |

Not verified here (needs the real macOS target or hardware):

- A build from this frontend against a **real macOS host** running the real
  scripts (the Agent and script pipeline are exercised separately; the macOS
  run is the project's next end-to-end step).
- A real Sideloadly/AltStore installation of the produced IPA.
- The deferred Tauri GUI, MSI/NSIS installers and code signing.

## Development

```bash
cd builder
cargo test -p builder-windows          # unit tests + Linux E2E against the real Agent
cargo clippy -p builder-windows --all-targets -- -D warnings
cargo fmt --all -- --check
```

`builder/windows/tests/e2e.rs` needs the workspace's `builder-agent` binary; run
`cargo test --workspace` (or `cargo build -p builder-agent` first) so the fake
build mode is available. The E2E tests are Unix-gated; the Windows-only paths
are covered by `self-test` and by running the executable on Windows.

Cross-compiling from Linux for a quick Windows check (optional):

```bash
rustup target add x86_64-pc-windows-gnu
cargo build -p builder-windows --target x86_64-pc-windows-gnu   # needs a mingw-w64 linker
```

## Security and privacy

- The ROM is uploaded only to the host you configure, over SSH with key
  authentication. The project runs no build service, no telemetry and no crash
  uploads.
- The Agent deletes the ROM and generated files at the end of the job by default
  (`--keep-input` is an explicit, warned opt-in) and reports the cleanup in the
  result.
- The frontend never asks for or stores an Apple ID, password, 2FA code,
  certificate, provisioning profile or device UDID.
- No password authentication anywhere; no port is opened on the Windows PC;
  ssh's own verbose output is not written to the configuration or logs.
- Only legally owned, decrypted ROMs may be used. The project provides no ROMs,
  keys or acquisition help, and the IPA must not be redistributed.
