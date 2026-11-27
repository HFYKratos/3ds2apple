#!/usr/bin/env bash
# stop-wda.sh - stop the WebDriverAgent XCTest runner started by start-wda.sh
# (or an equivalent 'pymobiledevice3 developer dvt xcuitest' process for the
# configured runner).
#
# It sends SIGTERM and only falls back to SIGKILL when the process does not exit
# in time. A process is stopped only when its command line really is the
# 'developer dvt xcuitest <runner>' runner, so an unrelated pymobiledevice3
# process is never touched by a stale pid file.
#
# Usage:
#   scripts/device/stop-wda.sh [options]
#
# Options:
#   --runner BUNDLE_ID  installed WDA XCTest runner (default WDA_RUNNER or
#                       com.kratos.wda.xctrunner)
#   --timeout SECONDS   graceful-stop timeout (default WDA_STOP_TIMEOUT or 10)
#   -h, --help          show this help
#
# Environment: PYMOBILEDEVICE3 is not needed to stop a runner (only the pid file
# and process table are used); WDA_RUNNER and WDA_LOG_DIR are honoured.
#
# Exit codes: 0 = runner stopped or was not running, 1 = stop failure,
#             2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Stop the WebDriverAgent XCTest runner started by start-wda.sh.

Usage:
  scripts/device/stop-wda.sh [options]

Options:
  --runner BUNDLE_ID  installed WDA XCTest runner (default WDA_RUNNER or
                      com.kratos.wda.xctrunner)
  --timeout SECONDS   graceful-stop timeout (default WDA_STOP_TIMEOUT or 10)
  -h, --help          show this help
EOF
}

runner="${WDA_RUNNER:-$WDA_DEFAULT_RUNNER}"
stop_timeout="${WDA_STOP_TIMEOUT:-$WDA_DEFAULT_STOP_TIMEOUT}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runner)
      [ "$#" -ge 2 ] || wda_die "--runner requires a value"
      runner="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || wda_die "--timeout requires a value"
      stop_timeout="$2"
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
stop_timeout="$(wda_validate_seconds "$stop_timeout" "--timeout")"
wda_prepare_log_dir

pid_file="$WDA_LOG_DIR/runner.pid"
stopped=0

stop_pid() {
  local pid="$1" iteration
  wda_info "stopping WDA runner pid $pid"
  kill -TERM "$pid" 2>/dev/null || true
  for ((iteration = 0; iteration < stop_timeout; iteration++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wda_info "WDA runner pid $pid stopped"
      return 0
    fi
    sleep 1
  done
  wda_warn "pid $pid did not exit after ${stop_timeout}s; sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    wda_warn "pid $pid is still alive and was not started by these scripts; leaving it alone"
    return 1
  fi
  wda_info "WDA runner pid $pid stopped"
  return 0
}

if [ -f "$pid_file" ]; then
  recorded_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if wda_pid_is_runner "$recorded_pid" "$runner"; then
    stop_pid "$recorded_pid" || wda_fail "could not stop the WDA runner pid $recorded_pid"
    stopped=1
  else
    wda_warn "ignoring stale runner pid file (pid '${recorded_pid}' is not a $runner runner): $pid_file"
  fi
  rm -f "$pid_file"
fi

for orphan_pid in $(wda_runner_pids "$runner"); do
  if wda_pid_is_runner "$orphan_pid" "$runner"; then
    stop_pid "$orphan_pid" || wda_fail "could not stop the WDA runner pid $orphan_pid"
    stopped=1
  fi
done

if [ "$stopped" -eq 0 ]; then
  wda_info "no WDA runner for $runner is running"
fi
