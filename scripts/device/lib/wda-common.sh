#!/usr/bin/env bash
# wda-common.sh - shared helpers for the scripts/device WDA wrappers.
#
# Sourced by every scripts/device/*.sh entry point. It centralises the
# pymobiledevice3 configuration (PYMOBILEDEVICE3), the WDA device port, the
# installed runner bundle id, output-path safety and small argument validators.
# There are no secrets and no UDID here: pymobiledevice3 selects the single
# connected device itself, so nothing device-specific is hard-coded or printed.
#
# Environment (all optional):
#   PYMOBILEDEVICE3   pymobiledevice3 command. Default: pymobiledevice3.
#                     May include arguments, e.g.
#                     PYMOBILEDEVICE3="/path/to/venv/bin/python -m pymobiledevice3"
#   WDA_PORT          WDA device port (default 8100)
#   WDA_RUNNER        installed WDA XCTest runner bundle id
#                     (default com.kratos.wda.xctrunner, from the task-6 setup)
#   WDA_LOG_DIR       default log/screenshot directory (default /tmp/3ds2apple-wda)
#   WDA_HTTP_TIMEOUT  default pymobiledevice3 --timeout seconds (default 10)
#   WDA_START_TIMEOUT default start-wda.sh readiness timeout seconds (default 90)
#   WDA_STOP_TIMEOUT  default stop-wda.sh graceful-stop seconds (default 10)
#
# Output policy: logs and screenshots default to /tmp/3ds2apple-wda and the
# helpers refuse to write inside this repository; WDA output is never committed.

WDA_DEFAULT_PORT=8100
WDA_DEFAULT_RUNNER="com.kratos.wda.xctrunner"
WDA_DEFAULT_LOG_DIR="/tmp/3ds2apple-wda"
WDA_DEFAULT_HTTP_TIMEOUT=10
WDA_DEFAULT_START_TIMEOUT=90
WDA_DEFAULT_STOP_TIMEOUT=10

WDA_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WDA_PMD3=()

wda_info() { printf '[wda] %s\n' "$*"; }
wda_warn() { printf '[wda][warn] %s\n' "$*" >&2; }
wda_die() { printf 'error: %s\n' "$*" >&2; exit 2; }
wda_fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# wda_require_pmd3 - resolve PYMOBILEDEVICE3 and fail with an actionable message.
wda_require_pmd3() {
  local command_value="${PYMOBILEDEVICE3:-pymobiledevice3}" executable
  read -r -a WDA_PMD3 <<< "$command_value"
  [ "${#WDA_PMD3[@]}" -gt 0 ] || wda_die "PYMOBILEDEVICE3 is empty; set it to the pymobiledevice3 command"
  executable="${WDA_PMD3[0]}"
  if [[ "$executable" == */* ]]; then
    [ -x "$executable" ] || wda_die "pymobiledevice3 executable not found: $executable (check PYMOBILEDEVICE3)"
  else
    command -v "$executable" >/dev/null 2>&1 \
      || wda_die "pymobiledevice3 command not found: $executable. Install it or set PYMOBILEDEVICE3, e.g. PYMOBILEDEVICE3='/path/to/venv/bin/python -m pymobiledevice3' (see scripts/README.md, device automation)."
  fi
}

# wda_pmd3 ARGS... - run pymobiledevice3 with the configured command.
wda_pmd3() { "${WDA_PMD3[@]}" "$@"; }

wda_validate_port() { # VALUE -> echoes the validated port
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || wda_die "device port must be an integer (got '$value')"
  (( value >= 1 && value <= 65535 )) || wda_die "device port must be 1-65535 (got $value)"
  printf '%s\n' "$value"
}

wda_validate_seconds() { # VALUE LABEL -> echoes a whole positive number of seconds
  local value="$1" label="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || wda_die "$label must be a whole number of seconds (got '$value')"
  (( value >= 1 )) || wda_die "$label must be >= 1 second (got $value)"
  printf '%s\n' "$value"
}

wda_validate_timeout() { # VALUE -> echoes a positive number (fractions allowed)
  local value="$1"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || wda_die "timeout must be a positive number of seconds (got '$value')"
  if [[ "$value" =~ ^0+([.]0+)?$ ]]; then wda_die "timeout must be > 0 (got '$value')"; fi
  printf '%s\n' "$value"
}

wda_validate_duration() { # VALUE -> echoes a positive swipe duration
  local value="$1" whole fraction
  [[ "$value" =~ ^([0-9]+)([.]([0-9]+))?$ ]] || wda_die "duration must be a positive number of seconds (got '$value')"
  whole="${BASH_REMATCH[1]}"
  fraction="${BASH_REMATCH[3]:-}"
  if [[ "$whole" =~ ^0+$ && ( -z "$fraction" || "$fraction" =~ ^0+$ ) ]]; then
    wda_die "duration must be > 0 (got '$value')"
  fi
  printf '%s\n' "$value"
}

wda_validate_coordinate() { # VALUE NAME -> echoes
  local value="$1" name="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || wda_die "$name must be a non-negative integer screen coordinate (got '$value')"
  printf '%s\n' "$value"
}

wda_validate_runner() { # VALUE
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || wda_die "invalid WDA runner bundle id: '$1' (expected e.g. com.kratos.wda.xctrunner)"
}

wda_validate_bundle_id() { # VALUE
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || wda_die "invalid app bundle id: '$1'"
}

# wda_require_outside_repo PATH LABEL - refuse to write logs/screenshots into git.
wda_require_outside_repo() {
  local path="$1" label="$2" absolute resolved
  [ -n "$path" ] || wda_die "$label path is empty"
  if [[ "$path" == /* ]]; then absolute="$path"; else absolute="$PWD/$path"; fi
  if command -v realpath >/dev/null 2>&1; then
    if resolved="$(realpath -m -- "$absolute" 2>/dev/null)"; then absolute="$resolved"; fi
  fi
  case "$absolute" in
    "$WDA_REPO_ROOT"|"$WDA_REPO_ROOT"/*)
      wda_die "refusing to write the $label inside the repository: $absolute (use /tmp or another local path; screenshots/logs are never committed)"
      ;;
  esac
}

# wda_prepare_log_dir - create/validate the default log directory.
wda_prepare_log_dir() {
  WDA_LOG_DIR="${WDA_LOG_DIR:-$WDA_DEFAULT_LOG_DIR}"
  wda_require_outside_repo "$WDA_LOG_DIR" "log directory"
  mkdir -p "$WDA_LOG_DIR" || wda_die "cannot create the log directory: $WDA_LOG_DIR"
  [ -w "$WDA_LOG_DIR" ] || wda_die "log directory is not writable: $WDA_LOG_DIR"
}

# wda_device_hint [PORT] - the two things to check when a WDA command fails.
wda_device_hint() {
  local port="${1:-$WDA_DEFAULT_PORT}"
  wda_warn "is the iPhone connected, unlocked and trusted over USB (usbmuxd), and the WDA runner started with scripts/device/start-wda.sh?"
  wda_warn "device port: $port; see scripts/README.md (device automation) for the setup."
}

# wda_pid_is_runner PID RUNNER - true when PID is a live 'developer dvt xcuitest' for RUNNER.
wda_pid_is_runner() {
  local pid="$1" runner="$2" command_line=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  elif command -v ps >/dev/null 2>&1; then
    command_line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  fi
  [[ "$command_line" == *"developer dvt xcuitest"* && "$command_line" == *"$runner"* ]]
}

# wda_runner_pids RUNNER - any live pymobiledevice3 xcuitest processes for RUNNER.
wda_runner_pids() {
  local runner="$1"
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -f -- "developer dvt xcuitest $runner" 2>/dev/null || true
}

# wda_status_reachable PORT TIMEOUT - true when the WDA server answers 'status'.
wda_status_reachable() {
  wda_pmd3 developer wda status --port "$1" --timeout "$2" >/dev/null 2>&1
}
