# Builder implementation plan

> **Status: design.** This plan turns [README.md](README.md) /
> [PROTOCOL.md](PROTOCOL.md) into four work packages with acceptance criteria.
> Nothing here is implemented yet. Each package is an independently reviewable
> unit of work and writes only inside its own directory scope.

## 1. Work packages

Dependency graph:

```text
                 ┌──────────────────────────────────────────┐
                 │ W1  macOS Build Agent + shared core/CLI  │  (critical path)
                 └───────────────┬──────────────────────────┘
                                 │ protocol core + fake agent published
                 ┌───────────────┴───────────────┐
                 ▼                               ▼
   ┌───────────────────────────┐   ┌───────────────────────────┐
   │ W2  Windows Builder MVP   │   │ W3  Linux Builder MVP     │
   └───────────────────────────┘   └───────────────────────────┘

                 ┌──────────────────────────────────────────┐
                 │ W4  Mac-free cross-compile spike         │  (research, parallel)
                 └──────────────────────────────────────────┘
```

### W1 · macOS Build Agent + shared core/CLI

**Outcome.** A Linux (and later Windows) command-line Builder can connect to a
macOS Build Agent over SSH, build one game end-to-end with the existing scripts,
download the unsigned IPA, verify the SHA256 and manifest, cancel a build, and
see the Agent delete the ROM and generated code afterwards.

**Scope (write):** `builder/core/`, `builder/cli/`, `builder/agent/`,
`builder/tests/`; root `.gitignore` addition for `node_modules/` only if W2/W3
land first (coordinate with the maintainers). No changes to `ios/`, `scripts/`,
`docs/` are expected: the Agent calls the scripts as-is.

**Deliverables:**

1. `builder-core` crate: protocol frames/types, version negotiation, SSH
   binding (`stdio` NDJSON + upload/download subcommands), HTTP binding
   (REST + SSE), streaming SHA256, host profiles, credit-store secrets, log
   event model, redacted export.
2. `builder-agent` macOS binary:
   - `doctor --json` (toolchain, source checkout, disk, MoltenVK cache,
     permissions; no ROM needed);
   - `pair` (HTTP token / SSH `authorized_keys` line, fingerprints);
   - `serve` daemon with control socket, job store, FIFO queue + one build
     slot, `ssh-dispatch` forced-command entry point;
   - job runner: per-job input/log/output directories, process-group execution
     with stage timeouts, SIGTERM→SIGKILL cancellation, NDJSON log capture with
     sequence numbers, stage parser for the scripts' output, and removal of the
     name-keyed build products from the checkout at every terminal state;
   - `preparing` step that ensures the pinned source checkout and cached
     runtime/MoltenVK (download SHA256-pinned, never committed);
   - cleanup on every terminal state, restart recovery (`interrupted`), stale
     child-process detection, `gc`, `selftest --dry-run` that validates the
     toolchain and prints the exact commands a job would run without a ROM.
3. `zkb` CLI: `host add|test|doctor|remove`, `build`, `jobs`, `status`,
   `logs`, `cancel`, `download --verify`, `delete`, `--json`, stable exit
   codes, resumable uploads/downloads.
4. `builder/tests/fake-agent` + golden fixtures for every protocol scenario and
   an e2e script for Linux → macOS (no ROM committed; uses the user's local
   ROM from the gitignored `ROM/` directory or `--rom`).
5. Documentation updates inside `builder/` only: protocol/UX/stack/plan stay
   accurate; the repo README may need a short "Building without a Mac desktop"
   pointer, coordinated with the maintainers (out of this package's write
   scope; note it in the change description).

**Acceptance:**

- `cargo fmt`, `cargo clippy --workspace --all-targets -D warnings`,
  `cargo test --workspace` pass on Linux with no macOS host (fake agent).
- `zkb host doctor` against the macOS VM reports the documented reference
  environment (`Xcode 16.4 / iOS 18.5 SDK`, Rust target installed, checkout
  revision, free disk).
- End-to-end on Linux → macOS VM: `zkb build` produces an IPA whose SHA256
  matches the manifest copy and the Agent's `artifact.json`; the file opens as
  a valid `Payload/*.app` zip; the `manifest.txt` reports the title ID,
  recomp/Zakuro revisions and Xcode version.
- Cancel at each stage (transfer, recompiling, linking, packaging) ends in
  `canceled`, leaves no `3dsrecomp`/`clang`/`cargo`/`xcodebuild` children, and
  removes the ROM from the Agent job directory.
- Agent restart during a build yields `interrupted` with a clear error and no
  stale children after restart.
- Default cleanup verified: job `input/` is empty/deleted, the name-keyed
  build products (`build/game/<name>`, `build/ios/<name>`) are gone from the
  checkout, and the artifact remains until `delete`/TTL.
- No ROM, derived code, IPA, binary, token or private key in git
  (`git status` clean, diff text-only).
- Local test pass from [§3](#3-local-verification-linux--macos-vm).

**Estimate:** 1.5–2.5 weeks (±50%). The
protocol/fake-agent part can start immediately and needs no Mac; the Agent
runner needs the macOS VM.

**Risks:** first-run provisioning on the Mac (network, Xcode licence state,
MoltenVK SHA256 drift); script output parsing fragility (mitigate with a
stable-contract test and pinning); 8 GB VM memory limits (serial builds,
`--auto-serial` is the default).

### W2 · Windows Builder MVP

**Outcome.** A Windows 10/11 desktop app that adds a build host (SSH or
paired HTTP), picks a ROM, builds on the user's macOS host, shows progress and
logs, downloads and verifies the IPA, and walks the user through Sideloadly/
AltStore/SideStore installation.

**Scope (write):** `builder/windows/`, `builder/ui/`; root `.gitignore` entries
for `node_modules/` and Tauri bundle output (coordinate).

**Deliverables:**

1. Tauri 2 app: welcome/BYO-ROM statement, host wizard (SSH key generation +
   restricted `authorized_keys` line + fingerprint confirmation; HTTP pairing
   with credential-store token), host list/status, build screen (file picker +
   drag-drop, hashing progress, options), transfer progress with resume,
   stage timeline + virtualised log viewer, result screen (IPA, SHA256 copy/
   verify, manifest summary, cleanup status), job history, install guide.
2. Windows packaging: NSIS/MSI installer, per-user install without admin,
   WebView2 presence check, uninstall that leaves user data unless asked,
   `SHA256SUMS` for release assets.
3. i18n (en + zh-CN) scaffolding; strings externalised.
4. GUI tests against `tests/fake-agent` on Windows CI, plus a manual
   end-to-end against the real macOS host.

**Acceptance:**

- Installer installs/uninstalls cleanly on a clean Windows 11 VM without
  admin; the app launches and the CLI works from the same install.
- A user following [UX.md](UX.md) §3–§6 with no other documentation gets from
  "install" to a verified IPA on a remote macOS host.
- Large-file path: a multi-GB ROM with a CJK name and spaces uploads, a
  cancelled/internet-dropped upload resumes, and a 4 GB sparse-file test
  passes.
- Token never appears in `%APPDATA%` config, logs or crash text; it is read
  back from Credential Manager after restart.
- SHA256 verification failure is detected and re-downloaded automatically.
- Windows checks in [§4](#4-windows-verification-checklist) pass.

**Estimate:** 1–1.5 weeks (±50%) once W1's protocol module + fake agent exist.

**Risks:** Tauri/WebView2 availability on old Windows images (mitigate: detect
and show a fix link; CLI fallback); Windows OpenSSH quirks (key ACLs,
known_hosts); SmartScreen/Gatekeeper warnings on unsigned binaries (document,
verify SHA256SUMS); long-path handling.

### W3 · Linux Builder MVP

**Outcome.** The Linux desktop is a first-class Builder, optimised for the
local macOS VM scenario: host setup over SSH port forwarding, resumable large
files, the same GUI as Windows, plus a headless CLI path and Linux packaging.

**Scope (write):** `builder/linux/`; shared `builder/ui/` is owned with W2
(coordinate through the protocol/fixtures, not by both editing the same files
at once).

**Deliverables:**

1. Linux packaging of the same Tauri UI (AppImage first; `.deb`/`.rpm`
   scripts with `webkit2gtk-4.1`/`libappindicator` dependencies documented),
   plus the standalone `zkb` CLI tarball.
2. Local-VM convenience: host wizard help for SSH port forwarding
   (`ssh -p <forwarded-port> …`), "test host" that checks SSH reachability and
   `doctor`, and a copyable command block for starting the VM/agent (no
   password storage, no VM management by the Builder).
3. Headless/server guidance: CLI-only install, `--json`, non-interactive
   flags, systemd-user notes for keeping a Mac-side agent available are out of
   scope (Agent is macOS).
4. Packaging tests on at least two distributions; manual e2e against the
   macOS VM.

**Acceptance:**

- AppImage runs on a clean Arch/CachyOS and Ubuntu 22.04 with the documented
  dependencies; the CLI tarball runs without a GUI stack.
- The Linux user flow from [UX.md](UX.md) completes against the local macOS VM
  over SSH; the install guide correctly says signing needs Windows/macOS and
  never claims Linux signing support.
- Same protocol/fixtures and job semantics as Windows (no forked client logic).
- Uninstall/cleanup docs: remove binary, data dir and host profile; no secrets
  left behind.

**Estimate:** 3–5 days (±50%) once W1 is usable; the UI reuse keeps it small.

**Risks:** WebKitGTK version/theme differences across distributions; AppImage
sandbox/portable-home quirks with credential store unavailable (fallback: file
`0600` token with explicit user consent, documented); Linux signing gap is a
product expectation risk (be explicit in the UI and README).

### W4 · Mac-free cross-compile spike (go/no-go)

**Outcome.** An evidence-based recommendation on whether Windows/Linux can
produce an installable game build without a Mac, and if so what the long-term
architecture would be.

**Scope (write):** `builder/cross/` (+ a short update to
`builder/README.md` "Supported matrix"/"Non-goals" once decided).

**Research questions:**

1. Can `clang -target arm64-apple-ios` + `ld64.lld`/`ldid`/`rcodesign` on
   Linux/Windows build and ad-hoc sign a loadable module without an Apple SDK
   redistribution problem? What is the minimum sysroot/headers actually needed
   for the generated C and the static archives?
2. The S2Arm-style route: a prebuilt shell (once, from macOS) plus a
   cross-compiled game module (`dylib` or similar) injected and re-signed by
   `rcodesign`, loaded by a custom loader. Does it work on the project's
   target iOS version, and what breaks (code signing, executable memory,
   dyld, entitlements)?
3. Is a prebuilt static runtime + per-game re-link possible with LLVM on
   Windows, including Swift/ObjC shell constraints (the shell cannot be built
   without macOS, so some prebuilt artifact is unavoidable)?
4. Legal/licensing: Apple SDK redistribution, Xcode licence, notarization and
   signing; what can be documented for users without encouraging EULA
   violations?

**Deliverables:** a report with a decision matrix, a minimal test artifact
(hello-world module) and a device test result if feasible, explicit list of
blocking risks, and a recommendation: keep "Windows/Linux frontend + macOS
Agent" as the long-term path, or open a follow-up implementation package.

**Acceptance:** clear go/no-go; no unlicensed SDK/binaries committed; the
decision and its evidence are reviewable by the maintainers.

**Estimate:** 1 week research (+ device testing), ±50%.

**Risks:** legality dominates; a positive result may still be unshippable due
to SDK licensing. Treat negative/inconclusive as a valid outcome.

## 2. What to build first

Order matters; each step is independently verifiable and mostly does not need
a Mac.

1. **Freeze the protocol core (no Mac needed).** `builder-core` types + golden
   fixtures + the in-process fake Agent. This is the contract every other
   package depends on; changing it later costs the most. Include the state
   machine, error codes, upload resume and artifact verification tests.
2. **CLI happy path against the fake Agent.** ROM selection, hashing, job
   create, upload (fake), subscribe/log replay, artifact download + SHA256
   verify, exit codes. This proves the client UX/CLI semantics before the real
   Agent exists.
3. **Agent doctor + selftest on the macOS VM.** `doctor --json` and
   `selftest --dry-run` (validates Xcode, Rust target, xcodegen, Python, disk,
   source revision and prints the exact pipeline commands) can be developed and
   tested without a ROM and with no build risk. This catches most macOS-side
   setup problems early.
4. **Agent job runner + stage parser, end-to-end on the Linux → macOS VM.**
   One real game build with the user's own ROM; then the cancel/restart/cleanup
   matrix. This is the first "it works" milestone.
5. **`zkb build` polish + Apple-free release gate**: resume, `--json`,
   redacted logs, `delete`, `jobs`.
6. **Then W2/W3 in parallel** against the fake Agent, with their own platform
   verification; W4 can start at any time after the design is accepted.

Do **not** start with the GUI. The GUI is a thin shell; the expensive unknowns
are the protocol, the Agent's process/cleanup correctness and the macOS
provisioning.

## 3. Local verification: Linux → macOS VM

The reference local setup is a Linux development host driving a macOS VM over
SSH (the same shape as a LAN Mac or cloud Mac, so everything verified here
carries over). No credentials belong in the repository or logs.

### 3.1 Build the pieces

```bash
# Linux host (client side)
cd builder
cargo build --release -p builder-cli
cargo test --workspace            # fake agent, fixtures, state machine

# macOS host (Agent side; build on the Mac or install a release build)
cargo build --release -p builder-agent
./builder-agent doctor --json
```

Notes: the Agent binary must be built/installed on macOS (Rust cannot reliably
cross-compile a Mach-O binary from Linux without the Apple toolchain, which is
exactly what this design avoids depending on). No ROM is needed for `doctor`
or `selftest`.

### 3.2 Host setup

```bash
# one-time: Agent generates the pairing material
builder-agent pair                       # HTTP token (same-machine / tunnel)
builder-agent ssh-setup                  # prints the restricted authorized_keys line
# (the exact command names are the target interface; see PROTOCOL.md §4)

# Linux host
zkb host add --ssh <user>@<mac-host> --port 22 --name macvm
zkb host doctor macvm
```

Expected: `doctor` lists Xcode 16.4 / iOS 18.5 SDK, Rust with
`aarch64-apple-ios`, xcodegen, Python 3, git, the source revision and free
disk; any missing item is actionable.

### 3.3 One real build (user's own ROM, never committed)

```bash
# ROM stays in the gitignored local directory; it is uploaded to the VM and deleted after the build.
zkb build --host macvm --rom "./ROM/<game>.cci" \
          --name <slug> --display-name "<Game name>" --out ./out
```

Checks after success:

| Check | Expected |
|---|---|
| `sha256sum ./out/<slug>-AOT.ipa` | equals the SHA256 printed by `zkb` and `artifact.json` |
| `unzip -l ./out/<slug>-AOT.ipa` | contains `Payload/3ds2apple.app/` with `Info.plist` and the executable |
| `manifest.txt` (download or Agent copy) | title ID is 16 hex digits; `ipa_sha256` matches; `recomp_rev`/`zakuro_rev`/`xcode` filled |
| Agent status | `state: succeeded`, `inputs_kept: false` |
| Agent job dir | `input/` deleted, and the checkout's name-keyed build products removed (logs/artifact per retention) |
| Processes | no `3dsrecomp`, `clang`, `cargo`, `xcodebuild` left (`pgrep -fl`) |
| Free disk on the Mac | returns to the pre-build level (± logs/artifact) |
| Logs | no ROM content, no keys, no token; ROM file name may appear, redacted export removes it |

Rough time budget to treat as the test target (not a guarantee): multi-GB
upload over a LAN/VM network takes minutes; a full per-game build on the
reference 4 vCPU / 8 GB VM takes tens of minutes. A build that hits
`--auto-serial` fallback is expected on that VM and must be reported, not
hidden.

### 3.4 Negative and chaos tests

| Scenario | How | Expected |
|---|---|---|
| Wrong ROM hash | Alter the local file after `job.create` declares its hash (or use `--bad-hash` test hook in the fake client) | `input_invalid`, staging file deleted, job stays/ends cleanly |
| Cancel each stage | `zkb cancel` during transfer, recompiling, linking, packaging | `canceled`; process group dead; input/work removed |
| SSH connection dropped mid-build | Kill the SSH connection / suspend the network | Build continues on the Agent; reconnect shows the current stage and log; no duplicate build |
| Network dropped mid-upload | Disable the link, re-enable | Resume from `received_bytes`, hash matches, job continues |
| Network dropped mid-download | Same during artifact download | Resume by offset, SHA256 still verifies |
| Agent restarted mid-build | `launchctl kickstart -k` / SIGTERM the daemon | Job `interrupted`, clear message, no stale children after restart |
| Agent restarted after success | Restart | Artifact still downloadable; status `succeeded` |
| Queue full | Submit `max_queued_jobs + 1` jobs | `queue_full` with retry-after; nothing lost |
| Disk pressure | Small scratch volume / `df` threshold override in a test build | `insufficient_storage` precreate or `build_failed` with hint; no partial "success" |
| Missing toolchain | `xcode-select` to a bad path / rename `xcodegen` in a test environment | `toolchain_missing` with item list; no build started |
| Source mismatch / dirty repo | Checkout another commit / touch a file | `source_mismatch` / `repo_dirty` with expected vs actual and override path |
| Bad auth | Wrong token / wrong SSH key | `unauthorized`, rate limited after repeats, no job created |
| Protocol mismatch | Fake agent hello with `/2` | `unsupported_protocol`, clear update message |
| Host key changed | Regenerate VM host key in a test setup | `host_key_mismatch` hard stop |
| Path abuse | Attempt `../` in name, symlinked ROM in path mode, weird Unicode file name | rejected with `bad_request`/`forbidden`; no file outside the job dir touched |
| Large file | Generate a 4 GB sparse/real file | upload, resume, hash, cleanup within the documented limits |
| Malformed frames | fuzz/fixtures with truncation, wrong types, huge frames | frame ignored/rejected per protocol; session stays alive; no panic |

### 3.5 Security verification on the local setup

- SSH mode: the Mac shows no new listening port for the Agent (`netstat`/
  `lsof`); the restricted key cannot open a shell (`ssh -i <builder-key> '
  whoami'` fails) or run arbitrary commands.
- Files: data root `0700`, job dirs `0700`, inputs/artifacts `0600`; the
  Builder's token is absent from `config.toml` and from `~/.ssh` except the
  dedicated key.
- Logs: grep the captured logs and exported redacted log for tokens, keys and
  ROM bytes; the export strips paths and the ROM file name.
- The Agent refuses to run as root; the `--allowed-user` mismatch is rejected.
- HTTP mode: only loopback binds by default; a non-loopback bind without TLS is
  refused; a changed TLS fingerprint is a hard error.
- Cleanup: after `succeeded`/`failed`/`canceled`/`interrupted` and after
  `zkb delete`, no ROM or generated C remains under the Agent data root (check
  with a recursive search for the ROM's magic bytes / file name).

### 3.6 macOS-host-specific checks

- Gatekeeper: download the Agent from the release page and run it — the
  documented approval flow works, and the binary's SHA256 matches.
- Xcode licence/first-launch: a fresh Mac/VM that has never run
  `xcodebuild -runFirstLaunch` is reported by `doctor` with the fix command.
- MoltenVK provisioning: first packaging step downloads v1.4.2, verifies
  SHA256, caches it, embeds it; a second build does not re-download; an
  intentionally corrupted cache file fails the job with a clear error.
- Fresh checkout: Agent managed mode clones the pinned revision; a dirty
  working tree or mismatched revision is reported, not silently used.
- Permissions: an unwritable data root fails at startup with a readable error.
- Performance: `doctor` reports disk/cpu/memory; build time and peak memory are
  logged in the artifact manifest for the reference VM.

## 4. Windows verification checklist

These cannot be validated from Linux and must be done on a Windows host (VM is
fine) before the Windows MVP is declared done. A second person following
[UX.md](UX.md) only should attempt the full flow.

**Install / start**

- [ ] Installer runs without admin, per-user; app starts from Start Menu and
      from an arbitrary directory; uninstall leaves/removes user data as
      documented.
- [ ] WebView2 present → app renders; missing → clear message with a fix link
      (simulate by disabling the Edge WebView runtime on a test image).
- [ ] SmartScreen/Defender handling documented; `SHA256SUMS` verifies.
- [ ] No firewall prompt in SSH-only mode; nothing listens on Windows.

**Secrets / SSH**

- [ ] Windows OpenSSH client present (`ssh -V`); the Builder locates it and
      fails with a helpful message when absent.
- [ ] Dedicated key created under the profile dir with ACLs restricted to the
      user; `known_hosts`/host-key verification works, including a changed
      host key.
- [ ] Token stored in Credential Manager and restored after restart; absent
      from `%APPDATA%` files and logs.

**Files**

- [ ] ROM picker handles spaces and CJK names, files on a network/OneDrive
      path, and paths longer than 260 characters.
- [ ] Drag-and-drop works; a 4 GB upload completes and a dropped/wobbly link
      resumes.
- [ ] Artifact download resume and SHA256 verification; "open folder" opens
      Explorer on the artifact.

**GUI**

- [ ] 125% / 150% / 200% DPI scaling, dark and light themes, keyboard-only
      navigation, screen-reader labels on stages/progress.
- [ ] Log viewer stays responsive with 100k+ lines and very long lines.
- [ ] Closing the window during a build does not cancel it; the job is
      reattachable after restart; a system sleep/resume during a build
      reconnects cleanly.
- [ ] zh-CN and en strings both render; no clipped labels.

**End-to-end**

- [ ] Windows → remote macOS host: full build, verified IPA, Sideloadly/AltStore
      guide followed by a second person results in an installed app.
- [ ] Failure paths render the documented messages: unreachable host, re-pair,
      toolchain missing, source mismatch, disk full, build failed, canceled,
      interrupted.
- [ ] Windows arm64: build the CLI/GUI and smoke-test if the platform is
      claimed as supported (else mark experimental in the docs).

## 5. macOS-specific verification (real Mac or VM)

Already covered in §3.6; the release gate requires the full e2e build on a real
macOS host (not a fake agent) and a device install with a signed IPA produced
from the Builder output. This is a manual step in the project's release
checklist because it needs the user's own ROM and Apple ID.

## 6. Definition of done (Builder v1)

- All four packages' acceptance criteria pass; the docs in `builder/` match the
  implementation.
- Protocol fixtures and fake agent are committed and CI runs them on Linux and
  Windows; CI never builds game data and never sees a ROM.
- A fresh Windows 11 VM + fresh macOS host, following only the public
  documentation, produces a verified unsigned IPA; signing/installation with
  Sideloadly succeeds; the Agent job directory contains no ROM or generated
  code afterwards.
- No ROM, generated C, `.a`, IPA, binary, token or private key in git;
  `git status` clean; the public docs describe only the shipped product.
- `builder/README.md` "Supported matrix" reflects what was actually verified,
  including any experimental/unsupported platform markings.

## 7. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Agent provisioning on a fresh Mac (Xcode first launch, Rust target, xcodegen, network) | First build fails for new users | `doctor` + `selftest --dry-run` with exact fix commands; docs; setup checklist; fail before transfer so the user does not upload a ROM for nothing |
| macOS VM instability / 8 GB RAM | Builds time out or OOM | Serial builds, `--auto-serial` default, stage timeouts, retry with clearly separated failure codes; document recommended host specs |
| Script output/CLI drift | Agent parses wrong IPA path/manifest | Parse only documented markers; version-lock the expected scripts; W1 tests the contract with fixtures; mismatch → `unsupported_agent` |
| SSH variability on Windows (OpenSSH version, key ACLs, proxies) | Host setup failures | Dedicated key, explicit `ssh -V` check, clear diagnostics, `ssh -vv` capture in `doctor --json`; fall back to HTTP tunnel path |
| Unsigned binaries (Gatekeeper/SmartScreen) | Users scared off / blocked | Document approval flows, publish SHA256SUMS, build from source instructions; consider signing when a certificate exists |
| Multi-GB upload over a slow link | Long waits, aborted transfers | Resumable upload with visible progress/ETA; path mode for shared folders; hash computed once locally and verified remotely |
| Cloud Mac provider sees the ROM | Privacy concern | In-product caveat + recommendations (encryption, dedicated user, cleanup), no claim that third-party hosts are private |
| Linux has no official signing path | Linux users cannot finish alone | Explicit guide: sign on Windows/macOS; mark Linux-native signing unsupported; keep IPA portable |
| Tauri/WebView2/WebKitGTK packaging | GUI unavailable on some systems | CLI always ships; detect missing webview with a fix link; native GUI fallback considered (STACK §2B) |
| Protocol shape churn after W1 | Rework in W2/W3 | Freeze fixtures in W1; additive-only changes in v1; version negotiation |
| Legal/EULA (VM or cloud macOS, SDK redistribution) | Project risk | Public docs only describe user-owned licensed hosts; no macOS setup or SDK redistribution; W4 explicitly studies licensing boundaries |
