# Builder ↔ Build Agent protocol, version 1

> **Status: design.** This is the normative v1 interface between the
> cross-platform Builder and the macOS Build Agent. No implementation exists
> yet; the message shapes, states and error codes below are the contract the
> work packages in [PLAN.md](PLAN.md) implement and test against.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Scope and goals

The protocol lets one Builder client:

1. discover and authenticate to a user-owned macOS Build Agent;
2. create a build job for one game and transfer its input files (ROM, optional
   keys) to that Agent;
3. follow stage progress and a line log while the Agent runs the existing AOT
   scripts ([scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md));
4. cancel a running job and have its processes and data cleaned up;
5. download the unsigned IPA, its manifest and SHA256, and verify them;
6. delete job data on the Agent after it is no longer needed.

Design goals:

- **Local-first trust.** The Agent belongs to the user. The protocol has no
  central server, no relay and no project-operated endpoint.
- **Least privilege.** A compromised or buggy Builder should not get a shell on
  the Mac. SSH access uses a restricted, forced-command key; the Agent executes
  only its fixed build pipeline.
- **Recoverable.** Large transfers, log streams and jobs survive dropped
  connections and client restarts; the Agent owns job state, not the client.
- **Testable without macOS.** The full client and a fake Agent run and are
  tested on Linux/Windows; only job execution needs a real Mac.
- **Boring and explicit.** JSON messages, a small state machine, stable error
  codes, and version negotiation. No code generation.

Non-goals: batch/multi-title jobs, incremental stage checkpoints, a remote
shell, signing/provisioning, device management, multi-user server semantics,
and fully Mac-free builds (a separate research spike).

## 2. Roles and terminology

| Term | Meaning |
|---|---|
| **Client / Builder** | The Windows, Linux or macOS frontend (GUI or CLI) using this protocol. |
| **Agent** | The macOS Build Agent daemon that owns jobs and runs builds. |
| **Host** | The macOS machine running the Agent: a VM, a LAN Mac or a cloud Mac, all user-controlled. |
| **Job** | One per-game AOT build request and everything derived from it. |
| **Input** | A file transferred to the Agent for a job: the ROM (required) and optional keys/supplementary files. |
| **Artifact** | The job output: unsigned IPA + JSON manifest + copy of the build manifest. |
| **Binding** | How frames and files travel: SSH (stdio + subcommands) or HTTP (REST + SSE). |
| **Data root** | The Agent's private directory on the Mac (`~/Library/Application Support/3ds2apple-builder-agent/` by default). |

## 3. Transport bindings

The protocol is one message model with two bindings. An Agent supports at least
one; the CLI/GUI can use either. A job's identity and semantics do not change
with the binding.

### 3.1 SSH binding (default for remote hosts)

The Builder uses the system OpenSSH client (`ssh`): standard on Linux and
macOS, included in Windows 11 and available as an optional Windows 10 feature
(the Builder reports it and links the install steps when it is missing). There
is no listening port on the Mac and no TLS to manage.

Sign-in uses a **dedicated SSH key** created by the Builder. The user appends
its public key to the target account's `authorized_keys` with a forced command
and restrictive options, so the key is useless for anything but the Agent:

```text
command="/Users/<user>/.local/bin/builder-agent ssh-dispatch",restrict ssh-ed25519 AAAA... 3ds2apple-builder <host-profile-id>
```

`restrict` and the forced command mean the key cannot open a shell, run
arbitrary commands, forward ports or read files. The Builder invokes
`ssh <host> '<subcommand> [args]'`; sshd always runs `builder-agent
ssh-dispatch`, which receives the requested text in `$SSH_ORIGINAL_COMMAND` and
allows only the subcommands in §3.1.1. The Agent verifies the login user
against its configured `--allowed-user` and refuses to run as root.

Host-key handling: on first pairing the Builder fetches the host key
(`ssh-keyscan`), shows its SHA256 fingerprint for the user to verify against
the Mac, and only after confirmation stores it in a **profile-private**
`known_hosts` file (`-o UserKnownHostsFile=<profile>/known_hosts`). All later
connections use `StrictHostKeyChecking=yes` against that file. A changed host
key is a hard error (`host_key_mismatch`), not a prompt to continue; the
Builder does not modify the user's global `known_hosts`.

#### 3.1.1 SSH subcommands

The Builder requests these command lines over SSH; the forced command
dispatches on `$SSH_ORIGINAL_COMMAND`:

| Requested subcommand | Purpose |
|---|---|
| `stdio` | Control channel: NDJSON frames on stdin/stdout. |
| `upload --job <id> --role <role> --bytes <n> --sha256 <hex> [--offset <n>]` | Streams file bytes from stdin into the job staging file; first JSON status line on stdout, then progress every 4 MiB, final JSON status. |
| `upload-status --job <id> --role <role>` | Prints one JSON object with `received_bytes`, `bytes`, `sha256_ok`, `complete`. |
| `download-artifact --job <id> --what ipa [--offset <n>]` | Streams the IPA to stdout (resumable by byte offset); the client hashes while writing. `--what manifest-txt` streams the build manifest copy instead. |
| `doctor --json` | Prints the environment report used by the Builder's host setup screen. |

All subcommands except `upload`/`download-artifact` speak NDJSON and exit when
their input ends. Binary payloads are never carried inside the NDJSON control
stream.

Recommended OpenSSH options for the Builder's calls:

```text
-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
-o ControlMaster=auto -o ControlPath=<profile>/ssh-%r@%h:%p -o ControlPersist=60
```

Connection multiplexing keeps a build session to one authenticated connection
and one host-key check. The Builder MUST NOT enable agent forwarding, X11,
remote port forwarding or `ProxyCommand` without explicit user configuration.

#### 3.1.2 SSH transport notes

- The control channel runs `stdio`, which proxies to the Agent daemon through a
  local Unix socket. Jobs live in the daemon, so closing the SSH connection does
  not cancel a job.
- If the daemon is not running, `ssh-dispatch` starts it (detached) by default;
  `--no-spawn` makes that an error (`daemon_unavailable`) for strict setups.
- The forced-command `authorized_keys` entry is written by the user during
  pairing; the Builder shows the exact line to paste and the fingerprint to
  verify. The Builder does not edit `authorized_keys` remotely.

### 3.2 HTTP binding (same machine or SSH tunnel)

Used when the Builder runs on the Mac, or when the user reaches a remote Agent
through `ssh -L` (recommended for HTTP over the internet). The daemon listens
on `127.0.0.1:7676` by default.

- `POST /v1/frames` — one NDJSON control frame per request; response is one
  JSON frame. (Also usable from `curl` for debugging.)
- `GET /v1/events?job_id=<id>&since_seq=<n>` — Server-Sent Events stream of
  `job.event` frames (status changes and log lines), resumable by sequence.
- `PUT /v1/jobs/<id>/inputs/<role>?offset=<n>` — raw upload body; `200` with a
  JSON progress frame. Supports resume.
- `GET /v1/jobs/<id>/inputs/<role>/status` — upload progress.
- `GET /v1/jobs/<id>/artifact/<name>` — artifact download; supports `Range`
  and returns `Content-Length`, `Content-Disposition`, `X-Content-SHA256`.
- `GET /v1/health` — unauthenticated only on loopback: version + `ready`.
- All `/v1/*` except health require `Authorization: Bearer <token>`.
- Loopback may be plain HTTP; any non-loopback bind MUST use TLS and the client
  MUST pin the certificate SHA256 fingerprint recorded at pairing. Plain HTTP
  to a non-loopback address is rejected by the Builder.

### 3.3 Framing

- Control frames are single-line JSON objects (UTF-8, no BOM, LF-terminated,
  ≤ 1 MiB each; senders MUST keep them far smaller).
- Every frame has `"type"` (string). Requests carry a client-chosen `"tag"`
  (string, unique per session); replies echo it.
- Unknown frame types MUST be ignored by an Agent (forward compatibility for
  optional extensions); unknown fields in known frames MUST be ignored.
- Replies are `"<request>.result"` (success) or `"error"` (failure).
- The SSH `stdio` channel is a stream of frames in both directions; it carries
  asynchronous `job.event` frames interleaved with replies. Order within a
  channel is preserved by TCP; the client correlates by `tag` and `job_id`.
- Keepalive: the client sends `{"type":"ping","tag":"..."}` if idle for 30 s;
  the Agent replies `{"type":"pong","tag":"..."}`. Two missed pongs (60 s)
  leave the transport "degraded" but the job keeps running.

## 4. Authentication and pairing

### 4.1 SSH

Pairing steps (performed once per host):

1. Builder creates a dedicated Ed25519 key pair in its data directory with
   `0600` permissions (`<profile-dir>/id_ed25519`); it does not reuse the
   user's personal key by default.
2. Builder prints the public key and the exact `authorized_keys` line; the user
   adds it on the Mac.
3. Builder fetches the host key (`ssh-keyscan`), shows its SHA256 fingerprint
   for the user to verify on the Mac, and only after confirmation writes it to
   the profile-private `known_hosts` file. It then connects with
   `StrictHostKeyChecking=yes` and runs `doctor --json` to confirm user, Agent
   version, toolchain and data root.
4. The profile stores: host, port, user, key path, known-host entry, Agent
   version and capabilities.

There is no token in SSH mode. Authorization is the SSH key (restricted by the
forced command) plus the Agent's own user check. Agent-side `--allowed-user`
defaults to the invoking user and MUST match; `root` is refused.

### 4.2 Token (HTTP)

1. On the Mac, `builder-agent pair` prints a one-line pairing payload:
   `3ds2apple-builder://pair?host=...&port=...&token=...&fp=<tls-sha256>` (or a
   multi-field block for manual entry when the payload is too long).
   The token is 32 random bytes, base64url. The payload contains a secret:
   paste it into the Builder and do not keep it in shell history or issue
   reports.
2. The Builder stores the token in the OS credential store (Windows Credential
   Manager, Secret Service/libsecret, macOS Keychain) keyed by profile id. It
   MUST NOT write the token to the config file, logs or history.
3. The Agent stores only `sha256(token)` in its config file (`0600`) and
   compares in constant time.
4. `builder-agent token rotate` invalidates the old token; the Builder shows
   "re-pair required" on `unauthorized`.
5. Scopes are not split in v1 (one token has the full client scope set:
   jobs create/read/cancel/delete/artifact). The field is reserved.

No passwords are accepted anywhere. The Agent MUST rate-limit failed
authentication (default: 10 failures per 5 minutes per source, then `429` with
`retry_after_seconds`) and MUST log authentication failures to its audit log
without secret values.

## 5. Session handshake

First frame from the client on a new control channel:

```json
{
  "type": "hello",
  "tag": "t-1",
  "protocol": "3ds2apple-builder/1",
  "client": { "name": "3ds2apple-builder", "version": "0.1.0", "os": "windows", "os_version": "11" },
  "features": ["events.stream", "upload.resume", "artifact.range", "path.input"]
}
```

Agent reply:

```json
{
  "type": "hello.result",
  "tag": "t-1",
  "protocol": "3ds2apple-builder/1",
  "agent": {
    "version": "0.1.0",
    "id": "mac-mini-kitchen",
    "os": "macos",
    "os_version": "14.8",
    "arch": "arm64"
  },
  "capabilities": [
    "events.stream", "upload.resume", "artifact.range", "path.input",
    "keep_input", "gpu_options", "job.delete", "job.list"
  ],
  "toolchain": {
    "xcode": "16.4",
    "ios_sdk": "18.5",
    "rust": "1.99.1",
    "rust_target_installed": true,
    "xcodegen": "2.44.1",
    "python": "3.11.9",
    "git": "2.46.0"
  },
  "source": {
    "repo": "/Users/<user>/src/3ds2apple",
    "revision": "4cc6186...",
    "dirty": false,
    "scripts_present": true
  },
  "limits": {
    "max_input_bytes": 8589934592,
    "max_queued_jobs": 4,
    "max_concurrent_builds": 1,
    "artifact_retention_hours": 168,
    "job_retention_hours": 168
  },
  "ready": true,
  "min_client": "0.1.0",
  "refusals": []
}
```

Rules:

- Protocol string is `3ds2apple-builder/<major>`. Different major → `426`
  `unsupported_protocol`; the Builder MUST refuse to create jobs and tell the
  user to update.
- Servers ignore unknown `features`/`capabilities` entries. Clients MUST NOT
  use a feature the Agent did not advertise.
- `ready:false` means the Mac is missing a required piece (`refusals` lists
  codes such as `toolchain_missing`, `repo_missing`); the Builder still shows
  the host and a fix path instead of failing the whole setup.
- A client `version` older than the Agent's `min_client` gets an
  `unsupported_client` error on first job creation (not on hello, so the user
  can still see diagnostics).
- The Agent MUST NOT change the source checkout mirror as a side effect of a
  session. It reports what it has; see §9 on revision pinning.
- The first frame on a channel MUST be `hello`. Any other frame before a
  successful handshake is rejected with `bad_request` and the channel is
  closed.

## 6. Job life cycle

### 6.1 States

```text
                input verified
request ──► created ──────────────► queued ──slot──► running ──success──► succeeded
               │                       │                 │
               │ cancel                │ cancel          ├── cancel ──► canceling ──► canceled
               ▼                       ▼                 │
            canceled                canceled             ├── stage error ────────► failed
                                                         └── agent restart ──────► interrupted
```

| State | Terminal | Meaning |
|---|---|---|
| `created` | no | Job accepted; waiting for its inputs to be uploaded/verified. |
| `queued` | no | Inputs verified; waiting for a build slot. |
| `running` | no | A build slot is held; `stage` tells what is happening. |
| `canceling` | no | Cancellation requested; processes are being stopped and data cleaned. |
| `succeeded` | yes | Artifact available for download. |
| `failed` | yes | A stage failed; error object and log tail available. |
| `canceled` | yes | Canceled by the client; no artifact. |
| `interrupted` | yes | The Agent restarted while the job was active; no artifact. |

`stage` is meaningful only for `running`/`canceling`:

| Stage | Work |
|---|---|
| `preparing` | Source/toolchain/disk checks, cached runtime build. |
| `recompiling` | 3dsrecomp generation and compiling generated C to objects/archive. |
| `linking` | Linked Zakuro runtime, `libgame.a` collection, app link inputs. |
| `packaging` | `xcodegen` + `xcodebuild`, unsigned IPA packaging. |
| `verifying` | SHA256/manifest/linked-code checks, artifact finalisation. |

Transitions are monotonic (a job never goes back to an earlier state or
stage). The Agent writes each transition to its job store before reporting it,
so a reconnect sees the same history.

### 6.2 Creating a job

Request:

```json
{
  "type": "job.create",
  "tag": "t-10",
  "request_id": "6f1c2b1e-...",
  "game": {
    "name": "pokemon-y",
    "display_name": "Pokemon Y",
    "bundle_id": null,
    "title_id": null
  },
  "inputs": [
    { "role": "rom", "name": "Pokemon Y.cci", "bytes": 4294967296, "sha256": "9f2c..." }
  ],
  "options": {
    "embed_moltenvk": true,
    "hardware_renderer": false,
    "clean": false,
    "keep_input": false
  },
  "source": { "expected_revision": "4cc6186..." },
  "transport": { "mode": "upload" }
}
```

Field rules:

- `request_id` is the **idempotency key** (UUID or ULID). Repeating a
  `job.create` with the same `request_id` and identical parameters returns the
  same job (`job.created` with the original `job_id`); different parameters are
  `conflict` (409). This makes "the response was lost" safe to retry.
- `game.name`: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; it becomes a path
  component and an argument to the scripts, which enforce the same rule.
- `game.display_name`: 1–48 printable characters, no control characters, no
  path separators; used as the app's display name.
- `game.bundle_id`: optional reverse-DNS; if omitted the Agent reports the
  default the scripts use (`com.kratos.3ds2apple.<name>`), and the Builder
  shows it before confirming.
- `game.title_id`: optional 16 hex characters; when omitted the scripts derive
  it during recompilation and the artifact manifest reports the value.
- `inputs`: exactly one `rom`; zero or one `keys` in v1. `name` is display-only
  metadata (it is never used as a path); `sha256` is lowercase hex; `bytes`
  must be > 0 and ≤ the Agent's `max_input_bytes`.
- `options.embed_moltenvk`: default `true` (matches the documented hardware
  rendering build). `hardware_renderer` maps to `ZAKURO_IOS_HARDWARE`; default
  `false` (the presented path turns the renderer on by itself; see
  [METAL.md](../ios/zakuro-ios/METAL.md) §7).
- `options.clean`: force a clean build, discarding Agent-side reuse.
- `options.keep_input`: explicit opt-in; default `false`. If true the Builder
  MUST have shown a privacy warning and the job status MUST report
  `inputs_kept:true`.
- `transport.mode`: `"upload"` (default) or `"path"` (the file already exists on
  the Mac; the Agent copies it into the job directory). `path` mode is only
  available when the Agent advertises `path.input` and the profile was created
  with an allowed path prefix.

Success reply:

```json
{
  "type": "job.created",
  "tag": "t-10",
  "job_id": "job_01J8Z3K4T9",
  "state": "created",
  "upload": {
    "roles": [
      { "role": "rom", "bytes": 4294967296, "sha256": "9f2c..." }
    ],
    "chunk_hint": 8388608,
    "expires_at": "2026-11-12T21:00:00Z"
  },
  "limits": { "max_queued_jobs": 4, "max_concurrent_builds": 1 }
}
```

Validation the Agent MUST perform before answering: protocol/version, game
name/display name/bundle id shapes, input roles and sizes, declared free disk
space against its threshold (default 20 GiB, configurable; failure is
`insufficient_storage` with `details.required_bytes`/`available_bytes`), source
revision check (§9), queue capacity (`queue_full`, retryable with
`retry_after_seconds`), and `keep_input` policy.

If validation fails, no job is created and no input is accepted.

### 6.3 Input transfer

Upload (both bindings) is chunked and resumable:

1. Client asks for the current status (`upload-status` / GET status). Fresh
   upload returns `received_bytes: 0`.
2. Client streams bytes from that offset (`upload --offset`, or `PUT` with
   `?offset=`). The Agent appends to `jobs/<id>/input/.staging/<role>.part`.
3. On completion the Agent verifies total `bytes` and `sha256`; success renames
   the file to `jobs/<id>/input/<role>` with `0600`, then reports
   `upload.complete`. Correct total but wrong hash → delete the staging file,
   `input_invalid` with `retryable:true` (start over).
4. When every declared role has been uploaded and verified, the **client**
   sends `job.input_ready`. The Agent re-checks that all declared roles exist
   with the declared size/hash and only then moves the job to `queued`; this
   makes the transition explicit even though each successful upload already
   moved its own file into place.

Rules:

- Re-uploading a role that is already complete is a `conflict` unless the
  staging state was reset by `input_invalid`.
- A role not declared in `job.create` is rejected (`bad_request`); a declared
  role that never arrives keeps the job in `created` until `expires_at`
  (default 60 min), then the Agent cleans up and the job becomes `canceled`
  (`input_timeout` recorded).
- No progress for 120 s aborts the upload with `upload_stalled`; the staging
  file and offset are kept for resume.
- Path mode: after `job.create`, the client sends
  `job.input_from_path` with the absolute path per role; the Agent
  canonicalises it, checks it is under an allowed prefix of the configured
  allowlist, is a regular file (not a symlink), matches the declared size and
  hash, then **copies** it into the job input directory. The user's original
  file is never moved, modified or deleted.
- Keys and other supplementary inputs follow the same flow; the Agent never
  logs their contents, and they are deleted with the rest of the inputs.

### 6.4 Queue and build slots

- The Agent runs at most `max_concurrent_builds` builds (default **1**) and
  queues at most `max_queued_jobs` (default **4**). A full queue rejects new
  jobs with `queue_full`; the Builder shows "host busy, try again in N s" and
  may retry with the same `request_id`.
- Queue order is FIFO by creation time; a canceled/expired job leaves the queue
  immediately.
- Starting a job moves it to `running` with `stage: "preparing"`; the slot is
  released at every terminal state, including failure and cancellation.
- Builds are serialised because the reference build host has 8 GB RAM and
  parallel xcodebuild/cargo runs are not safe there. Larger hosts may raise the
  limit in the Agent config.

### 6.5 Progress and status

`job.status` request/reply (or the same object inside a `job.event`):

```json
{
  "type": "job.status",
  "tag": "t-20",
  "job": {
    "job_id": "job_01J8Z3K4T9",
    "state": "running",
    "stage": "recompiling",
    "stage_state": "running",
    "percent": 42,
    "detail": { "files_done": 318, "files_total": 761, "stage_started_at": "2026-11-12T19:41:02Z" },
    "created_at": "2026-11-12T19:33:10Z",
    "started_at": "2026-11-12T19:40:55Z",
    "updated_at": "2026-11-12T19:43:40Z",
    "finished_at": null,
    "queue_position": 0,
    "stages": [
      { "name": "preparing", "state": "done", "duration_ms": 2003 },
      { "name": "recompiling", "state": "running", "duration_ms": null },
      { "name": "linking", "state": "pending" },
      { "name": "packaging", "state": "pending" },
      { "name": "verifying", "state": "pending" }
    ],
    "source_revision": "4cc6186...",
    "toolchain": { "xcode": "16.4", "ios_sdk": "18.5" },
    "inputs_present": true,
    "inputs_kept": false,
    "warnings": [],
    "error": null,
    "artifact": null
  }
}
```

- `percent` is coarse and honest (stage base + parsed sub-progress). It MAY be
  absent/`null` when the stage cannot estimate; UIs MUST fall back to stage +
  log activity rather than showing a fake number.
- `detail` counters are best-effort when the scripts print enough to parse
  file counts; they are not a contract.
- Status calls are cheap and idempotent; clients SHOULD prefer the event
  stream and use status polling only as a fallback (every 2 s while running).
- The Agent MUST report the exact `source_revision` and toolchain it used in
  both status and artifact manifest.

### 6.6 Logs and events

The client subscribes to a job:

```json
{ "type": "job.subscribe", "tag": "t-30", "job_id": "job_01J8Z3K4T9", "since_seq": 0 }
```

Agent replies `job.subscribe.result` with the current snapshot, then sends
`job.event` frames:

```json
{ "type": "job.event", "seq": 187, "job_id": "job_01J8Z3K4T9", "ts": "2026-11-12T19:44:01.120Z",
  "kind": "log", "stage": "recompiling", "source": "script", "level": "info",
  "line": "[build-recomp-ios] compiling generated code (318/761)" }
```

```json
{ "type": "job.event", "seq": 188, "job_id": "job_01J8Z3K4T9", "ts": "...",
  "kind": "state", "state": "running", "stage": "linking" }
```

- `seq` is a monotonic per-job sequence number persisted with the job; it is
  the resume cursor. Reconnecting with `since_seq` replays events after that
  number from the Agent's retained log.
- Event kinds: `state` (state/stage change), `log` (a line), `warning`,
  `artifact` (artifact ready), `end` (terminal state reached; the stream can be
  closed after this), `heartbeat` (keepalive at least every 15 s).
- Log line limit is 32 KiB; longer lines are split into multiple `log` events
  with `line_part`/`line_parts` and must be reassembled by the client.
- Log sources: `agent` (job/orchestration messages), `script` (the build
  scripts' stdout/stderr), `xcodebuild` (when the scripts stream it). The Agent
  marks each line with the stage that produced it.
- Retention: the Agent keeps a bounded in-memory tail (default 2,000 lines) and
  the full per-job log on disk until the job is deleted/GC'd. A replay request
  older than what is retained returns `log_truncated:true` and the earliest
  available `seq`.
- The Agent MUST NOT log input file contents, keys, tokens or environment
  values that could contain secrets. Local paths and the ROM file name may
  appear; the Builder offers a redacted export for bug reports.

### 6.7 Cancellation

Request:

```json
{ "type": "job.cancel", "tag": "t-40", "job_id": "job_01J8Z3K4T9", "reason": "user_canceled" }
```

Semantics:

- `created`: delete staging inputs, job → `canceled`.
- `queued`: remove from queue, clean job data, job → `canceled`.
- `running`: job → `canceling`; the Agent sends SIGTERM to the **process group**
  of the current script, waits up to 30 s, then SIGKILLs the group; waiting
  child processes (`cargo`, `clang`, `xcodebuild`, `3dsrecomp`) MUST be covered
  by the process group or an explicit child list. It then cleans the job data
  and reports `canceled`.
- `succeeded`/`failed`/`canceled`/`interrupted`: `conflict` (409) — the
  terminal state is reported so the client can stop waiting.
- `job.cancel` is idempotent while non-terminal; repeated calls return
  `canceling`.
- Cancellation is cooperative and bounded: the reply to `job.cancel` is
  `job.cancel.result` with the new state; the terminal transition arrives as a
  `state` event. The client MUST NOT assume the job is dead until `canceled` or
  `interrupted` is observed or a status call says so.
- When the client disappears, a job keeps running. There is no automatic
  cancel on disconnect in v1 (a build takes tens of minutes; a temporary
  network drop must not destroy it). The UI explains this on "Quit while
  building".

### 6.8 Artifact

When `stage: "verifying"` completes, the Agent writes:

```text
jobs/<id>/out/
  <name>-AOT.ipa          unsigned IPA
  manifest.txt            copy of build/ios/<name>/manifest.txt
  artifact.json           the machine-readable artifact record below
```

`artifact.json`:

```json
{
  "artifact_version": 1,
  "job_id": "job_01J8Z3K4T9",
  "game": {
    "name": "pokemon-y",
    "display_name": "Pokemon Y",
    "bundle_id": "com.kratos.3ds2apple.pokemon-y",
    "title_id": "0004000000055E00"
  },
  "ipa": { "name": "pokemon-y-AOT.ipa", "bytes": 98765432, "sha256": "..." },
  "manifest_txt": { "name": "manifest.txt", "bytes": 921, "sha256": "..." },
  "source": {
    "repo_revision": "4cc6186...",
    "expected_revision": "4cc6186...",
    "match": true
  },
  "toolchain": { "xcode": "16.4", "ios_sdk": "18.5", "rust": "1.99.1", "xcodegen": "2.44.1" },
  "build": { "started_at": "...", "finished_at": "...", "warnings": [] },
  "retention_until": "2026-11-19T19:50:00Z"
}
```

- The IPA SHA256 MUST equal the `ipa_sha256` in `manifest.txt` and the SHA256
  the build scripts printed. A mismatch fails verification
  (`internal`/`verify_failed`) and the job becomes `failed`.
- Download via HTTP `GET /v1/jobs/<id>/artifact/<name>` (Range supported) or
  SSH `download-artifact --what ipa`. The machine-readable artifact record is
  fetched with `{"type":"artifact.manifest","tag":"...","job_id":"..."}` →
  `artifact.manifest.result` (HTTP: `GET /v1/jobs/<id>/artifact.json`); the
  build manifest copy is available as `manifest.txt`.
- The client MUST recompute the IPA SHA256 while writing and compare with
  `artifact.json`; on mismatch it MUST delete the local file, report
  `artifact_corrupt` locally and re-download from offset 0 (resumed bytes
  cannot be trusted after a mismatch).
- After a verified download the client sends
  `{"type":"artifact.ack","tag":"...","job_id":"...","artifact_sha256":"..."}`
  (fire-and-forget). The Agent's retention policy may then delete earlier if
  configured; the default still keeps the artifact until the retention TTL.
- `artifact_not_ready` (409) is returned while the job is non-terminal or
  failed.

### 6.9 Listing jobs

The Builder keeps its own local history; the Agent can also list what it still
holds for reconciliation and for CLI `jobs`:

```json
{ "type": "job.list", "tag": "t-50", "limit": 20, "cursor": null }
```

Reply `job.list.result`:

```json
{
  "type": "job.list.result",
  "tag": "t-50",
  "jobs": [
    {
      "job_id": "job_01J8Z3K4T9",
      "state": "succeeded",
      "game": { "name": "pokemon-y", "display_name": "Pokemon Y" },
      "created_at": "2026-11-12T19:33:10Z",
      "finished_at": "2026-11-12T19:58:02Z",
      "artifact": { "name": "pokemon-y-AOT.ipa", "bytes": 98765432, "sha256": "..." }
    }
  ],
  "next_cursor": null
}
```

Newest first, active jobs before terminal ones. `job.delete` removes an entry
from this list.

### 6.10 Cleanup, retention and deletion

| Data | When removed (default) | Configurable |
|---|---|---|
| Input ROM / keys | At the terminal state (`succeeded`, `failed`, `canceled`, `interrupted`) unless `keep_input` was explicitly set | `inputs.keep=false` |
| Generated C, objects, archives, generated Xcode project, name-keyed `build/` outputs | At the terminal state (logs are kept), or immediately after packaging on success | `build.clean_after_success=true` |
| Job logs/status | At job TTL: 168 h after terminal state | `job_retention_hours` |
| Artifact (IPA/manifest) | 168 h after terminal state, or after `job.delete` | `artifact_retention_hours` |
| User's original file in path mode | Never touched | — |
| Abandoned `created` job with no input | 60 min after creation | `input_timeout_minutes` |

- `job.delete` purges a terminal job's directory (metadata, logs, artifact) and
  is idempotent. It is the "remove this build from the Mac" action in the UI;
  non-terminal jobs must be cancelled first (`conflict`).
- `builder-agent gc` enforces TTLs; it also removes orphaned staging files
  older than the input timeout.
- The status reports `inputs_present`/`inputs_kept` so the UI can state whether
  the ROM is still on the Mac. The Agent verifies deletion (file must be gone)
  before reporting a terminal state; if deletion fails, the job still reaches
  its terminal state but carries warning `input_cleanup_failed` with the path —
  the user must clean up manually.
- On uninstall, the docs say to remove the Agent data root; `builder-agent gc
  --all --yes` exists for that.
- The Builder keeps only job metadata, redacted logs and the downloaded IPA in
  its own data directory; its staging copy of the ROM is deleted after upload
  completion/abort. The Builder's "delete local job" removes its history and
  artifacts.

### 6.11 Agent restart and recovery

- Job state (request metadata, state, stage, seq, artifact record) is persisted
  in `jobs/<id>/job.json` before each transition is reported.
- On startup, any job in `created`/`queued`/`running`/`canceling` is marked
  `interrupted` with error code `agent_restarted` (no automatic resume in v1).
  Orphaned child processes from the previous daemon are killed (the daemon
  records process-group ids; if it cannot prove they are gone it refuses to
  start a new build and reports `stale_build_processes`, with the pids, so the
  user can fix it).
- Terminal jobs, their logs and artifacts remain available after a restart.
- The client sees `interrupted` with a clear "the Mac restarted or the Agent
  was stopped; start a new build" message. It MUST NOT silently retry a
  multi-hour build without user confirmation.

## 7. Directory isolation on the Agent

```text
<data root>/                                 0700
  config.toml                                0600  (no secrets: token hash only)
  audit.jsonl                                0600  (job created/canceled/downloaded, no contents)
  agent.sock                                 Unix socket for the CLI/stdio proxy
  jobs/
    job_01J8Z3K4T9/                          0700
      job.json                               owner-only state; no secret material
      input/
        rom                                   0600  (deleted at terminal state)
        keys                                  0600  (optional; same life cycle)
        .staging/<role>.part                  upload scratch
      logs/                                   per-stage captured logs (deleted with TTL)
      out/
        <name>-AOT.ipa                       0600
        manifest.txt
        artifact.json
  cache/
    moltenvk/                                downloaded once, SHA256-pinned (never committed)
    repo/                                    optional managed checkout (if the user asks the Agent to manage it)
  tmp/                                       cleaned by gc
```

The **build products do not live under the job directory**: the existing
scripts write to the source checkout's gitignored tree
(`build/game/<name>/`, `build/ios/<name>/`, `IPA/` under the checkout). The
Agent runs each job with the checkout as the working directory, redirects the
IPA to `out/` with `--out-dir`, and removes the name-keyed build paths at the
terminal state. A per-job clone/copy of the checkout (APFS clone) is the
forward path for hard filesystem isolation; v1 relies on the serialised build
slot plus name-keyed cleanup instead, because the scripts are written around a
single repository root.

Rules:

- The Agent runs as the user, never as root; the daemon refuses to start as
  `root`. It respects `umask 077` and creates the data root with `0700`.
- **One job, one directory.** The job id is generated by the Agent (ULID), not
  by the client, so path components are not client-controlled. The game `name`
  is validated against `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` and is the only
  client string that reaches a filesystem path (via the scripts' own
  validation).
- Inputs are staged as fixed role file names (`rom`, `keys`), not with the
  user's file name; the client-provided `name` is display metadata only.
- The build uses the existing checkout's `build/` layout because the scripts
  expect it. Because builds are serialised (one build slot), jobs do not race
  on `build/` or `third_party/`. At every terminal state the Agent removes
  `build/game/<name>/`, `build/ios/<name>/`, the generated Xcode project and
  any `IPA/<name>-*` left in the checkout, and refuses to start a job whose
  `name` collides with an existing build directory it does not own. The
  `--isolated-target` flag keeps Cargo target directories per game.
- If the Agent manages its own checkout (`repo.managed`), it lives under
  `cache/repo/` and is updated only by explicit `builder-agent update --repo`,
  never behind the user's back. A user-managed checkout path is read/executed
  but the Agent only adds/removes the gitignored `build/` and `IPA/` outputs it
  created for the job.
- Absolute paths in the protocol exist only in `input_from_path` (allowlisted
  prefix) and in `doctor` output. The client cannot ask the Agent to read or
  write an arbitrary path.
- Symlinks are refused for inputs and inside the data root the Agent will not
  follow them for cleanup (it removes entries it created; it never runs a
  recursive delete on a path that resolves outside the job directory).

## 8. Failure semantics

### 8.1 Error frame

```json
{
  "type": "error",
  "tag": "t-31",
  "error": {
    "code": "build_failed",
    "message": "xcodebuild failed (exit 65) while linking the app",
    "stage": "packaging",
    "hint": "The link order check failed: -lzakuro_ios must come before -lgame. Check the Agent log for the undefined symbol.",
    "retryable": false,
    "details": { "exit_code": 65, "log_ends_at_seq": 1204 },
    "log_tail": ["... last lines ..."]
  }
}
```

`code` is stable and machine-readable; `message` is for humans; `hint` is a
actionable suggestion; `retryable` says whether the same request may be
retried without user changes; `stage` identifies the failing build stage when
applicable; `log_tail` is at most 200 lines and MUST be white-listed the same
way as live logs.

### 8.2 Error codes

| Code | HTTP | Meaning / typical fix | Retryable |
|---|---|---|---|
| `bad_request` | 400 | Malformed frame, invalid name/role/option. Fix the request. | no |
| `unsupported_protocol` | 426 | Protocol major mismatch. Update Builder or Agent. | no |
| `unsupported_client` | 426 | Builder below the Agent's minimum client version. Update Builder. | no |
| `unsupported_agent` | 426 | Agent below the Builder's minimum Agent version for the pinned scripts. Update the Agent. | no |
| `unauthorized` | 401 | Missing/invalid token or key not accepted. Re-pair. | no |
| `forbidden` | 403 | Path outside the allowlist, wrong user, disallowed operation. | no |
| `not_found` | 404 | Unknown job/artifact. | no |
| `conflict` | 409 | Wrong state for the operation (e.g. cancel a finished job, delete a running job). Read status and continue. | no |
| `queue_full` | 429 | Host is busy at its queue limit. Retry after `retry_after_seconds`. | yes |
| `rate_limited` | 429 | Too many requests/attempts. Back off. | yes |
| `payload_too_large` | 413 | Input exceeds `max_input_bytes`. | no |
| `insufficient_storage` | 507 | Not enough free disk on the Mac. Free space on the host. | no (until fixed) |
| `toolchain_missing` | 412 | Xcode/Rust target/xcodegen/Python missing or Xcode not initialised. Fix the Mac. | no (until fixed) |
| `repo_missing` | 412 | Source checkout not configured/found or scripts absent. Fix the Mac. | no |
| `repo_dirty` | 412 | Checkout has uncommitted changes. Commit/stash or use the override. | no |
| `source_mismatch` | 412 | Checkout revision ≠ expected revision. Update the Mac checkout or the Builder. | no |
| `input_invalid` | 422 | ROM/keys rejected (size/hash/extension/format). Re-upload or pick another file. | yes if hash mismatch |
| `input_timeout` | 408 | Declared input never arrived; job canceled. Create a new job. | no |
| `upload_stalled` | 408 | No upload progress for 120 s; resume. | yes |
| `build_failed` | 422 | A build stage failed; inspect `stage`, `hint`, log. | no (until fixed) |
| `verify_failed` | 500 | Artifact/manifest self-check failed on the Agent. Report a bug. | yes once |
| `artifact_not_ready` | 409 | Artifact requested before success. Wait. | no |
| `daemon_unavailable` | 503 | Agent daemon not running and auto-start disabled. Start it. | yes |
| `timeout` | 504 | Stage exceeded its time limit (see §8.4). | no |
| `interrupted` | — | Agent restarted during the job. Start a new build. | no |
| `internal` | 500 | Unexpected Agent bug. Report with logs. | yes once |

Build-failure mapping the Agent SHOULD apply (from
[scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md) and
[docs/build.md](../docs/build.md) troubleshooting):

| Build log symptom | Agent hint |
|---|---|
| `missing librecomp.a` | 3dsrecomp step did not finish; see the `recompiling` log. |
| Undefined `_recomp_*` at app link | `libgame.a` missing or linked before `libzakuro_ios.a`; the script should have caught it — check the log and report. |
| `AOT: linked, interpreting` in build output | This is a runtime diagnostic, not a build failure; it usually means the title ID/ABI did not match. Re-run with the matching title and pinned revisions. |
| `no space left on device` / OOM-killed compiler | Clean the job/host, retry with `--auto-serial` (already the default in the Agent). |
| `xcode-select: error` / SDK not found | `toolchain_missing`; run the host doctor. |
| MoltenVK missing / framework copy failed | Agent provisioning failed; run `builder-agent setup --moltenvk` and check the pinned SHA256. |

### 8.3 Retry and resume matrix

| Situation | Client behaviour |
|---|---|
| `job.create` reply lost / connection dropped | Retry the same `request_id`; get the original job. |
| Upload interrupted | Query upload status, resume from `received_bytes`. |
| Log stream dropped | Re-subscribe with the last `seq`; replay missing events. |
| Status poll failed | Retry with backoff; the job keeps running on the Agent. |
| Artifact download interrupted | Resume with the received offset, then verify SHA256. |
| Artifact SHA256 mismatch | Delete local file, re-download from 0, verify again; report failure to the user if it repeats. |
| `queue_full` / `rate_limited` | Respect `retry_after_seconds`, retry same request id. |
| `unauthorized` | Stop; show re-pair steps. No automatic retry. |
| Validation/toolchain/repo/build failure | No automatic retry; show hint + log. "Retry" in the UI creates a **new** job with a new `request_id` after user confirmation. |
| `interrupted` | No automatic retry; start a new build explicitly. |
| Protocol/version mismatch | Stop; ask user to update the older side. |

Clients MUST use exponential backoff with jitter for retryable transport
failures (start 1 s, cap 30 s) and MUST cap automatic retries (suggested: 5
for upload chunks/streams, 3 for downloads, 1 for `internal`).

### 8.4 Default timeouts

| Operation | Default | Behaviour on expiry |
|---|---|---|
| Handshake | 10 s | `timeout`, transport closed |
| Control frame idle | 60 s | Client sends `ping`; after 3 unanswered pings the transport is considered dead |
| Upload inactivity | 120 s | `upload_stalled`; client resumes |
| Input arrival for a `created` job | 60 min | Job canceled (`input_timeout`) |
| `preparing` (incl. first-run runtime build) | 45 min | `timeout` (skill: first run clones and builds the runtime; later runs are cached) |
| `recompiling` | 4 h | `timeout` |
| `linking` | 2 h | `timeout` |
| `packaging` | 1 h | `timeout` |
| `verifying` | 10 min | `timeout` |
| Whole job | 8 h | `timeout` |
| Cancellation grace (SIGTERM → SIGKILL) | 30 s | SIGKILL the process group |

All values are Agent config; the Agent reports the effective ones in `welcome`.

## 9. Versioning, source pinning and compatibility

- **Protocol version:** `3ds2apple-builder/1`. Additive changes (new frame
  types, new optional fields, new error codes) keep version 1; clients ignore
  unknown frames/fields. Removing fields or changing semantics requires
  version 2 and a negotiation path (the Agent rejects unknown majors).
- **Versions reported:** Builder version, Agent version, protocol version,
  toolchain versions, source revision. The Builder shows them in the host
  details and the artifact page; bug reports include them.
- **Source pinning:** the Builder ships an expected 3ds2apple source revision
  (the release tag/commit it was built from) and asks the Agent to confirm it.
  The Agent compares with `git rev-parse HEAD` of its configured checkout:
  - equal → proceed;
  - different → `source_mismatch` with `expected`/`actual`, unless the user
    enabled `--allow-source-mismatch` for that host (UI shows a warning that
    build reproducibility is not guaranteed);
  - dirty working tree → `repo_dirty` unless `--allow-dirty` is set.
  The Agent never checks out, stashes or fetches on its own during a job.
- **Script contract:** the Agent uses the scripts at the configured revision.
  If the script's CLI or output format changes in an incompatible way, the
  minimum Agent version changes and the Builder refuses to use an older Agent
  (`unsupported_client`/`unsupported_agent`). The Agent parses only the
  documented stdout markers (last stdout line = IPA path; log lines
  `SHA256:`, `manifest:`; `manifest.txt` file) rather than free text.
- **Agent minimum client:** the Agent advertises `min_client`; clients below it
  still get `doctor` and status but cannot create jobs.
- **Minor versions:** the CLI warns (not fails) when the Builder and Agent
  minor versions differ, and states that build assumptions may differ.

## 10. Security requirements on implementations

The following are MUSTs for both sides, beyond the transport-specific rules in
§3–§4:

1. **No shell interpolation.** Commands are executed with argument arrays;
   client strings never reach a shell. Working directory, environment and
   executable path are fixed by the Agent.
2. **Path safety.** Only validated names become path components. Input path
   mode is allowlisted and resolved with `realpath`; symlinks, `..`, control
   characters and names the scripts reject are rejected.
3. **Permissions.** Data root `0700`, job dirs `0700`, inputs/artifacts `0600`,
   config with secrets `0600`. The Agent runs as the login user; refuses root.
4. **Secret hygiene.** Tokens are stored hashed on the Agent and in the OS
   credential store on the client; they never appear in config/logs/argv where
   avoidable (prefer stdin/env over argv for anything sensitive). ROM/keys
   bytes never appear in logs.
5. **TLS.** Non-loopback HTTP binding requires TLS ≥ 1.2 with a certificate
   pinned by SHA256 at pairing; the Builder refuses to downgrade or trust an
   unknown certificate. SSH host keys are verified strictly.
6. **Authentication rate limiting** and an audit log of job actions (no
   contents).
7. **Limits:** max frame 1 MiB, max input per job (configured), max queue,
   max concurrent builds, upload idle timeout, whole-job deadline. An Agent
   MUST reject anything over its limits rather than buffering without bound.
8. **Crash safety.** Replies are only sent after state is persisted; cleanup is
   retried at startup; stale child processes are detected before a new build.
9. **No secrets in artifacts.** `artifact.json` contains only build metadata.
10. **Least privilege for the SSH key** (§3.1) is mandatory for the Builder's
    generated key; the UI explains why and shows the exact restricted
    `authorized_keys` line.

## 11. Conformance and testability

The protocol is designed to be tested without macOS:

- **Fake Agent** (`builder/tests/fake-agent/`): implements both bindings in
  process with scriptable scenarios (success, each error code, upload
  interruption, log replay, restart, artifact corruption). Used by the
  Builder's unit/integration tests on Linux and Windows CI.
- **Golden fixtures** (`builder/tests/protocol/`): versioned JSON requests and
  expected replies/events per scenario; a fixture mismatch fails CI and forces
  a deliberate protocol change review.
- **State-machine tests:** every allowed/forbidden transition, idempotent
  `job.create`/`cancel`/`delete`, cancel during each stage, restart recovery.
- **Chaos tests:** kill the control connection mid-upload and mid-build;
  restart the fake Agent; truncate the artifact download; corrupt one byte;
  replay with an old `seq`; exceed limits; malformed frames (fuzz JSON).
- **Real end-to-end:** Linux host → SSH → macOS VM, per
  [PLAN.md](PLAN.md) §"Local verification". ROM content is the user's own; the
  test uses a small test image where available and the documented sample game
  otherwise.

The CLI also acts as the reference implementation for manual testing:
`zkb host test --json`, `zkb build --json`, `zkb status --json`,
`zkb logs --follow`, `zkb download --verify`.

## 12. Example: happy path over SSH

```text
Builder                                              macOS Agent
  |
  | ssh ... stdio   (forced command runs builder-agent ssh-dispatch)
  |-------------------------------------------------->|
  | {"type":"hello",...}                             |
  |-------------------------------------------------->|  protocol/toolchain/revision check
  |<--------------------------------------------------|  {"type":"hello.result",...}
  | {"type":"job.create",...}                        |
  |-------------------------------------------------->|  validate + persist job
  |<--------------------------------------------------|  {"type":"job.created",...}
  | {"type":"job.subscribe",...}                     |
  |<--------------------------------------------------|  status snapshot
  | ssh ... "upload --job ... --role rom ..." < rom  (separate, multiplexed connection)
  |-------------------------------------------------->|  hash + verify + move into job input
  | {"type":"job.input_ready",...}                   |
  |-------------------------------------------------->|  queue -> preparing -> recompiling ...
  |<--------------------------------------------------|  {"type":"job.event","kind":"state",...}
  |<--------------------------------------------------|  {"type":"job.event","kind":"log",...}   (many)
  |<--------------------------------------------------|  {"type":"job.event","kind":"artifact",...}
  |<--------------------------------------------------|  {"type":"job.event","kind":"end",...}
  | {"type":"artifact.manifest","job_id":...}        |
  |-------------------------------------------------->|
  |<--------------------------------------------------|  artifact.json
  | ssh ... "download-artifact --job ... --what ipa --offset 0" > local.ipa
  |-------------------------------------------------->|  stream bytes; Builder hashes while writing
  | {"type":"artifact.ack","job_id":...}             |
  |-------------------------------------------------->|  record download; retention policy
  | {"type":"job.status","job_id":...}               |
  |-------------------------------------------------->|  {"state":"succeeded","inputs_kept":false}
```

## 13. Example: build failure

```json
{
  "type": "job.event",
  "seq": 1310,
  "job_id": "job_01J8Z3K4T9",
  "ts": "2026-11-12T20:03:12Z",
  "kind": "state",
  "state": "failed",
  "stage": "packaging",
  "error": {
    "code": "build_failed",
    "message": "xcodebuild failed (exit 65) while linking the app",
    "stage": "packaging",
    "hint": "Undefined _recomp_* symbols: check that -lzakuro_ios is listed before -lgame (build-game-ipa.sh enforces this).",
    "retryable": false,
    "details": { "exit_code": 65, "log_ends_at_seq": 1309 },
    "log_tail": ["[build-game-ipa] error: ..."]
  }
}
```

The client renders the hint, the last log lines, a "copy redacted log" button
and a "start new build" action (new job, same inputs; the Agent already
deleted the previous job's inputs unless `keep_input` was set — the UI warns
before the retry).

## 14. Deferred features

Explicitly out of scope for v1 (the protocol reserves room for them, but no
client may rely on them):

- Batch jobs / several games in one job, auto-discovery of titles.
- Incremental resume of a failed stage (`--code-dir`/`--archive` adoption from
  an earlier job), job export/import.
- Multi-file supplementary inputs and named save/update/DLC inputs.
- Checkpointing inside `recompiling` (per-file progress is log-based only).
- Server push when the client did not subscribe (no webhooks, no email).
- Agent auto-update and remote Agent provisioning.
- mTLS client certificates, OAuth, per-scope tokens.
- Artifact encryption at rest on the Mac.
- Remote device installation or signing hooks.
