# Desktop Builder and macOS Build Agent

3ds2apple turns a game into an app ahead of time: 3dsrecomp translates the
game's ARM/Thumb/VFP code into C, the iOS SDK's clang compiles that C for
`arm64-apple-ios`, and `xcodebuild` links it with the SwiftUI shell and the
Zakuro runtime into an unsigned IPA. The compilation and linking steps need
macOS and Xcode.

A user of this project may not own a Mac. They may run Windows or Linux only,
while the macOS part can happen on a machine the user already controls: a local
macOS VM, a Mac on the LAN, or a cloud Mac rented for the project. The
**Builder** is a desktop application for Windows and Linux that drives the AOT
build on such a host through a small **Build Agent**, then receives the
unsigned IPA, its SHA256 and its manifest.

> **Status: first implementation.** The shared core, the CLI (`zkb`), the
> macOS Build Agent and the Windows frontend (`builder-windows`) live in this
> directory and run end-to-end on Linux against the Agent's scripted fake-build
> mode. The SSH binding, job queue with one build slot, NDJSON log streaming,
> cancellation, input/build-product cleanup and verified artifact download are
> implemented and covered by tests; the Windows executable has additionally been
> run on Windows 11, including a build over real SSH to an Agent. The optional
> HTTP+SSE binding, the graphical desktop shells and a run of the real macOS
> pipeline from this repository are not part of this slice; see
> [Running it today](#running-it-today).
>
> A Linux frontend (`builder/linux`, binary `3ds2apple-builder`) wraps that CLI
> for a Linux workstation: it discovers a local QEMU/KVM macOS VM's forwarded
> SSH port, pairs the host and runs the build end to end. See
> [builder/linux/README.md](linux/README.md).
>
> The build itself is done by the existing scripts in [`scripts/`](../scripts/);
> the Builder does not re-implement the pipeline.

The design is split across these documents:

| Document | Contents |
|---|---|
| [PROTOCOL.md](PROTOCOL.md) | Wire protocol v1: transports, authentication, jobs, logs, cancellation, artifact download, isolation, failure semantics |
| [UX.md](UX.md) | User flows: add a build host, select a ROM, build, read progress, collect and install the IPA |
| [STACK.md](STACK.md) | Technology choice (Rust/Tauri vs Python/CLI), repository layout, packaging, release rules |

## Running it today

Everything below runs from `builder/`:

```bash
cargo test --workspace          # protocol fixtures, fake-agent E2E, state machine
cargo build --workspace         # binaries: target/debug/{zkb,builder-agent}
```

On the Mac (the Build Agent host):

```bash
builder-agent init --checkout ~/src/3ds2apple
builder-agent serve              # daemon on <data root>/agent.sock
# ssh-dispatch starts the daemon automatically when the SSH key is used
```

On the Windows/Linux machine with the ROM, either the `zkb` CLI or — on
Windows — the dedicated frontend (same configuration file and host profiles):

```bash
# 1. Pair the host once. This creates a dedicated SSH key, prints its public
#    key, the exact restricted authorized_keys line and the host key
#    fingerprint; the fingerprint is verified with --yes or --fingerprint.
zkb host add --name office --ssh builder@mac-mini.local

# 2. Check the host (the Agent's doctor report).
zkb host test office

# 3. Build, stream the log, download and verify the unsigned IPA.
zkb build --host office --rom "./ROM/Pokemon Y.cci" \
          --name pokemon-y --display-name "Pokemon Y" --out ./out

# 4. Reattach, inspect, download again, cancel or clean up.
zkb status --host office <job-id> --follow
zkb logs   --host office <job-id> --follow
zkb download --host office <job-id> --out ./out --verify
zkb cancel  --host office <job-id>
zkb jobs    --host office
zkb delete  --host office <job-id>
```

`zkb build` prints the IPA path, its SHA256 and the manifest location on its
last lines and exits `0`; a failed build exits `1` with the failing stage, the
Agent's hint and the last log lines (`--json` emits the protocol objects).

On a Linux workstation the frontend adds VM discovery, pairing and a build
wrapper over the same client:

```bash
3ds2apple-builder vm discover                    # find the VM's forwarded SSH port
3ds2apple-builder vm setup --name cachyos-vm --user builder
3ds2apple-builder build --host cachyos-vm --rom "./ROM/Pokemon Y.cci"
3ds2apple-builder install-guide --ipa <downloaded.ipa>
```

See [builder/linux/README.md](linux/README.md) for the CachyOS + macOS VM
walkthrough, headless usage and troubleshooting. The frontend shells out to
`zkb` for protocol work, so the two clients behave identically.

On Windows the same flow is available from `builder-windows.exe`, which adds a
guided first-run session (host pairing, ROM selection, progress, result and the
Sideloadly/AltStore guide) and Windows-specific handling for long paths, CJK
names, the OpenSSH client and console encoding:

```powershell
cd builder
cargo build -p builder-windows --release
.\target\release\builder-windows.exe            # guided session
.\target\release\builder-windows.exe doctor      # check this PC
.\target\release\builder-windows.exe self-test   # no Mac needed
```

See [windows/README.md](windows/README.md) for the full command reference and
the Windows packaging/verification details.

No Mac is needed to exercise the protocol path: the Agent's `--fake-build`
mode replaces only the script execution, and
[`tests/e2e/local_fake_agent.sh`](tests/e2e/local_fake_agent.sh) runs the whole
flow (host add, upload, queue, events, artifact download, SHA256 check,
cleanup) on Linux.

| Piece | Implemented now | Verified where |
|---|---|---|
| `builder/core` | protocol types, framing, versioning, validation, hashing, SSH/local transports, client state, config | `cargo test -p builder-core`, golden fixtures |
| `builder/windows` | Windows frontend: guided session, `doctor`/`self-test`, build/status/logs/cancel/download/jobs, install guide, long-path and CJK handling, portable packaging | `cargo test -p builder-windows` (unit + real-Agent E2E on Linux); run on Windows 11 incl. a build over SSH |
| `builder/cli` (`zkb`) | `host add/list/test/remove`, `build`, `status`, `logs`, `cancel`, `download`, `jobs`, `delete`, `doctor`, `config` | `cargo test -p builder-cli` (E2E against the real Agent) |
| `builder/agent` | daemon + stdio sessions, `ssh-dispatch` forced command, queue with one build slot, store/recovery, NDJSON events, cancellation with process groups, cleanup, artifact verification, `doctor`, `gc`, fake-build mode | unit tests + CLI E2E on Linux |
| `builder/linux` (`3ds2apple-builder`) | Linux frontend over `zkb`: QEMU/KVM VM SSH port discovery, host pairing with fingerprint confirmation, build wrapper with local SHA256 re-verification, install guide, doctor | `cargo test -p builder-linux` (unit, local integration, fake-agent E2E) |
| Real macOS pipeline | script stages and output parsing implemented; not yet exercised on a Mac from this repository | pending a macOS run |
| HTTP+SSE binding | not implemented (SSH is the only binding in this slice) | — |

Remaining gaps in this slice, in addition to the deferrals in
[PROTOCOL.md](PROTOCOL.md) §15: the HTTP binding, `transport.mode: "path"`,
`heartbeat` events, automatic `input_timeout` expiry, a Builder-embedded source
revision pin (the CLI sends one only with `--expected-revision`), the
graphical desktop shells (the Linux and Windows frontends are CLI-first today;
both Tauri GUIs remain design-only, see
[linux/README.md](linux/README.md#gui) and
[windows/README.md](windows/README.md#gui-status)) and a run of the real macOS
pipeline from this repository.

## Why a Mac is still needed

The AOT pipeline is:

```text
user's ROM (local only)
   └─ 3dsrecomp ──► generated C
                     └─ clang -target arm64-apple-ios ──► libgame.a
Zakuro source ──► cargo --target aarch64-apple-ios ──► libzakuro_ios.a
libgame.a + libzakuro_ios.a + SwiftUI shell ──► xcodebuild ──► .app ──► .ipa
```

- 3dsrecomp can run on Linux or macOS, but the generated C still has to be
  compiled and linked with Apple's toolchain.
- iOS apps are Mach-O bundles built by `xcodebuild`; signing and installation
  are a separate, user-controlled step.
- Rebuilding the shell and re-linking the runtime on every game is the part
  that must happen on macOS. A future "prebuilt shell + cross-compiled game
  module" spike may remove some of that, but it is a separate investigation
  (the cross-compile spike), not the v1 path.

The Builder makes that macOS step a background service on a machine the user
already owns, driven from the OS the user actually works on.

## Architecture

```text
┌───────────────────────────────────────────────┐        ┌──────────────────────────────────────────────┐
│ Builder (Windows or Linux desktop)            │        │ macOS Build Agent (user-owned host)          │
│                                               │        │                                              │
│  ┌─────────────┐   ┌────────────────────────┐ │        │  ┌────────────────────────────────────────┐  │
│  │ GUI         │   │ shared core            │ │        │  │ agent daemon                           │  │
│  │ (Tauri)     │──►│ protocol · transports  │ │  (1)   │  │  job queue · job runner · cleanup      │  │
│  └─────────────┘   │ client state · hashing │ │────────►│  │  build slots · logs · artifacts        │  │
│  ┌─────────────┐   │ config · keychain      │ │        │  └──────────────┬─────────────────────────┘  │
│  │ CLI         │──►│ log redaction          │ │  (2)   │                 │ exec (no shell string)        │
│  └─────────────┘   └────────────────────────┘ │◄────────│  ┌──────────────▼─────────────────────────┐  │
│                                               │        │  │ existing scripts/ pipeline             │  │
│  user's ROM (never uploaded to a project      │        │  │ build-recomp-ios.sh                    │  │
│  server; sent only to the user's own host)    │        │  │ build-linked-ios-lib.sh                │  │
└───────────────────────────────────────────────┘        │  │ build-game-ipa.sh (+ package-ipa.sh)   │  │
                                                         │  └──────────────┬─────────────────────────┘  │
                                                         │                 │                            │
                                                         │  job dir: input/ logs/ out/  (deleted after)│
                                                         └──────────────────────────────────────────────┘
                                                                          │ (3) unsigned IPA + manifest + SHA256
                                                                          ▼
                                                         Builder verifies SHA256, shows install steps
                                                                          │
                                                                          ▼
                                                         Sideloadly / AltStore / SideStore
                                                         (user's own Apple ID, on the user's machine)
                                                                          │
                                                                          ▼
                                                                    iPhone / iPad
```

Data flow:

1. The Builder uploads the user's ROM (and optional supplementary files such as
   a keys file) to the user's own Build Agent over an authenticated channel,
   together with a build request. The Agent never contacts a project-operated
   server, because the project does not run one.
2. The Agent runs the existing AOT scripts with per-job inputs, logs and
   outputs; build products go to the checkout's gitignored `build/` tree under
   the job's game name and are removed at the end of the job. Staged progress
   plus a line log stream back to the Builder.
3. The Agent returns the unsigned IPA, manifest and SHA256, then deletes the
   ROM, any keys and the generated code from its job directory (default; see
   [security](#security-and-privacy)). The Builder verifies the checksum and
   leaves signing/installation to the user on their own machine.

### Components

| Component | Planned location | Runs on | Responsibility |
|---|---|---|---|
| **Shared core** | `builder/core/` | All platforms | Protocol types and versioning, transports, job client state machine, hashing/verification, host profiles, secret storage, log redaction. No UI, no process execution. |
| **CLI** | `builder/cli/` | Windows, Linux, macOS | `zkb` (working name): add/test build hosts, start a build, tail progress and logs, download and verify the IPA, show doctor output. The reference client and the Linux MVP. |
| **Windows frontend** | `builder/windows/` | Windows 10/11 | CLI-first desktop frontend over the shared core: guided session, host profiles, transfer/build progress, log streaming, artifact page and install guide; a Tauri graphical shell over the same engine is still design only. |
| **Linux frontend** | `builder/linux/` | Linux desktops and headless | `3ds2apple-builder`: CLI frontend over `zkb` with QEMU/KVM VM SSH discovery, host pairing, build wrapper, local SHA256 re-verification and install guide, packaged for Arch/CachyOS and Debian/Ubuntu. A Tauri GUI over the shared `builder/ui` is still planned for both desktops. |
| **Build Agent** | `builder/agent/` | macOS (Apple Silicon or Intel) | Long-lived daemon plus `ssh` dispatch and CLI: pairing, `doctor` toolchain checks, job queue with build slots, per-job runner that invokes the existing scripts, NDJSON logs, cancellation, cleanup, artifact serving, data-root GC. |
| **Cross-compile spike** | `builder/cross/` | Any (research) | Investigates whether a prebuilt shell plus a cross-compiled game module can remove macOS from the loop. Not shipped in v1; see [README.md](README.md). |
| **Tests and fixtures** | `builder/tests/` | All platforms | Protocol fixtures, a scriptable fake Agent, conformance/chaos tests, and the Linux → macOS end-to-end script. |

The frontends and CLI are thin clients over the same Rust library; the Build
Agent is a separate binary from the same workspace. The Windows frontend is
CLI-first today (a guided session plus commands) and shares its configuration
file with `zkb`. See [STACK.md](STACK.md) for the full directory layout.

### How a build maps to the existing scripts

The Agent does not re-implement the pipeline. It validates the job, prepares
the toolchain and calls the same scripts a user would call by hand
(see [docs/build.md](../docs/build.md), [scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md)):

| Stage | Agent action (working directory: the macOS source checkout) | Output consumed |
|---|---|---|
| `preparing` | version/toolchain/disk checks; cached `scripts/build-zakuro-ios.sh` for the pinned checkout (once per Agent install or after an update) | `third_party/zakuro`, `build/ios/libzakuro_ios.a` |
| `recompiling` | `scripts/build-recomp-ios.sh <job>/input/rom.<ext> <name> --auto-serial` | `build/game/<name>/code/librecomp.a`, recomp metadata |
| `linking` | `scripts/build-linked-ios-lib.sh <name> --title-id <id> --isolated-target` (title ID from the request or from the recomp metadata) | `build/ios/<name>/{libzakuro_ios.a,libgame.a,build-info.txt}` |
| `packaging` | `MOLTENVK_FRAMEWORK=<agent cache>/…/MoltenVK.framework scripts/build-game-ipa.sh <name> --display-name <name> --out-dir <job>/out --ipa-name <slug>-AOT` | `IPA/<slug>-AOT.ipa`, `build/ios/<name>/manifest.txt` |
| `verifying` | recompute the IPA SHA256, check the manifest (title ID, revisions, sizes), check the app contains linked code | `out/artifact.json` |

Constraints that follow from the scripts:

- The Agent passes arguments as arrays, never as a shell string. The user's
  display name and ROM file name are validated/sanitised by the Agent; the game
  `name` must already satisfy the scripts' name rule (`[A-Za-z0-9._-]`).
- `-lzakuro_ios` must stay before `-lgame`; the Agent must not reorder or
  rewrite the link flags. `build-game-ipa.sh` already enforces this.
- The job may omit the title ID: `build-linked-ios-lib.sh` reads it from the
  recomp output. The Agent reports the title ID it used in the artifact
  manifest.
- MoltenVK is a third-party binary and is never committed. The Agent downloads
  it once into its own cache with the pinned version and SHA256 from
  [METAL.md](../ios/zakuro-ios/METAL.md) §4.2, then passes
  `MOLTENVK_FRAMEWORK` for the packaging step.
- The shipped scripts keep their behaviour; the Agent only chooses arguments
  and environment. If a script's contract changes, the Agent version must
  change with it (see [PROTOCOL.md](PROTOCOL.md) compatibility rules).

## Supported matrix

| Piece | Supported target | Notes |
|---|---|---|
| Builder frontend/CLI | Windows 10 22H2+, Windows 11 (x86_64; arm64 experimental) | `builder-windows.exe` and `zkb.exe` are single executables with no runtime dependency. A future graphical shell also needs WebView2 (preinstalled on Windows 10/11). |
| Builder frontend/CLI | Linux x86_64 (Arch/CachyOS, Debian/Ubuntu 22.04+, Fedora 38+); aarch64 experimental | The implemented CLI frontend has no GUI dependencies; the planned GUI needs WebKitGTK 4.1. |
| Builder (optional) | macOS 13+ | Useful when building on the same Mac; same CLI/GUI. |
| Build Agent | macOS 14 Sonoma or newer, Apple Silicon or Intel | Reference tested configuration: macOS 14.8, Xcode 16.4 / iOS 18.5 SDK, 4 vCPU, 8 GB RAM (the configuration the per-game pipeline has been exercised on). Headless is enough; no Apple ID, no USB device, no signing. |
| Agent toolchain | Xcode 16.x with the iOS SDK, Rust stable with `aarch64-apple-ios`, `xcodegen`, Python 3, git, network access for the first provisioning | `builder-agent doctor` reports each item; the Builder refuses to start a job when a required item is missing. |
| Agent disk | ~20 GB free per concurrent build (generated C, objects, archives, Xcode data); 30 GB+ recommended | Jobs are serialised by default (one build slot) because the reference host has 8 GB RAM. |
| Agent network | SSH (OpenSSH server, Remote Login) and/or a loopback HTTP listener | SSH is the default for a remote host; the HTTP listener is for same-machine use or an SSH tunnel. |
| Install / signing | Windows: Sideloadly, AltStore, SideStore. Linux: sign on a Windows/macOS machine; Linux-native signing is out of scope for v1 | The Builder never handles Apple IDs or device provisioning. |
| Device | iPhone/iPad, iOS 16+ | Same requirement as the shell and per-game builds. |

"Supported" in this matrix means "target of the design and part of the v1
acceptance tests", not "already verified". The Windows and macOS items that
cannot be validated from a Linux development host are listed explicitly in
[README.md](README.md).

### Deployment shapes

| User situation | Builder | Agent | Transport |
|---|---|---|---|
| Linux workstation + local macOS VM | Linux GUI or CLI | Agent inside the VM (`ssh -p <forwarded-port>`) | SSH to the VM |
| Windows PC + Mac mini on the LAN | Windows GUI | Agent on the Mac | SSH over LAN |
| Windows/Linux PC + rented cloud Mac | Windows/Linux GUI | Agent on the cloud Mac | SSH over the internet |
| One Mac, everything local | macOS CLI/GUI | Agent on the same machine | loopback HTTP or SSH to localhost |
| CI or scripted rebuild | CLI | Agent | SSH, non-interactive with `--json` |

In every shape the ROM travels only from the Builder to the Agent the user
chose; the project operates no server in the path.

## Security and privacy

The Builder and Agent touch the user's copyrighted game data and, potentially,
the user's build machine. The design keeps the blast radius at "the user's own
machines".

### ROM stays under the user's control

- The project runs **no build service** and collects **no telemetry**. The
  Builder contains no analytics, crash uploads or "share build" feature.
- A ROM is sent only to the Build Agent the user configured, over an
  authenticated channel (SSH key or token + TLS). The Builder refuses to send
  it anywhere else; there is no default/global endpoint.
- The Agent stores the ROM only in the job input directory and deletes it when
  the job reaches a terminal state (success, failure, cancellation, or Agent
  restart recovery). Deletion is the default and is reported back to the
  Builder.
- "Keep inputs on the host" is an explicit opt-in that shows a warning and
  requires per-host confirmation. "Path mode" (Agent reads a file already on
  the Mac) copies the file into the job directory; the original is never moved
  or deleted.
- The Builder deletes its own staging copy of the ROM after upload completes
  (success, cancel or error), and never writes ROM contents into its config,
  logs or history.
- Cloud Mac caveat: if the user rents a cloud Mac, the provider can access that
  host by nature. The UI says so at host-setup time and recommends disk
  encryption, a dedicated macOS user and job cleanup. The project does not
  operate and cannot vouch for third-party hosts.

### Deleting derived data

- Generated C, object files, archives and the generated Xcode project are
  job work products. They are deleted at the end of the job by default.
- The unsigned IPA is the only intended output. It contains game-derived code:
  it is produced for the user, stays on the user's machines, and is never
  uploaded anywhere. The UI states that it must not be redistributed.
- The Agent keeps the IPA in `jobs/<id>/out/` until the retention period
  expires (default 7 days), the user deletes the job, or a configured
  "delete after a verified download" policy removes it. `job delete` and
  `builder-agent gc` purge job data on demand.
- Logs are kept for debugging but never contain ROM bytes or key material.
  Error log tails are the last lines of the build output; the Builder can
  export a redacted log for bug reports.

### No Apple ID, no device, no signing

- The Builder never asks for, stores or transmits an Apple ID, Apple password,
  app-specific password, certificate, provisioning profile, device UDID or
  two-factor code.
- The Agent does not sign, install or provision anything. It only produces the
  unsigned IPA.
- Signing and installation are a documented manual step on the user's Windows
  or macOS machine (Sideloadly, AltStore, SideStore) with the user's own Apple
  ID; the project cannot and does not automate it.
- Trusting the developer certificate on the device is also a user step; the
  documentation explains where that setting is, but the Builder does not touch
  the device.

### Keys and other supplementary files

- The current pipeline builds from a decrypted `.3ds`/`.cci`; it does not read
  a keys file. The protocol nevertheless has an optional supplementary input
  role so a user can hand a keys file to their own Agent for future/tooling
  needs without a protocol change.
- Such files get the same treatment as the ROM: job-scoped, `0600`, uploaded
  only to the configured Agent, deleted at job end, never logged, never
  included in artifacts.
- The project does not provide, generate or help obtain keys; no download or
  key-derivation feature exists in the Builder.

### Network exposure

- **SSH transport (default for remote hosts):** no new listening port. The
  Builder uses the system OpenSSH client and a **dedicated key** the user adds
  to the macOS account's `authorized_keys` with a forced command
  (`builder-agent ssh-dispatch`) and restricted options, so the key can only
  run the Agent subcommands and cannot open a shell, forward ports or read the
  user's files. Host keys are verified through a profile-private `known_hosts`
  file; the pairing UI shows the fingerprint.
- **HTTP transport:** the Agent binds `127.0.0.1` by default; binding anything
  else requires TLS and a token. The token is printed once at pairing, stored
  in the OS credential store on the Builder side (Windows Credential Manager /
  libsecret / macOS Keychain) and stored only as a hash in the Agent config.
  Certificates are pinned by SHA256 fingerprint recorded at pairing; plain
  HTTP is refused for non-loopback addresses. Access through an SSH tunnel is
  the recommended way to reach a remote Agent over HTTP.
- No password authentication anywhere; no agent forwarding; no port forwarding
  is configured by the Builder unless the user explicitly opens an SSH tunnel.
- The Agent rejects unknown job ids, path traversal and symlinked inputs,
  validates file names/slugs, enforces a size limit, and runs only the known
  build scripts — never an arbitrary command.

### Legal and third-party notices

- Only legally owned, decrypted ROMs may be used. The Builder's first-run text
  and the build review screen repeat this; it provides no acquisition,
  decryption or key-distribution help.
- macOS hosts must be legally licensed (Apple hardware per Apple's licence; a
  cloud Mac is rented under the user's agreement). The project ships no macOS
  installation or licence-bypass instructions.
- The unsigned IPA contains game-derived code and is not distributed by the
  project; no ROM, generated C, IPA, keys, static library or credential is
  committed to the repository.

## Non-goals

- **No hosted or multi-tenant build service.** The project will not run a
  central build farm, accept ROMs, or store user game data.
- **No ROM/keys storage, sharing or acquisition.** No library management, no
  game downloads, no decryption feature.
- **No signing, provisioning or device management.** No Apple IDs, UDIDs,
  certificates or profiles; no automation of Sideloadly/AltStore.
- **No App Store path.**
- **No fully Mac-free build in v1.** The cross-compile route is a research
  spike only; the shipped path requires a macOS host
  (VM, LAN Mac or cloud Mac) at least for the compile/link/package steps.
- **No CI builds of game data.** Public CI builds only ROM-free parts
  (shell, runtime, Builder tests) as today.
- **No support for encrypted ROMs, updates/DLC or multi-title jobs in v1.**
  One job produces one per-game IPA from a decrypted base-game ROM.
- **No Xcode installation/management, no remote Xcode GUI, no device
  debugging, no Instruments.** The Agent is a headless build executor.
- **No automatic updates in v1.** The Agent and Builder are versioned and
  report their versions; updating is a manual download/replace.

## Related documentation

- [docs/build.md](../docs/build.md) — the manual macOS build the Agent automates.
- [scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md) — per-game AOT build commands,
  outputs and failure diagnostics.
- [ios/zakuro-ios/METAL.md](../ios/zakuro-ios/METAL.md) — the renderer/presenter
  build path and the MoltenVK release the Agent caches (§4.2).
- [README.md](../README.md) — project overview, BYO-ROM policy and licensing.
