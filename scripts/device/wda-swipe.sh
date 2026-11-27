#!/usr/bin/env bash
# wda-swipe.sh - swipe (or, for a same-point short swipe, tap by coordinate)
# through WebDriverAgent.
#
# Thin wrapper around:
#   pymobiledevice3 developer wda swipe X1 Y1 X2 Y2 --duration SECONDS --port PORT
# The WDA runner must already be running (scripts/device/start-wda.sh).
# A short swipe that starts and ends on the same point is a coordinate tap
# (WDA has no separate coordinate-tap endpoint):
#   scripts/device/wda-swipe.sh 190 400 190 400 --duration 0.1
#
# Usage:
#   scripts/device/wda-swipe.sh X1 Y1 X2 Y2 [--duration SECONDS] [--port PORT] [--timeout SECONDS]
#
# Exit codes: 0 = swipe accepted, 1 = device/WDA failure, 2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Swipe through WebDriverAgent (same-point short swipe = coordinate tap).

Usage:
  scripts/device/wda-swipe.sh X1 Y1 X2 Y2 [options]

Arguments:
  X1 Y1 X2 Y2        start and end screen coordinates in points

Options:
  --duration SECONDS, -d SECONDS
                     swipe duration (default 0.2; use ~0.1 for a coordinate tap)
  --port PORT        WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS  HTTP timeout (default WDA_HTTP_TIMEOUT or 10)
  -h, --help         show this help

Options may appear before or after the four coordinates.
Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_HTTP_TIMEOUT.
EOF
}

duration="0.2"
port="${WDA_PORT:-$WDA_DEFAULT_PORT}"
timeout="${WDA_HTTP_TIMEOUT:-$WDA_DEFAULT_HTTP_TIMEOUT}"
positionals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --duration|-d)
      [ "$#" -ge 2 ] || wda_die "$1 requires a value"
      duration="$2"
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || wda_die "--port requires a value"
      port="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || wda_die "--timeout requires a value"
      timeout="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do positionals+=("$1"); shift; done
      ;;
    -*)
      wda_die "unknown option: $1 (try --help)"
      ;;
    *)
      positionals+=("$1")
      shift
      ;;
  esac
done
[ "${#positionals[@]}" -eq 4 ] \
  || wda_die "expected exactly 4 coordinates: X1 Y1 X2 Y2 (got ${#positionals[@]}: ${positionals[*]:-})"
start_x="$(wda_validate_coordinate "${positionals[0]}" "X1")"
start_y="$(wda_validate_coordinate "${positionals[1]}" "Y1")"
end_x="$(wda_validate_coordinate "${positionals[2]}" "X2")"
end_y="$(wda_validate_coordinate "${positionals[3]}" "Y2")"
duration="$(wda_validate_duration "$duration")"
port="$(wda_validate_port "$port")"
timeout="$(wda_validate_timeout "$timeout")"
wda_require_pmd3

if [ "$start_x" = "$end_x" ] && [ "$start_y" = "$end_y" ]; then
  wda_info "same-point swipe treated as a coordinate tap at ($start_x,$start_y)"
fi

if ! output="$(wda_pmd3 developer wda swipe "$start_x" "$start_y" "$end_x" "$end_y" \
  --duration "$duration" --port "$port" --timeout "$timeout" 2>&1)"; then
  if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
  fi
  wda_device_hint "$port"
  wda_fail "WDA swipe ($start_x,$start_y) -> ($end_x,$end_y) failed on device port $port"
fi
wda_info "swipe: ($start_x,$start_y) -> ($end_x,$end_y) duration ${duration}s"
if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi
