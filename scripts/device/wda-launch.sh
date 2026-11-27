#!/usr/bin/env bash
# wda-launch.sh - launch an app on the phone through WebDriverAgent.
#
# Thin wrapper around:
#   pymobiledevice3 developer wda launch BUNDLE_ID --port PORT
# It starts a WDA session, launches the app and prints the session id.
# The WDA runner must already be running (scripts/device/start-wda.sh).
#
# Usage:
#   scripts/device/wda-launch.sh BUNDLE_ID [--port PORT] [--timeout SECONDS]
#
# Exit codes: 0 = app launched, 1 = device/WDA failure, 2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Launch an app on the phone through WebDriverAgent.

Usage:
  scripts/device/wda-launch.sh BUNDLE_ID [options]

Arguments:
  BUNDLE_ID          app bundle id to launch (e.g. com.kratos.3ds2apple)

Options:
  --port PORT        WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS  HTTP timeout (default WDA_HTTP_TIMEOUT or 10)
  -h, --help         show this help

Options may appear before or after BUNDLE_ID.
Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_HTTP_TIMEOUT.
EOF
}

port="${WDA_PORT:-$WDA_DEFAULT_PORT}"
timeout="${WDA_HTTP_TIMEOUT:-$WDA_DEFAULT_HTTP_TIMEOUT}"
positionals=()
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
[ "${#positionals[@]}" -ge 1 ] || wda_die "the app bundle id is required (try --help)"
[ "${#positionals[@]}" -eq 1 ] || wda_die "unexpected extra arguments: ${positionals[*]:1} (try --help)"
bundle_id="${positionals[0]}"
wda_validate_bundle_id "$bundle_id"
port="$(wda_validate_port "$port")"
timeout="$(wda_validate_timeout "$timeout")"
wda_require_pmd3

if ! output="$(wda_pmd3 developer wda launch "$bundle_id" --port "$port" --timeout "$timeout" 2>&1)"; then
  [ -n "$output" ] && printf '%s\n' "$output" >&2
  wda_device_hint "$port"
  wda_fail "WDA launch of '$bundle_id' failed on device port $port"
fi
wda_info "launched: $bundle_id"
[ -n "$output" ] && printf '%s\n' "$output"
