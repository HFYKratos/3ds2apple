#!/usr/bin/env bash
# wda-tap.sh - tap an element through WebDriverAgent, by accessibility id/label/xpath.
#
# Thin wrapper around:
#   pymobiledevice3 developer wda tap SELECTOR --using STRATEGY --port PORT
# The WDA runner must already be running (scripts/device/start-wda.sh).
# Use scripts/device/wda-list.sh to discover selectors first (accessibility ids
# used by the 3ds2apple shell include 'game-card' and 'settings-link').
# For a raw coordinate tap, use a same-point short swipe:
#   scripts/device/wda-swipe.sh 190 400 190 400 --duration 0.1
#
# Usage:
#   scripts/device/wda-tap.sh SELECTOR [--using STRATEGY] [--port PORT] [--timeout SECONDS]
#
# Exit codes: 0 = tap accepted, 1 = device/WDA failure, 2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Tap an element through WebDriverAgent.

Usage:
  scripts/device/wda-tap.sh SELECTOR [options]

Arguments:
  SELECTOR           element selector matched with --using (e.g. 'game-card')

Options:
  --using STRATEGY, -u STRATEGY
                     element lookup strategy (default 'accessibility id';
                     WDA also accepts 'name', 'label', 'xpath')
  --port PORT        WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS  HTTP timeout (default WDA_HTTP_TIMEOUT or 10)
  -h, --help         show this help

Options may appear before or after SELECTOR; quote a selector that contains
spaces. Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_HTTP_TIMEOUT.
EOF
}

using="accessibility id"
port="${WDA_PORT:-$WDA_DEFAULT_PORT}"
timeout="${WDA_HTTP_TIMEOUT:-$WDA_DEFAULT_HTTP_TIMEOUT}"
positionals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --using|-u)
      [ "$#" -ge 2 ] || wda_die "$1 requires a value"
      using="$2"
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
[ "${#positionals[@]}" -ge 1 ] || wda_die "the element selector is required (try --help)"
[ "${#positionals[@]}" -eq 1 ] \
  || wda_die "unexpected extra arguments: ${positionals[*]:1} (quote a selector that contains spaces)"
selector="${positionals[0]}"
[ -n "$selector" ] || wda_die "the element selector is empty"
[ -n "$using" ] || wda_die "the --using strategy is empty"

port="$(wda_validate_port "$port")"
timeout="$(wda_validate_timeout "$timeout")"
wda_require_pmd3

if ! output="$(wda_pmd3 developer wda tap "$selector" --using "$using" --port "$port" --timeout "$timeout" 2>&1)"; then
  [ -n "$output" ] && printf '%s\n' "$output" >&2
  wda_device_hint "$port"
  wda_fail "WDA tap '$selector' (using: $using) failed on device port $port"
fi
wda_info "tapped: $selector (using: $using)"
[ -n "$output" ] && printf '%s\n' "$output"
