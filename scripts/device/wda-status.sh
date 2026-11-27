#!/usr/bin/env bash
# wda-status.sh - print the WebDriverAgent server status JSON.
#
# Thin wrapper around: pymobiledevice3 developer wda status --port PORT
# The WDA runner must already be running (scripts/device/start-wda.sh).
#
# Usage:
#   scripts/device/wda-status.sh [--port PORT] [--timeout SECONDS]
#
# Exit codes: 0 = WDA answered, 1 = device/WDA failure, 2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Print the WebDriverAgent server status JSON.

Usage:
  scripts/device/wda-status.sh [--port PORT] [--timeout SECONDS]

Options:
  --port PORT        WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS  HTTP timeout (default WDA_HTTP_TIMEOUT or 10)
  -h, --help         show this help

Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_HTTP_TIMEOUT.
EOF
}

port="${WDA_PORT:-$WDA_DEFAULT_PORT}"
timeout="${WDA_HTTP_TIMEOUT:-$WDA_DEFAULT_HTTP_TIMEOUT}"
while [ "$#" -gt 0 ]; do
  case "$1" in
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
    -*)
      wda_die "unknown option: $1 (try --help)"
      ;;
    *)
      wda_die "unexpected argument: $1 (try --help)"
      ;;
  esac
done

port="$(wda_validate_port "$port")"
timeout="$(wda_validate_timeout "$timeout")"
wda_require_pmd3

if ! output="$(wda_pmd3 developer wda status --port "$port" --timeout "$timeout" 2>&1)"; then
  if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
  fi
  wda_device_hint "$port"
  wda_fail "WDA status failed on device port $port"
fi
printf '%s\n' "$output"
