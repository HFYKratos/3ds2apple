#!/usr/bin/env bash
# Local end-to-end check: Linux/macOS host -> Build Agent (fake build) -> IPA.
#
# This exercises the real protocol path (ssh-dispatch local transport, job
# queue, NDJSON logs, resumable upload, artifact download + SHA256 verify,
# input cleanup) without macOS, Xcode or a ROM. It is a convenience wrapper
# around the same scenario the `builder-cli` integration tests cover.
#
# Usage: builder/tests/e2e/local_fake_agent.sh [--plan success|fail-packaging|cancel]
set -euo pipefail

PLAN="success"
if [[ "${1:-}" == "--plan" ]]; then
  PLAN="${2:?--plan needs a value}"
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILDER_DIR="$REPO/builder"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zkb-e2e.XXXXXX")"
AGENT_PID=""
cleanup() {
  [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== building workspace binaries =="
(cd "$BUILDER_DIR" && cargo build --quiet --workspace)
BIN="$BUILDER_DIR/target/debug"
AGENT="$BIN/builder-agent"
ZKB="$BIN/zkb"
export ZKB_CONFIG_DIR="$TMP/config"

echo "== configuring the Agent (fake build, plan: $PLAN) =="
"$AGENT" init --data-root "$TMP/agent" --checkout "$REPO" --fake-build --fake-plan "$PLAN" --agent-id e2e >/dev/null
"$AGENT" serve --socket "$TMP/agent/agent.sock" --data-root "$TMP/agent" >"$TMP/agent.log" 2>&1 &
AGENT_PID=$!
for _ in $(seq 1 100); do [[ -S "$TMP/agent/agent.sock" ]] && break; sleep 0.05; done
[[ -S "$TMP/agent/agent.sock" ]] || { echo "Agent did not start"; cat "$TMP/agent.log"; exit 1; }

echo "== pairing the local host =="
"$ZKB" host add --name local --local-agent "$AGENT" \
  --local-env "BUILDER_AGENT_DATA_ROOT=$TMP/agent" >/dev/null
"$ZKB" host test local

echo "== creating a test payload (not a ROM) =="
head -c 262144 /dev/urandom >"$TMP/test-payload.cci"

echo "== build =="
"$ZKB" build --host local --rom "$TMP/test-payload.cci" --name demo-game \
  --display-name "Demo Game" --out "$TMP/out" 2>"$TMP/build.err" | tee "$TMP/build.out"
echo
echo "artifacts:"
ls -la "$TMP/out"
echo
echo "SHA256 verification:"
EXPECTED="$(sed -n 's/^ipa_sha256=//p' "$TMP/out/manifest.txt")"
ACTUAL="$(sha256sum "$TMP/out/demo-game-AOT.ipa" | cut -d' ' -f1)"
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "SHA256 mismatch: $EXPECTED != $ACTUAL"; exit 1; }
echo "ok: $ACTUAL"

echo "== agent cleanup check =="
if find "$TMP/agent/jobs" -path '*/input/*' -o -path '*/input/rom' | grep -q .; then
  echo "input files were not deleted"; find "$TMP/agent/jobs" -type f; exit 1
fi
echo "ok: inputs deleted"

echo "== done (temp data in $TMP, removed on exit) =="
