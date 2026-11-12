# Builder technology and repository layout

> **Status: implemented (core, CLI, Agent).** This document records the stack,
> the alternatives that were weighed, and the layout that now exists under
> `builder/`: the shared library, the `zkb` CLI and the macOS Build Agent are
> implemented in Rust and tested on Linux. The GUI frontends are still design
> only.

## 1. Decision summary

| Decision | Choice | Why |
|---|---|---|
| Implementation language | **Rust 2021**, one Cargo workspace under `builder/` | One toolchain for Agent, CLI and GUI backends; single static binaries on Windows/Linux without a Python/Node runtime; the build pipeline already uses Rust (Zakuro); strong process, IO and crypto ecosystem. |
| Shared client | `builder/core` library crate | Protocol, transports, hashing, config/secrets and log redaction are used by the CLI and both GUIs; no duplicated client logic. |
| First client | `builder/cli` (`zkb`) | Fastest way to prove the protocol end-to-end on Linux → macOS VM; headless and scriptable; the Linux MVP. |
| GUI | **Tauri 2** (Rust backend + TypeScript web UI) for Windows and Linux | Small installers, uses the OS web view (WebView2 / WebKitGTK), reuses the `core` crate, one UI codebase for both desktops. CLI remains available when a webview is not desired. |
| Agent | `builder-agent` Rust binary, daemon + `ssh-dispatch` | Owns jobs, processes, cleanup and logs; runs only on macOS; no runtime dependencies beyond the OS and the existing toolchain. |
| SSH | Shell out to the system OpenSSH client/server in v1 | Users already have `ssh` on Linux and macOS, Windows 11 ships it and Windows 10 offers it as an optional feature; it handles keys, known_hosts, agent and user config. No second crypto stack, no custom SSH server to get right. A native library can replace it later without changing the protocol. |
| HTTP/HTTPS | `reqwest` (rustls) + `tokio` on the client; `axum` + `tokio` on the Agent | Standard, TLS via rustls (no OpenSSL build dependency on Windows), SSE is just chunked responses. |
| Secrets | OS credential store via `keyring` (Windows Credential Manager, Secret Service, macOS Keychain) | Tokens never land in config files or history. |
| Tests | `cargo test` + protocol fixtures + in-process fake Agent + a Linux→macOS e2e script | The whole client is testable without a Mac; only the real build needs macOS. |
| Distribution | GitHub Releases with SHA256SUMS | No project server, consistent with the local-first trust model. |

Working names (bikeshedding is deferred): product **3ds2apple Builder**, CLI
binary `zkb`, macOS binary `builder-agent`, protocol
`3ds2apple-builder/1`, pairing URL scheme `3ds2apple-builder://`.

## 2. Options considered

### A. Rust + Tauri (recommended)

One workspace: `core` (protocol/transport/client), `cli`, `agent`, and two thin
Tauri shells. Single binaries for CLI and Agent; GUI installers are ~5–15 MB
using the system webview. The Agent's job runner and process supervision are
services the Rust ecosystem handles well (`tokio`, `command-group`, `sha2`,
`serde`). Cargo makes cross-platform CI straightforward.

Costs: learning/maintenance overhead of a web UI stack in addition to Rust;
Tauri adds WebView2/WebKitGTK as a runtime dependency for the GUI (not for the
CLI); the Windows installer is unsigned by default and triggers a SmartScreen
warning.

### B. Rust + native GUI (egui / iced / Slint)

Same Rust core, no webview. Smaller and more predictable on old Windows
machines; no HTML/CSS. But the UI work (file dialogs, log viewer, tables,
accessibility, i18n) is all hand-rolled or ecosystem-immature compared with
web UI, and the project would own more pixels for the same two screens. A
reasonable fallback if WebView2 turns out to be a support problem.

### C. Python + CLI (and no GUI, or PySide6 later)

The fastest possible MVP: `argparse`/`click`, `httpx`, `paramiko` (or `ssh`
subprocess), `hashlib`. The macOS Agent could be Python too (macOS ships
Python 3 via the developer tools, but a pinned runtime is still needed) and the
existing build scripts are shell/Python already.

Problems for a shipped desktop tool: packaging a Python GUI (PyInstaller) is
large (~50–150 MB), slow to start, frequently flagged by antivirus on Windows,
and needs per-platform build hosts; the OS credential store and native file
dialogs add dependencies; a security-sensitive tool that stores tokens and
talks SSH benefits from stronger types and a single-binary story. Acceptable
for a throwaway protocol spike, not for the shipped Builder.

### D. Electron / Node or Go + Wails

Electron: by far the best-documented desktop UI, but 100 MB+ installers, high
memory, a Node supply chain for a tool that handles ROMs and SSH keys. Go +
Wails: viable (single binary, web UI), but splits the project's language stack
and the Agent/CLI would not share types with anything else in the repository.
Not recommended.

### Comparison

| Criterion (weight) | Rust+Tauri | Rust+native GUI | Python+CLI | Electron/Go |
|---|---|---|---|---|
| MVP speed (high) | medium | medium | **high** | medium |
| Installer size / startup (high) | **good** | **good** | poor (frozen) | poor |
| Distribution / no runtime deps (high) | **good** (CLI/Agent); GUI needs webview | **good** | medium (AV false positives) | medium |
| Type-safe protocol/client shared by CLI+GUI (high) | **good** | **good** | weak | weak |
| Security posture, secrets handling (high) | **good** | **good** | medium | medium |
| Long-term maintenance (medium) | good | medium (UI churn) | medium | medium |
| Contributor familiarity (medium) | medium | medium | **high** | high |
| OS support (Win/Linux) (medium) | good | good | good | good |
| Ecosystem for SSH/process/crypto (medium) | **good** | **good** | good (paramiko) | good |

Verdict: **Rust + Tauri**, with the CLI built first so the protocol and Agent
are proven before any web UI exists. If Tauri becomes a problem on a target
machine, the CLI keeps working and a native-shell GUI can be added behind the
same `core` crate.

## 3. Recommended dependencies

Keep the dependency set small and licence-clean (project is Apache-2.0; only
MIT/Apache-2.0/BSD-compatible crates; no GPL/AGPL).

| Area | Crates |
|---|---|
| Serialization/protocol | `serde`, `serde_json` |
| CLI | `clap` (derive) |
| Async/HTTP | `tokio`, `reqwest` with `rustls-tls`, `axum`, `tower`, `futures` |
| Hashing/encoding | `sha2`, `hex`, `base64`, `ulid` or `uuid` |
| Process supervision (Agent) | `tokio::process`, `command-group` (process groups without unsafe code) |
| Filesystem | `tempfile`, `walkdir`, `fs2` (advisory locks) or a small lock file |
| Config/secrets | `dirs`, `keyring`, `toml`, `zeroize` for transient secret buffers |
| Logging/diagnostics | `tracing`, `tracing-subscriber`, rolling file appender |
| Errors | `thiserror`, `anyhow` (binaries only) |
| GUI | Tauri 2 + TypeScript + one small framework (Svelte or React); minimal npm dependencies |
| CI hygiene | `cargo-deny` (licences/advisories), `cargo-audit`, `rustfmt`, `clippy` |

No codegen in the protocol path: the JSON shapes are plain `serde` structs and
versioned fixtures. This keeps the "no generated code in git" rule absolute
(see §6).

## 4. Repository layout

The `builder/` directory is a self-contained Cargo workspace. The `core`,
`cli` and `agent` crates exist today; `windows/`, `linux/`, `ui/` and `cross/`
are still design-only.

```text
builder/
  README.md  PROTOCOL.md  UX.md  STACK.md

  Cargo.toml                     # [workspace] members = core, cli, agent

  core/                          # library crate: builder-core  (no UI, no process exec)
    src/lib.rs
    src/protocol/
      mod.rs                     # frame envelope, tags, version negotiation
      frames.rs                  # all request/reply/event structs (serde)
      codes.rs                   # stable error codes + human hints
      model.rs                   # job/game/artifact/limits types
    src/transport/
      mod.rs                     # trait ControlChannel + DataChannel
      ssh.rs                     # invoke system ssh; NDJSON framing; subcommands
      http.rs                    # reqwest client + SSE event stream
    src/client.rs                # BuilderClient: hello, create, upload, subscribe, cancel, download
    src/hash.rs                  # streaming SHA256 (file and network)
    src/config.rs                # host profiles, paths, redacted display
    src/secrets.rs               # keyring-backed token storage
    src/redact.rs                # redacted log export
    tests/                       # protocol/state-machine tests against fake agent

  cli/                           # binary crate: zkb
    src/main.rs                  # clap commands: host/build/status/logs/cancel/download/jobs/delete/doctor
    tests/cli.rs                 # golden-output + exit-code tests

  agent/                         # binary crate: builder-agent (macOS target)
    src/main.rs                  # clap: serve | ssh-dispatch | doctor | pair | setup | gc | update
    src/daemon.rs                # control socket / HTTP server, session handling
    src/store.rs                 # job.json persistence, crash-safe writes
    src/queue.rs                 # FIFO queue + build slots
    src/runner.rs                # process-group execution, timeouts, cancellation
    src/stages.rs                # script invocation + log/status parsing (the contract with scripts/)
    src/cleanup.rs               # input/build-product/artifact retention, gc, stale-process checks
    src/doctor.rs                # toolchain/repo/disk checks; JSON report
    src/pairing.rs               # token generation, hashes, SSH line printing
    src/ssh_dispatch.rs          # forced-command entry point; subcommand allowlist
    tests/                       # stage parser + cleanup tests (host-runnable, no builds)

  windows/                       # Tauri app (Windows packaging, installer)
    src-tauri/
    ...
  linux/                         # Tauri packaging (AppImage/deb/rpm) for the same UI

  ui/                            # shared TypeScript UI used by windows/ and linux/
    src/
      screens/  (HostSetup, Build, Progress, Result, Jobs, InstallGuide)
      components/ (StageList, LogViewer, ArtifactCard, ErrorPanel)
      i18n/ (en, zh-CN)
    package.json

  tests/
    protocol/                    # golden JSON fixtures (control frames + data-channel lines)
    e2e/local_fake_agent.sh      # Linux end-to-end against the Agent's fake build

  cross/                         # W4 spike only: report + minimal prototype, never shipped
```

Rules for the layout:

- `core` has no UI and never spawns processes; `agent` never shares code paths
  that would let the client influence command construction.
- The GUI crates contain no protocol logic — they call `core` through Tauri
  commands. The CLI is the reference client and must stay feature-complete.
- `ui/` is one codebase for both desktops; platform differences are limited to
  file dialogs, tray behaviour, credential store and installer metadata.
- The Agent's `--fake-build` mode is the primary development tool for the GUI
  frontends: it runs the real protocol path on any Unix host without macOS, so
  the GUIs can be built and tested before a macOS host exists.
- `cross/` is research output only; nothing in the shipped binaries depends on
  it.

### Data directories

| OS | Config | Cache/artifacts | Logs | Secrets |
|---|---|---|---|---|
| Windows | `%APPDATA%\3ds2apple\builder\config.toml` | `%LOCALAPPDATA%\3ds2apple\builder\{cache,artifacts}` | `%LOCALAPPDATA%\3ds2apple\builder\logs` | Windows Credential Manager |
| Linux | `$XDG_CONFIG_HOME/3ds2apple/builder/config.toml` | `$XDG_DATA_HOME/3ds2apple/builder/{cache,artifacts}` | `$XDG_STATE_HOME/3ds2apple/builder/logs` | Secret Service (libsecret) |
| macOS (Builder) | `~/Library/Application Support/3ds2apple-builder/config.toml` | `.../artifacts`, `.../logs` | same | macOS Keychain |
| macOS (Agent) | `~/Library/Application Support/3ds2apple-builder-agent/config.toml` | `.../jobs`, `.../cache` | same | token hash in config (`0600`) |

The Agent data root is documented and removable; the "uninstall" instructions
are just "delete this directory and the binary".

## 5. Build and release

### Build from source

```bash
cd builder
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace            # includes protocol fixtures + fake agent
cargo build --release -p builder-cli            # zkb
cargo build --release -p builder-agent          # builder-agent (compile on macOS for real use)
cd ui && npm ci && npm run build
cd ../windows && cargo tauri build             # MSI/NSIS on Windows
cd ../linux && cargo tauri build               # AppImage/deb/rpm on Linux
```

Cross-compilation notes:

- CLI: Windows x86_64 MSVC build on Windows (or `cargo-xwin` for a Linux-hosted
  build); Linux binaries built on the oldest supported glibc, or a musl static
  build for portability; macOS CLI built on macOS.
- Agent: build on macOS for both slices (`cargo build --target
  aarch64-apple-darwin` and `x86_64-apple-darwin`) and combine with `lipo` into
  one universal binary.
- GUI: the installer must be built on its target OS (Tauri's platform
  bundlers). CI does exactly that.

### Release artifacts

Per release, in GitHub Releases:

```text
zkb-<version>-windows-x86_64.zip        (exe + licence + README snippet)
3ds2apple-builder-<version>-windows-x86_64-setup.exe   (Tauri NSIS/MSI)
zkb-<version>-linux-x86_64.tar.gz       (static or old-glibc binary)
3ds2apple-builder-<version>-linux-x86_64.AppImage / .deb / .rpm
builder-agent-<version>-macos-universal.tar.gz
SHA256SUMS
```

- Binaries are unsigned (no Apple Developer ID / Authenticode certificate in
  the project). The README explains the Gatekeeper/SmartScreen prompts and how
  to verify SHA256SUMS. If the project ever ships signed binaries, add the
  notarization/signing steps here and keep the checksums regardless.
- Versioning: workspace semver for Builder and Agent (`0.x` while the
  interface is young); protocol version is independent
  (`3ds2apple-builder/1`) and breaks only on incompatible changes. The
  artifact JSON also embeds the source revision and toolchain versions.
- Cargo.lock is committed (these are binaries); npm lockfiles are committed;
  no generated code, no vendored binaries.

### CI

| Runner | Jobs |
|---|---|
| Linux | `fmt`, `clippy`, workspace tests, fake-Agent conformance tests, build Linux CLI; no ROM, no game build. |
| Windows | build CLI + GUI installer, run workspace tests (client side), smoke-test the GUI launch; no device, no signing. |
| macOS | build Agent (universal), run `builder-agent doctor --json` and protocol tests against the fake Agent; no game build in CI (ROMs never enter CI). |
| Release | tag build of the artifacts above + `SHA256SUMS`; manual e2e against a real macOS host is a release gate (see [README.md](README.md)). |

Tauri's webview is a runtime dependency of the GUI only: Windows 10/11 ships
WebView2 (Evergreen); Linux packages depend on `webkit2gtk-4.1` and
`libappindicator` and the packaging docs list them per distribution.

## 6. "Never commit generated code" rules for the Builder

The repository's existing rules apply unchanged: no ROM, decrypted keys, BIOS
or system files, generated C, static libraries, IPAs, game assets or
credentials. For `builder/` specifically:

| Never committed | Where it lives instead |
|---|---|
| `target/` (Rust build products) | workspace-local, already covered by the root `.gitignore` |
| `node_modules/`, `dist/`, Tauri bundle outputs | local/CI; `dist/` is already ignored — add `node_modules/` and the Tauri bundle paths to the root `.gitignore` when W2/W3 start |
| Downloaded MoltenVK frameworks/binaries | Agent cache on the Mac (`build/third_party`-style), SHA256-pinned; never in git |
| Generated 3dsrecomp C, `libgame.a`, `libzakuro_ios.a`, Xcode projects | Agent job directories, deleted after the job |
| IPAs, manifests of game builds | Agent artifact directory + Builder artifact directory; never git |
| ROMs, keys, save files, screenshots with game content | user's machines only |
| Tokens, SSH private keys, keychains | OS credential store / profile dir with `0600`; never git or logs |
| Protocol codegen output | not generated: plain `serde` structs + fixtures |

The `.gitignore` additions are the only change the Builder needs outside
`builder/`; coordinate them with the maintainers (they are small and
reviewable).

## 7. Security engineering notes

- `builder-core` and `builder-cli` are `#![forbid(unsafe_code)]`; the Agent
  keeps unsafe code out as well by using the `command-group` and `nix` wrapper
  crates for process-group control instead of hand-written `libc` calls.
- Every external command is executed with an argument array, a fixed working
  directory and an explicit environment; no `sh -c`, no string interpolation.
  A unit test greps the agent source for command construction to keep it that
  way.
- Hashing is streaming (`sha2::Sha256` over 4–8 MiB chunks) so multi-GB ROMs
  and IPA downloads never have to fit in memory.
- Transient secrets (tokens, keys-file bytes) use `zeroize` buffers and are
  never formatted into errors; `Debug` impls on secret-bearing structs are
  manual and redact.
- Log capture runs through a small redaction filter that strips the configured
  token, key paths and (for the exported log) absolute paths and the ROM file
  name.
- Dependency policy: `cargo-deny` in CI (licences allow-list, advisory
  database, banned crates); dependency review before adding anything new.
- The SSH path uses the system client with `BatchMode=yes`,
  `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes` and only the dedicated key;
  the Agent side uses the forced-command entry point. See
  [PROTOCOL.md](PROTOCOL.md) §3.1/§4.1.

## 8. Localization and copy

- GUI strings live in `ui/src/i18n/{en,zh-CN}.json`; the project's first
  audience includes Chinese users, so zh-CN is completed alongside English
  rather than later. CLI output is English with stable machine-readable codes
  (scripts and CI parse those), and error hints are translatable in the GUI.
- No game screenshots or game assets are shipped in the UI; the app icon is
  project artwork.

## 9. Open technology questions (resolved by W1/W2, not blocking this design)

1. Tauri 2 vs a native Rust GUI after the first Windows build (webview
   availability on target machines, installer size, accessibility tooling).
2. System `ssh` subprocess vs an embedded SSH library — v1 uses the system
   client; revisit only if Windows OpenSSH proves unreliable in testing.
3. Windows MSVC vs a cross-built CLI — decide by which produces a smaller,
   more robust single binary in CI.
4. Whether the Agent should manage its own source checkout (`repo.managed`) or
   require a user-managed one. The design supports both; v1 defaults to
   user-managed and documents the managed option.
5. Packaging format for Linux (AppImage first for portability; deb/rpm as
   follow-up) and whether the GUI or the CLI is the primary Linux deliverable.
