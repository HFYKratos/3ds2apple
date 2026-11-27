#!/usr/bin/env bash
# wda-shot.sh - take a screenshot of the phone through WebDriverAgent.
#
# Thin wrapper around: pymobiledevice3 developer wda screenshot OUT --port PORT
# The WDA runner must already be running (scripts/device/start-wda.sh).
# Screenshots default to /tmp/3ds2apple-wda (never into this repository).
#
# Usage:
#   scripts/device/wda-shot.sh [OUT.png] [--port PORT] [--timeout SECONDS]
#
# Exit codes: 0 = screenshot written, 1 = device/WDA failure, 2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
Take a screenshot of the phone through WebDriverAgent.

Usage:
  scripts/device/wda-shot.sh [OUT.png] [options]

Arguments:
  OUT.png            output file (default <WDA_LOG_DIR>/shot-<timestamp>.png)

Options:
  --port PORT        WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS  HTTP timeout (default WDA_HTTP_TIMEOUT or 10)
  -h, --help         show this help

Options may appear before or after OUT.png.
Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_LOG_DIR, WDA_HTTP_TIMEOUT.
A screenshot path inside this repository is refused; use /tmp.
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
[ "${#positionals[@]}" -le 1 ] || wda_die "unexpected extra arguments: ${positionals[*]:1} (try --help)"
out="${positionals[0]:-}"

port="$(wda_validate_port "$port")"
timeout="$(wda_validate_timeout "$timeout")"
wda_prepare_log_dir
if [ -z "$out" ]; then
  out="$WDA_LOG_DIR/shot-$(date +%Y%m%d-%H%M%S).png"
fi
wda_require_outside_repo "$out" "screenshot"
mkdir -p "$(dirname "$out")" || wda_die "cannot create the screenshot directory: $(dirname "$out")"
wda_require_pmd3

if ! output="$(wda_pmd3 developer wda screenshot "$out" --port "$port" --timeout "$timeout" 2>&1)"; then
  [ -n "$output" ] && printf '%s\n' "$output" >&2
  wda_device_hint "$port"
  wda_fail "WDA screenshot failed on device port $port"
fi
[ -s "$out" ] || wda_fail "WDA reported success but no screenshot file was written: $out"
bytes="$(wc -c <"$out" | tr -d ' ')"
wda_info "screenshot: $out ($bytes bytes)"
[ -n "$output" ] && printf '%s\n' "$output"
