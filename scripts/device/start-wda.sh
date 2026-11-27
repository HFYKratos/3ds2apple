#!/usr/bin/env bash
# start-wda.sh - start the installed WebDriverAgent XCTest runner in the background
# and wait until the WDA server answers, so the other scripts/device/wda-*.sh
# wrappers can drive the phone.
#
# The runner is the app installed by the one-time WDA setup (task-6):
#   pymobiledevice3 developer dvt xcuitest com.kratos.wda.xctrunner
# It keeps running after this script exits; stop it with scripts/device/stop-wda.sh.
# The runner log and a pid file live under WDA_LOG_DIR (default
# /tmp/3ds2apple-wda), never in the repository. If WDA does not become reachable
# in time the script kills the runner again (rollback) and exits 1.
#
# Usage:
#   scripts/device/start-wda.sh [options]
#
# Options:
#   --runner BUNDLE_ID  installed WDA XCTest runner (default WDA_RUNNER or
#                       com.kratos.wda.xctrunner)
#   --port PORT         WDA device port (default WDA_PORT or 8100)
#   --timeout SECONDS   readiness timeout (default WDA_START_TIMEOUT or 90)
#   --log FILE          runner log (default <WDA_LOG_DIR>/start-<timestamp>.log)
#   -h, --help          show this help
#
# Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_RUNNER, WDA_LOG_DIR,
#              WDA_START_TIMEOUT, WDA_HTTP_TIMEOUT (see lib/wda-common.sh).
#
# Exit codes: 0 = runner ready (or already running), 1 = runner/WDA failure,
#             2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Start the installed WebDriverAgent XCTest runner in the background.

Usage:
  scripts/device/start-wda.sh [options]

Options:
  --runner BUNDLE_ID  installed WDA XCTest runner (default WDA_RUNNER or
                      com.kratos.wda.xctrunner)
  --port PORT         WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS   readiness timeout (default WDA_START_TIMEOUT or 90)
  --log FILE          runner log (default <WDA_LOG_DIR>/start-<timestamp>.log)
  -h, --help          show this help

Environment:
  PYMOBILEDEVICE3     pymobiledevice3 command (default: pymobiledevice3; may
                      include arguments, e.g. "/path/venv/bin/python -m pymobiledevice3")
  WDA_PORT, WDA_RUNNER, WDA_LOG_DIR, WDA_START_TIMEOUT, WDA_HTTP_TIMEOUT

The runner log and pid file are written under WDA_LOG_DIR (default
/tmp/3ds2apple-wda); writing them inside the repository is refused. No Apple ID,
credentials or UDID are needed or printed: exactly one device must be connected.
EOF
}

runner="${WDA_RUNNER:-$WDA_DEFAULT_RUNNER}"
port="${WDA_PORT:-$WDA_DEFAULT_PORT}"
start_timeout="${WDA_START_TIMEOUT:-$WDA_DEFAULT_START_TIMEOUT}"
http_timeout="${WDA_HTTP_TIMEOUT:-$WDA_DEFAULT_HTTP_TIMEOUT}"
log=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runner)
      [ "$#" -ge 2 ] || wda_die "--runner requires a value"
      runner="$2"
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || wda_die "--port requires a value"
      port="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || wda_die "--timeout requires a value"
      start_timeout="$2"
      shift 2
      ;;
    --log)
      [ "$#" -ge 2 ] || wda_die "--log requires a value"
      log="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      wda_die "unknown option: $1 (try --help)"
      ;;
    *)
      wda_die "unexpected argument: $1 (try --help)"
      ;;
  esac
done

wda_validate_runner "$runner"
port="$(wda_validate_port "$port")"
start_timeout="$(wda_validate_seconds "$start_timeout" "--timeout")"
http_timeout="$(wda_validate_timeout "$http_timeout")"
wda_prepare_log_dir
if [ -z "$log" ]; then
  log="$WDA_LOG_DIR/start-$(date +%Y%m%d-%H%M%S).log"
fi
wda_require_outside_repo "$log" "runner log"
mkdir -p "$(dirname "$log")" || wda_die "cannot create the log directory: $(dirname "$log")"
wda_require_pmd3

pid_file="$WDA_LOG_DIR/runner.pid"
pid=""

# wait_for_ready PID - poll 'wda status' until the server answers or the timeout expires.
wait_for_ready() {
  local runner_pid="$1" iterations iteration
  iterations=$(( start_timeout / 2 + 1 ))
  for ((iteration = 0; iteration < iterations; iteration++)); do
    if ! kill -0 "$runner_pid" 2>/dev/null; then
      wda_warn "the WDA runner process exited during startup; last lines of $log:"
      tail -n 20 "$log" >&2 2>/dev/null || true
      rm -f "$pid_file"
      return 1
    fi
    if wda_status_reachable "$port" "$http_timeout"; then
      wda_info "WDA runner ready on device port $port (pid $runner_pid); log: $log"
      if grep -q 'ServerURLHere' "$log" 2>/dev/null; then
        wda_info "runner log reports ServerURLHere"
      fi
      return 0
    fi
    sleep 2
  done
  return 2
}

if [ -f "$pid_file" ]; then
  existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if wda_pid_is_runner "$existing_pid" "$runner"; then
    if wda_status_reachable "$port" "$http_timeout"; then
      wda_info "WDA runner already running (pid $existing_pid, device port $port)"
      exit 0
    fi
    wda_info "a WDA runner pid file exists (pid $existing_pid) but WDA is not reachable yet; waiting for it"
    pid="$existing_pid"
  else
    wda_warn "removing stale runner pid file: $pid_file"
    rm -f "$pid_file"
  fi
fi
if [ -z "$pid" ]; then
  orphans="$(wda_runner_pids "$runner")"
  if [ -n "$orphans" ]; then
    wda_die "a WDA runner for $runner is already running without a pid file (pid(s): $(printf '%s' "$orphans" | tr '\n' ' ')); run scripts/device/stop-wda.sh first"
  fi
fi

if [ -n "$pid" ]; then
  if wait_for_ready "$pid"; then
    exit 0
  fi
  wda_warn "the existing runner (pid $pid) did not become reachable; stopping it and starting a fresh one"
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$pid_file"
  wda_fail "the existing WDA runner did not become reachable within ${start_timeout}s; it was stopped. Check the device and retry."
fi

wda_info "starting WDA runner $runner on device port $port (log: $log)"
nohup "${WDA_PMD3[@]}" developer dvt xcuitest "$runner" >>"$log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$pid_file"
wda_info "WDA runner pid $pid; waiting up to ${start_timeout}s for readiness"

if wait_for_ready "$pid"; then
  exit 0
fi

wda_warn "startup failed; stopping the runner pid $pid"
kill -TERM "$pid" 2>/dev/null || true
for ((iteration = 0; iteration < 5; iteration++)); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
kill -KILL "$pid" 2>/dev/null || true
rm -f "$pid_file"
tail -n 20 "$log" >&2 2>/dev/null || true
wda_fail "WDA did not become reachable within ${start_timeout}s on device port $port (log: $log)"
