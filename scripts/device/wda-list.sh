#!/usr/bin/env bash
# wda-list.sh - list tappable WebDriverAgent elements (accessibility ids/labels).
#
# Thin wrapper around: pymobiledevice3 developer wda list-items --port PORT
# The WDA runner must already be running (scripts/device/start-wda.sh).
# Use the listed accessibility ids with scripts/device/wda-tap.sh.
#
# Usage:
#   scripts/device/wda-list.sh [--hittable-only] [--with-rect] [--types LIST]
#                              [--port PORT] [--timeout SECONDS]
#
# Exit codes: 0 = list printed, 1 = device/WDA failure, 2 = usage/tooling error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wda-common.sh
. "$SCRIPT_DIR/lib/wda-common.sh"

usage() {
  cat <<'EOF'
List tappable WebDriverAgent elements.

Usage:
  scripts/device/wda-list.sh [options]

Options:
  --hittable-only    only elements WDA marks hittable
  --with-rect        include element bounds (x,y,width,height)
  --types LIST       comma-separated element types (e.g. Icon,Button,Cell)
  --port PORT        WDA device port (default WDA_PORT or 8100)
  --timeout SECONDS  HTTP timeout (default WDA_HTTP_TIMEOUT or 10)
  -h, --help         show this help

Environment: PYMOBILEDEVICE3, WDA_PORT, WDA_HTTP_TIMEOUT.
EOF
}

hittable_only=0
with_rect=0
types=""
port="${WDA_PORT:-$WDA_DEFAULT_PORT}"
timeout="${WDA_HTTP_TIMEOUT:-$WDA_DEFAULT_HTTP_TIMEOUT}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hittable-only)
      hittable_only=1
      shift
      ;;
    --with-rect)
      with_rect=1
      shift
      ;;
    --types)
      [ "$#" -ge 2 ] || wda_die "--types requires a value"
      types="$2"
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

arguments=(developer wda list-items --port "$port" --timeout "$timeout")
if [ "$hittable_only" -eq 1 ]; then arguments+=(--hittable-only); fi
if [ "$with_rect" -eq 1 ]; then arguments+=(--with-rect); fi
if [ -n "$types" ]; then arguments+=(--types "$types"); fi

if ! output="$(wda_pmd3 "${arguments[@]}" 2>&1)"; then
  if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
  fi
  wda_device_hint "$port"
  wda_fail "WDA element list failed on device port $port"
fi
printf '%s\n' "$output"
