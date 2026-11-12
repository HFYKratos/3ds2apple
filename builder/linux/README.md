# Linux Builder frontend

`3ds2apple-builder` is the Linux frontend for the 3ds2apple Builder. It takes a
legally owned, decrypted `.3ds`/`.cci` from a Linux workstation, drives the AOT
build on a macOS host the user controls (a local macOS VM, a Mac on the LAN or a
rented cloud Mac) through the 3ds2apple Build Agent, then downloads and verifies
the unsigned IPA and prints the signing/installation steps.

It is designed around the project's own development setup — CachyOS/Arch with a
QEMU/KVM macOS VM — but works with any Linux distribution and any reachable
macOS host.

> **Status:** the CLI frontend is implemented and covered by unit tests, local
> integration tests and an end-to-end test against the real Build Agent in
> fake-build mode. The Tauri GUI shell is not part of this release (see
> [GUI](#gui)). The real macOS pipeline and SSH pairing against a live macOS VM
> still need a first run on real hardware; see
> [What is verified](#what-is-verified).

## What it is and is not

- **It is** a thin, Linux-specific layer over the shared `zkb` client and the
  `builder-core` library. Protocol work, uploads, resumable transfer, log
  streaming, cancellation, artifact download and SHA256 verification are the
  shared implementation; this frontend does not re-implement them.
- **It is** the place where a Linux user gets help with what is specific to
  Linux: finding the local VM's forwarded SSH port, pairing the host with an SSH
  key, making ROM selection a one-liner, re-verifying the downloaded IPA and
  showing the signing steps.
- **It is not** an emulator, a ROM tool, a signing tool or an installer. It
  never asks for an Apple ID, password, 2FA code, UDID, certificate or
  provisioning profile, and it never uploads anything to a project server
  (there is none).

The AOT pipeline needs macOS because the generated C is compiled with Apple's
clang and linked by `xcodebuild`; see
[`builder/README.md`](../README.md) for the full picture and the Build Agent.

## Requirements

| Side | Requirement |
|---|---|
| Linux workstation | x86_64 (aarch64 builds from source; untested), OpenSSH client (`ssh`, `ssh-keygen`, `ssh-keyscan`), ~1 GB disk for a downloaded IPA |
| Network | SSH from the workstation to the macOS host (local forwarded port, LAN or internet) |
| macOS host | The user's own macOS (VM, Mac or cloud Mac) with the toolchain and the Build Agent installed; see [`builder/README.md`](../README.md) and [`scripts/AOT_BUILD.md`](../../scripts/AOT_BUILD.md) |
| Game file | A decrypted base-game `.3ds`/`.cci` the user legally owns. The project provides no ROM, keys, system files or download service. |

Both binaries must be available: `3ds2apple-builder` and the shared `zkb`
client. Put `zkb` next to the frontend binary, on `PATH`, or point `--zkb` (or
`$ZKB_BIN`) at it. Packages install both (see
[packaging/README.md](packaging/README.md)).

## Quick start: CachyOS + macOS VM

These are the steps for the project's reference setup: CachyOS (or any Arch
derivative) with a macOS VM running under QEMU/KVM and user-mode networking that
forwards a host port to the VM's SSH port.

### 1. macOS side (once)

Inside the macOS VM:

1. Enable SSH: **System Settings → General → Sharing → Remote Login** (allow
   your login user).
2. Install the Build Agent: copy the `builder-agent` binary to
   `~/.local/bin/builder-agent` (see [`builder/README.md`](../README.md)) and
   initialize it once with the checkout the build scripts should run in:

   ```bash
   builder-agent init --checkout ~/src/3ds2apple
   builder-agent doctor --json     # should report ready: yes
   ```

3. Make sure the VM's SSH port is reachable. With QEMU user-mode networking the
   usual rule is `-netdev user,id=net0,hostfwd=tcp::2222-:22`, which exposes
   `127.0.0.1:2222` on the Linux host. The frontend finds this rule
   automatically; no manual port bookkeeping is needed if it is present.

The macOS VM must be legally licensed; the project ships no macOS images or
licence-bypass instructions.

### 2. Pair the host (once)

```bash
# See what is reachable before changing anything.
3ds2apple-builder vm discover

# Pair the only SSH endpoint found. It shows the host-key fingerprints, then
# runs `zkb host add`: a dedicated Ed25519 key is created for this profile.
3ds2apple-builder vm setup --name cachyos-vm --user builder
```

`vm discover` looks for endpoints in this order:

1. explicit environment overrides (`ZKB_VM_SSH`, `ZKB_VM_HOST`/`ZKB_VM_PORT`);
2. QEMU/KVM `hostfwd` rules visible in `/proc/<pid>/cmdline` (any running
   `qemu-system-*` process);
3. with `--scan`, the default localhost port list (`2222`, `2223`, `2224`,
   `2200`, `2201`, `2022`, `10022`, `8022`, `22222`).

Each candidate is probed for an `SSH-…` banner and ranked, so a stale or
non-SSH port is reported as such instead of being paired. `vm setup` refuses to
guess when several SSH endpoints are visible; choose one with
`--host/--port`.

Verify the printed SHA256 fingerprint inside the VM, then confirm:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

`vm setup` accepts `--yes` (trust the listed keys) or
`--fingerprint SHA256:...` (pin one). Interactively it asks; in scripts and
with `--no-input`, pass one of the two flags — nothing is ever trusted by
default.

Pairing prints the exact `authorized_keys` line to add on the Mac. It uses a
forced command and `restrict`, so the key can only run the Build Agent:

```text
command="/Users/<user>/.local/bin/builder-agent ssh-dispatch",restrict ssh-ed25519 AAAA... 3ds2apple-builder <profile-id>
```

The key cannot open a shell or forward ports, and the frontend never edits
`authorized_keys` remotely. The host key is stored in a profile-private
`known_hosts` file, not the system one; a changed host key is a hard error.
`vm setup --test` runs `zkb host test` immediately after pairing; it only
succeeds once that `authorized_keys` line has been added on the Mac (or when
re-pairing an already authorised host).

Check the host when the Agent is installed:

```bash
3ds2apple-builder doctor --host cachyos-vm
# or: zkb host test cachyos-vm
```

### 3. Build a game

```bash
3ds2apple-builder build \
  --host cachyos-vm \
  --rom "$HOME/ROM/Pokemon Y.cci" \
  --name pokemon-y --display-name "Pokemon Y"
```

With `--rom` omitted in a terminal, the frontend offers the `.3ds`/`.cci` files
it finds in the current directory, `./ROM`, the checkout's `ROM/`, `~/ROM` and
`--rom-dir` directories. `--host` can be omitted when exactly one host is
configured. The ROM is hashed and uploaded only to the configured macOS host,
and the Agent deletes it when the job ends (default); `--keep-input` is an
explicit opt-in with a warning.

The build streams the Agent's stage/log output. When it finishes, the frontend
recomputes the downloaded IPA's SHA256 and checks it against the Agent's
`manifest.txt` before printing success:

```text
Build succeeded
  game:     Pokemon Y (pokemon-y)
  ipa:      /home/u/.local/share/3ds2apple/builder/artifacts/pokemon-y/pokemon-y-AOT.ipa
  size:     96.4 MiB
  sha256:   e3b0c442…b855
  manifest: …/manifest.txt
  verified: local SHA256 matches the Agent's manifest
```

Artifacts are collected under
`$XDG_DATA_HOME/3ds2apple/builder/artifacts/<game>/` by default (`--out`
overrides). The IPA is unsigned and contains game-derived code: it is produced
for the user, must not be redistributed, and signing/installation is a manual
step on a Windows or macOS machine.

### 4. Sign and install

```bash
3ds2apple-builder install-guide --ipa \
  "$HOME/.local/share/3ds2apple/builder/artifacts/pokemon-y/pokemon-y-AOT.ipa"
```

The guide prints the file's size and SHA256, the `sha256sum` check, and the
Sideloadly/AltStore steps. Official Sideloadly/AltStore builds do not run on
Linux: copy the IPA to a Windows or macOS machine and sign it there with your
own Apple ID. A free Apple ID certificate expires after 7 days; that is Apple's
limit, not the Builder's.

## Command reference

| Command | Purpose |
|---|---|
| `status` (default) | Shared client, configured hosts, detected VM endpoints, next commands |
| `vm discover [--scan] [--ports 2222,2200-2205] [--no-probe] [--json]` | List and probe candidate SSH endpoints |
| `vm setup --name NAME [--host H] [--port P] [--user U] [--key PATH] [--yes \| --fingerprint SHA256:…] [--test]` | Verify and pair a host through `zkb host add` |
| `build [--host NAME] [--rom PATH \| interactive picker] [--out DIR] [options]` | Build, stream, download and verify one game |
| `doctor [--host NAME] [--probe] [--json]` | Check client, OpenSSH, config, key permissions, VM, disk and optionally the host |
| `install-guide [--ipa PATH]` | Print signing/installation steps, hashing the IPA when given |
| `zkb ARGS…` | Passthrough to the shared client (`host`, `status`, `logs`, `cancel`, `jobs`, `download`, …) |
| `--help`, `--version` | Command help and version |

Global options:

| Option | Meaning |
|---|---|
| `--zkb PATH` | Path of the shared client (default: `$ZKB_BIN`, a sibling binary, `$PATH`) |
| `--config PATH` | Builder config file (default: the shared client's location) |
| `--json` | JSON for this frontend's commands, NDJSON from the shared client |
| `--no-input` | Never prompt; missing choices are usage errors |

`build` also accepts the shared client's flags: `--name`, `--display-name`,
`--bundle-id`, `--title-id`, `--no-moltenvk`, `--hardware-renderer`, `--clean`,
`--keep-input`, `--expected-revision`, `--no-download`, `--allow-any-file` and
`--rom-dir` (repeatable). `zkb build --help` documents the underlying flags.

### Exit codes

The codes match the shared client so scripts can treat both the same:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | the build failed (the Agent's stage, hint and last log lines are printed) |
| 2 | usage or configuration error |
| 3 | the macOS host, SSH connection or Agent failed / is not ready |
| 4 | the build was canceled |
| 5 | local I/O error on the Linux machine |
| 64 | internal error |

### Headless and scripted use

Every command is non-interactive when `--no-input` is set or stdin is not a
terminal; nothing prompts for a password. `--json` makes stdout
machine-readable, and exit codes are stable. Pairing still needs either
`--yes` or `--fingerprint`, and adding the `authorized_keys` line on the Mac is
a one-time manual step by design.

```bash
# Example CI-style rebuild of one game (no prompts, no GUI)
set -euo pipefail
3ds2apple-builder --json build --host cachyos-vm --no-input \
  --rom "/src/ROM/Pokemon Y.cci" --name pokemon-y --out ./out > build.ndjson
sha256sum ./out/pokemon-y-AOT.ipa    # compare with the printed manifest
```

Environment variables:

| Variable | Meaning |
|---|---|
| `ZKB_VM_SSH` | Endpoint override `[user@]host[:port]`, highest priority |
| `ZKB_VM_HOST`, `ZKB_VM_PORT`, `ZKB_VM_USER` | Individual endpoint overrides |
| `ZKB_VM_KEY` | Existing private key instead of a dedicated one |
| `ZKB_BIN` | Path of the shared `zkb` client |
| `ZKB_CONFIG_DIR`, `ZKB_DATA_DIR` | Shared client config/data directories |
| `ZKB_ROM_DIR` | Extra directory searched for ROMs |

### How the VM SSH discovery works

The frontend reads `/proc/<pid>/cmdline` for running QEMU/KVM processes and
parses user-mode networking rules such as:

```text
-netdev user,id=net0,hostfwd=tcp::2222-:22
-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22
-netdev user,id=net0,hostfwd=tcp:0.0.0.0:2222-:22
```

The bound address is normalized (empty / `0.0.0.0` / `[::]` / `localhost` →
`127.0.0.1`), rules whose guest port is 22 rank first, and each candidate is
probed by opening a TCP connection and reading the SSH banner. It also picks up
the VM name from `-name guest=…` when present. UDP forwards and unsupported
rules are reported and ignored.

If the VM uses bridged networking, `passt`, libvirt NAT or a different
forwarding setup, discovery may find nothing. In that case pass the endpoint
explicitly:

```bash
ZKB_VM_SSH=builder@127.0.0.1:2222 3ds2apple-builder vm setup --name cachyos-vm
# or
3ds2apple-builder vm setup --name cachyos-vm --host 192.168.1.40 --port 22 --user builder
```

`--host` without `--port` uses SSH port 22; `--port` without `--host` assumes a
local forward on `127.0.0.1`.

Nothing in the VM's disk, OpenCore or network configuration is modified by the
frontend; it only reads process metadata and opens TCP connections to endpoints
the user already controls.

## GUI

The planned desktop GUI is a Tauri 2 shell over the shared TypeScript UI
(`builder/ui`), reusing the same frontend logic. It is **not part of this
release**: the environment used to build and verify this slice has no
WebKitGTK development packages and no access to the Tauri crates, so a GUI could
not be compiled or tested here. Rather than ship unverified GUI code, the CLI is
the supported Linux frontend and is complete for the workflow above.

When the GUI lands it will be packaged as AppImage/deb/rpm; the required
packages and commands are listed in
[packaging/README.md](packaging/README.md#appimage--gui-note). The CLI remains
available for headless and server hosts, and `builder-agent --fake-build` is
the GUI's development backend.

## Packaging

Arch/CachyOS: [`packaging/PKGBUILD`](packaging/PKGBUILD)
(`makepkg -si`). Debian/Ubuntu: `packaging/build-deb.sh` produces a `.deb` and a
portable tarball plus `SHA256SUMS`. Single-file musl binaries and AppImage
notes: [packaging/README.md](packaging/README.md). No binary, ROM, generated C,
static library, IPA or credential is committed to the repository.

## What is verified

Verified in this repository on Linux (Ubuntu 26.04, Rust 1.99.1):

- `cargo check`, `cargo fmt --check`, `cargo clippy --workspace --all-targets
  -- -D warnings`, `cargo test --workspace` (the workspace now includes
  `builder-linux`; 74 new tests).
- Unit tests for: QEMU `hostfwd` parsing and `/proc` scanning, SSH banner
  probing against real local sockets, endpoint/port parsing, host-key
  confirmation, argument construction, ROM selection and hashing, result
  parsing and exit-code mapping.
- Local integration tests for the real binary: status, `--json` output, doctor,
  VM discovery, pairing refusals, build usage errors, install guide, `zkb`
  passthrough and exit codes.
- An end-to-end test and a shell wrapper
  ([`tests/local_fake_agent.sh`](tests/local_fake_agent.sh)) against the real
  Build Agent in fake-build mode: pair, build, stream, download, SHA256
  verification, install guide, Agent-side ROM cleanup, failure exit code 1,
  cancellation exit code 4 and NDJSON stdout in `--json` mode.

Not verified here (needs the real environment):

- SSH pairing against a live macOS VM (`vm setup` → `zkb host add` →
  `authorized_keys` → `host test`); the QEMU-based discovery and probe are
  tested against synthetic `/proc` entries and real local SSH banners, but not
  against a real VM's sshd.
- The real AOT pipeline on macOS (3dsrecomp, clang, xcodebuild, MoltenVK); the
  Agent's fake-build mode replaces only script execution.
- Signing/installation on Windows/macOS (user step; out of scope).
- The Tauri GUI (not included in this release).

## Testing

```bash
cd builder
cargo test --workspace                    # unit + local integration + fake-agent E2E
cargo test -p builder-linux               # only the Linux frontend's tests
builder/linux/tests/local_fake_agent.sh   # human-readable E2E, no macOS needed
```

The fake-agent E2E needs the workspace binaries next to each other, which
`cargo test --workspace` builds automatically. It uses deterministic non-ROM
payloads in a temp directory; no ROM, IPA or game data is committed or
uploaded anywhere.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `vm discover` finds no endpoint | QEMU is not running, the VM uses bridged networking, or the forward is not visible. Start the VM; check `-netdev …,hostfwd=tcp::2222-:22`; or pass `--host/--port` or `ZKB_VM_SSH` |
| `… is not answering as an SSH server (timed out)` | The forwarded port points at the wrong guest port, the VM is not booted, or Remote Login is off inside macOS |
| `Permission denied (publickey)` | The `authorized_keys` line was not added, has wrong whitespace, or the Mac user/`builder-agent` path is different. Re-run `vm setup --name … ` and paste the printed line |
| `host key mismatch` | The VM was reinstalled or the port now points at a different machine. Do not ignore it: remove the stale profile with `zkb host remove <name>` and pair again after verifying the fingerprint |
| `host test` reports `toolchain_missing` / `repo_missing` / `insufficient_storage` | Fix the macOS side as the message says (Xcode + iOS SDK, Rust with `aarch64-apple-ios`, `xcodegen`, Python 3, Agent started with `--checkout`, ~20 GB free) |
| Upload interrupted | `zkb` resumes by offset; rerun the same command or `zkb build …` again. The Agent rejects a size/SHA256 mismatch |
| `the downloaded IPA does not match …` | Corrupt or partial download: delete the file and run `zkb download --host <name> <job-id> --out <dir>` again |
| `no build host is configured yet` | Run `3ds2apple-builder vm setup --name cachyos-vm` first, or `zkb host add` for a LAN Mac |
| `the shared zkb client was not found` | Install the package (both binaries), or put `zkb` next to the frontend, or pass `--zkb PATH` |
| `config … readable by other users` (doctor warning) | `chmod 600` the config file; keys must stay `0600` (the shared client creates them that way) |

## Layout

```text
builder/linux/
  Cargo.toml, src/            frontend crate (`builder-linux`, binary `3ds2apple-builder`)
  README.md                   this document
  packaging/                  PKGBUILD, deb/tarball script, man page, desktop entry
  tests/                      local integration, fake-agent E2E, shell E2E wrapper
```

The frontend depends on `builder-core` for config, hashing and SSH helper
functions, and shells out to the shared `zkb` binary for protocol work. That
keeps behaviour identical to the Windows and macOS clients, and means a fix in
the shared client benefits all platforms.

## Related documentation

- [`builder/README.md`](../README.md) — Builder architecture, Build Agent, security model
- [`builder/UX.md`](../UX.md) — user flows and copy rules
- [`builder/PROTOCOL.md`](../PROTOCOL.md) — wire protocol v1
- [`builder/STACK.md`](../STACK.md) — technology and repository layout
- [`scripts/AOT_BUILD.md`](../../scripts/AOT_BUILD.md) — per-game AOT build commands and failure diagnostics
- [`docs/build.md`](../../docs/build.md) — the manual macOS build the Agent automates
