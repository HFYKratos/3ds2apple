#!/usr/bin/env bash
# dev-transfer.sh - one-command, hash-verified dev file transfer for 3ds2apple.
#
# The macOS build VM and the Windows/WSL workstation are on different networks, so
# large dev artifacts (for example the bundled-ROM IPA) have to travel over the
# internet. This helper relays a file through the VPS:
#
#   build VM -> CachyOS host -> VPS /var/www/ios/tmp/<random-token>/<name>
#                               -> HTTPS download on Windows/WSL (resumable)
#
# It is also the documented home of the direct-LAN path (lan push / lan fetch) that
# becomes available once both machines share a network.
#
# Security rules (see docs/dev-transfer.md):
#   * tokens are random 96-bit hex path segments; every artifact carries a sha256
#     sidecar; tokens expire after --ttl minutes (default 180) and must be removed
#     with "clean <token>" after use.
#   * never paste an artifact URL anywhere; never move ROM/IPA files into git.
#   * this script never prints key material, passwords or Apple credentials.
#
# Hosts:
#   push/list/clean/side-load/doctor/speedtest/lan run wherever the file and the
#   target host are reachable. In this project: run push on the CachyOS host
#   (it has the VPS root key), run fetch on Windows/WSL (plain HTTPS, no key).
#
# Requirements: bash, ssh, scp, rsync (push, optional), curl (fetch), python3,
# openssl, sha256sum/shasum, unzip (only for --ipa).

set -o pipefail

SCRIPT_NAME="dev-transfer.sh"
SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# configuration (override with DT_* environment variables)
# ---------------------------------------------------------------------------
VPS_TARGET="root@47.115.170.160"
VPS_KEY="$HOME/.ssh/id_ed25519"
VPS_PORT="22"
VM_TARGET="kratoshuang@127.0.0.1"
VM_PORT="2222"
VM_KEY="$HOME/.ssh/3ds2apple_macos"
WEB_ROOT="/var/www/ios"
TMP_ROOT="/var/www/ios/tmp"
INDEX_DIR="/var/lib/dev-transfer"
BASE_URL="https://47.115.170.160/ios"
DEFAULT_TTL="180"
DEFAULT_MAX_BYTES="2147483648"

load_env() {
  if [ -n "$DT_VPS_TARGET" ]; then VPS_TARGET="$DT_VPS_TARGET"; fi
  if [ -n "$DT_VPS_KEY" ]; then VPS_KEY="$DT_VPS_KEY"; fi
  if [ -n "$DT_VPS_PORT" ]; then VPS_PORT="$DT_VPS_PORT"; fi
  if [ -n "$DT_VM_TARGET" ]; then VM_TARGET="$DT_VM_TARGET"; fi
  if [ -n "$DT_VM_PORT" ]; then VM_PORT="$DT_VM_PORT"; fi
  if [ -n "$DT_VM_KEY" ]; then VM_KEY="$DT_VM_KEY"; fi
  if [ -n "$DT_WEB_ROOT" ]; then WEB_ROOT="$DT_WEB_ROOT"; fi
  if [ -n "$DT_TMP_ROOT" ]; then TMP_ROOT="$DT_TMP_ROOT"; fi
  if [ -n "$DT_INDEX_DIR" ]; then INDEX_DIR="$DT_INDEX_DIR"; fi
  if [ -n "$DT_BASE_URL" ]; then BASE_URL="$DT_BASE_URL"; fi
  if [ -n "$DT_TTL_MINUTES" ]; then DEFAULT_TTL="$DT_TTL_MINUTES"; fi
  if [ -n "$DT_MAX_BYTES" ]; then DEFAULT_MAX_BYTES="$DT_MAX_BYTES"; fi
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
log()  { echo "[dev-transfer] $*" >&2; }
warn() { echo "[dev-transfer] WARNING: $*" >&2; }
die()  { echo "[dev-transfer] ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_now() { date -u +%s; }
epoch_to_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ms_now() { date +%s%N; }

human_bytes() {
  python3 -c 'import sys
n=int(sys.argv[1])
units=["B","KiB","MiB","GiB","TiB"]
i=0
f=float(n)
while f>=1024.0 and i<len(units)-1:
    f=f/1024.0
    i+=1
print("%.0f %s" % (f,units[i]) if i==0 else "%.2f %s" % (f,units[i]))' "$1"
}

rate_mb_s() {
  python3 -c 'import sys
b=float(sys.argv[1]); ms=float(sys.argv[2])
print("%.2f" % (b/ms/1000.0) if ms>0 else "0.00")' "$1" "$2"
}

project_min() {
  python3 -c 'import sys
b=float(sys.argv[1]); rate=float(sys.argv[2])
print("%.1f" % (b/rate/1000000.0/60.0) if rate>0 else "inf")' "$1" "$2"
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "need sha256sum or shasum"
  fi
}

rand_token() {
  need_cmd openssl
  openssl rand -hex 12
}

validate_token() {
  local tok="$1" n
  [ -n "$tok" ] || return 1
  n=$(printf '%s' "$tok" | wc -c)
  [ "$n" -eq 24 ] || return 1
  case "$tok" in
    *[!0-9a-f]*) return 1 ;;
  esac
  return 0
}

sanitize_name() {
  local raw="$1" name
  name=$(basename "$raw" | tr -cd 'A-Za-z0-9._-')
  case "$name" in
    -*) name="_$name" ;;
  esac
  [ -n "$name" ] || name="artifact.bin"
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# remote command helpers
# ---------------------------------------------------------------------------
vps() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
      -p "$VPS_PORT" -i "$VPS_KEY" "$VPS_TARGET" "$@"
}
vps_ok() { vps true >/dev/null 2>&1; }

require_vps() {
  [ -f "$VPS_KEY" ] || die "VPS key not found at $VPS_KEY (set DT_VPS_KEY; run push on the CachyOS build host)"
  if ! vps_ok; then
    die "cannot SSH to $VPS_TARGET as root (BatchMode). Run push/list/clean on the CachyOS host, or set DT_VPS_TARGET/DT_VPS_KEY."
  fi
}

vm() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
      -p "$VM_PORT" -i "$VM_KEY" "$VM_TARGET" "$@"
}
vm_ok() { vm true >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# index / source.json generation
# ---------------------------------------------------------------------------
build_index_json() {
  # args: token name bytes sha created expires ttl url kind bundle version appname pushhost
  local token="$1" name="$2" size="$3" sha="$4" created="$5" expires="$6" ttl="$7" url="$8" kind="$9"
  shift 9
  local bundle="$1" version="$2" app_name="$3" host="$4"
  python3 - "$token" "$name" "$size" "$sha" "$created" "$expires" "$ttl" "$url" "$kind" "$bundle" "$version" "$app_name" "$host" <<'PY'
import json, sys
(token, name, size, sha, created, expires, ttl, url, kind, bundle, version, app_name, host) = sys.argv[1:14]
d = {
    "schema": 1,
    "token": token,
    "name": name,
    "bytes": int(size),
    "sha256": sha,
    "created_utc": created,
    "expires_utc": expires,
    "ttl_minutes": int(ttl),
    "url": url,
    "kind": kind,
    "pushed_from": host,
    "note": "one-time dev transfer; delete after use (scripts/dev-transfer.sh clean TOKEN)",
}
if bundle or version or app_name:
    d["ipa"] = {"bundle_id": bundle, "version": version, "app_name": app_name}
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
}

emit_source_json() {
  # args: identifier app_name bundle_id version url size
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys, datetime
ident, app_name, bundle, version, url, size = sys.argv[1:7]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
source = {
    "name": "3ds2apple dev transfer",
    "identifier": ident,
    "subtitle": "Temporary build relay (delete after use)",
    "description": "One-time SideStore source generated by scripts/dev-transfer.sh. Remove it with: scripts/dev-transfer.sh clean TOKEN",
    "apps": [
        {
            "name": app_name or "dev build",
            "bundleIdentifier": bundle,
            "developerName": "Local unsigned build",
            "subtitle": "dev transfer " + version,
            "localizedDescription": (app_name or "dev build") + " temporary relay build",
            "tintColor": "5B9BD5",
            "versions": [
                {
                    "version": version,
                    "date": now,
                    "localizedDescription": "Dev transfer via scripts/dev-transfer.sh",
                    "downloadURL": url,
                    "size": int(size),
                }
            ],
        }
    ],
}
print(json.dumps(source, indent=2, ensure_ascii=False))
PY
}

ipa_metadata() {
  # $1 = local .ipa path; prints bundle_id|version|app_name
  local f="$1" tmpd plist
  need_cmd unzip
  tmpd=$(mktemp -d)
  plist="$tmpd/Info.plist"
  if ! unzip -p "$f" 'Payload/*.app/Info.plist' > "$plist" 2>/dev/null || [ ! -s "$plist" ]; then
    rm -rf "$tmpd"
    die "cannot read Payload/*.app/Info.plist from $f (is it a valid IPA?)"
  fi
  python3 - "$plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
name = d.get("CFBundleDisplayName") or d.get("CFBundleName") or "dev build"
print("%s|%s|%s" % (d.get("CFBundleIdentifier", ""), d.get("CFBundleShortVersionString", ""), name))
PY
  rm -rf "$tmpd"
}

load_index_json() {
  local token="$1"
  vps "cat '$INDEX_DIR/$token.json'"
}

# ---------------------------------------------------------------------------
# index listing (push host only)
# ---------------------------------------------------------------------------
list_index_tsv() {
  # prints: token|expires_epoch|bytes|kind|name|url
  local tmpf
  tmpf=$(mktemp)
  vps "cat '$INDEX_DIR'/*.json 2>/dev/null" > "$tmpf" 2>/dev/null || true
  python3 - "$tmpf" <<'PY'
import json, sys, datetime
try:
    data = open(sys.argv[1], "r", encoding="utf-8").read()
except OSError:
    data = ""
dec = json.JSONDecoder()
idx = 0
rows = []
while True:
    while idx < len(data) and data[idx] in " \t\r\n":
        idx += 1
    if idx >= len(data):
        break
    try:
        obj, idx = dec.raw_decode(data, idx)
    except ValueError:
        break
    exp = obj.get("expires_utc", "")
    try:
        e = int(datetime.datetime.strptime(exp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        e = 0
    rows.append((obj.get("token", ""), e, int(obj.get("bytes", 0)), obj.get("kind", "file"),
                 obj.get("name", ""), obj.get("url", "")))
for r in rows:
    print("%s|%d|%d|%s|%s|%s" % r)
PY
  rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------
cmd_push() {
  local file="" name="" ttl="$DEFAULT_TTL" max_bytes="$DEFAULT_MAX_BYTES" ipa=0 vm_path="" dry=0 json=0
  local local_file="" tmpd="" token="" url="" size="" sha="" t0="" t1="" vm_ms="" push_ms=""
  local kind="file" bundle="" version="" app_name="" source_url="" rhash="" exp_epoch="" created="" expires="" index_json=""
  local web_dir="" remote_file="" host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) shift; name="$1" ;;
      --ttl) shift; ttl="$1" ;;
      --max-bytes) shift; max_bytes="$1" ;;
      --ipa) ipa=1 ;;
      --vm) shift; vm_path="$1" ;;
      --dry-run|-n) dry=1 ;;
      --json) json=1 ;;
      -*) die "push: unknown option $1" ;;
      *) if [ -z "$file" ]; then file="$1"; else die "push: unexpected argument $1"; fi ;;
    esac
    shift || true
  done

  if [ -n "$vm_path" ]; then
    [ -z "$file" ] || die "push: use either <file> or --vm <vm-path>, not both"
    need_cmd ssh
    vm_ok || die "cannot SSH to the macOS VM ($VM_TARGET, port $VM_PORT): run --vm on the CachyOS build host"
  else
    [ -n "$file" ] || die "push: missing <file> (or --vm <path> for a macOS VM file)"
    [ -f "$file" ] || die "push: no such file: $file"
  fi
  case "$ttl" in
    ''|*[!0-9]*) die "push: --ttl must be an integer number of minutes" ;;
  esac
  case "$max_bytes" in
    ''|*[!0-9]*) die "push: --max-bytes must be an integer" ;;
  esac

  token=$(rand_token)
  validate_token "$token" || die "internal error: generated an invalid token"
  if [ -z "$name" ]; then
    if [ -n "$vm_path" ]; then name=$(sanitize_name "$vm_path"); else name=$(sanitize_name "$file"); fi
  else
    name=$(sanitize_name "$name")
  fi
  url="$BASE_URL/tmp/$token/$name"
  web_dir="$TMP_ROOT/$token"
  remote_file="$web_dir/$name"

  if [ "$dry" = 1 ]; then
    echo "dry-run: no remote changes, no token created"
    if [ -n "$vm_path" ]; then echo "file:        $vm_path (from the macOS VM)"; else echo "file:        $file"; fi
    echo "name:        $name"
    echo "max-bytes:   $max_bytes"
    echo "ttl-minutes: $ttl"
    echo "token:       (random 24-hex, generated on the real run)"
    echo "steps:"
    if [ -n "$vm_path" ]; then
      echo "  1. scp -P $VM_PORT -i $VM_KEY $VM_TARGET:$vm_path <tmp>/<name>"
    fi
    echo "  2. ssh -i $VPS_KEY $VPS_TARGET mkdir -p $web_dir"
    echo "  3. rsync --partial --inplace <file> $VPS_TARGET:$remote_file"
    echo "  4. ssh ... sha256sum $remote_file  (compare with the local sha256)"
    echo "  5. if --ipa: write $web_dir/source.json for SideStore"
    echo "  6. write $INDEX_DIR/<token>.json and print the https URL"
    echo "  7. cleanup: scripts/dev-transfer.sh clean <token>"
    return 0
  fi

  require_vps
  if [ -n "$vm_path" ]; then
    need_cmd scp
    tmpd=$(mktemp -d)
    local_file="$tmpd/$name"
    log "pulling from macOS VM: $vm_path"
    t0=$(ms_now)
    if ! scp -q -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new \
         -P "$VM_PORT" -i "$VM_KEY" "$VM_TARGET:$vm_path" "$local_file"; then
      rm -rf "$tmpd"
      die "scp from the macOS VM failed (check the path and that the VM is running)"
    fi
    t1=$(ms_now)
    vm_ms=$(( (t1 - t0) / 1000000 ))
    size=$(wc -c < "$local_file")
  else
    local_file="$file"
    size=$(wc -c < "$file")
  fi
  if [ "$size" -gt "$max_bytes" ]; then
    [ -n "$tmpd" ] && rm -rf "$tmpd"
    die "file is $size bytes, above --max-bytes $max_bytes (pass a larger --max-bytes only for an intended transfer)"
  fi

  host=$(hostname 2>/dev/null || echo unknown)
  sha=$(sha_of "$local_file")
  log "uploading $(human_bytes "$size") to $VPS_TARGET:$remote_file"
  t0=$(ms_now)
  if ! vps "mkdir -p '$web_dir' '$INDEX_DIR' && chmod 755 '$web_dir' && chmod 700 '$INDEX_DIR'"; then
    [ -n "$tmpd" ] && rm -rf "$tmpd"
    die "could not create remote directory $web_dir"
  fi
  if command -v rsync >/dev/null 2>&1; then
    if ! rsync -q --partial --inplace -e "ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -p $VPS_PORT -i $VPS_KEY" "$local_file" "$VPS_TARGET:$remote_file"; then
      [ -n "$tmpd" ] && rm -rf "$tmpd"
      die "rsync upload failed (partial data kept in $web_dir; run clean if you abandon it)"
    fi
  else
    if ! scp -q -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new \
         -P "$VPS_PORT" -i "$VPS_KEY" "$local_file" "$VPS_TARGET:$remote_file"; then
      [ -n "$tmpd" ] && rm -rf "$tmpd"
      die "scp upload failed"
    fi
  fi
  t1=$(ms_now)
  push_ms=$(( (t1 - t0) / 1000000 ))
  [ -n "$tmpd" ] && rm -rf "$tmpd"

  rhash=$(vps "sha256sum '$remote_file'" | cut -d' ' -f1)
  if [ "$rhash" != "$sha" ]; then
    die "sha256 mismatch after upload (local $sha, remote $rhash); artifact NOT published, run clean $token"
  fi
  vps "cd '$web_dir' && sha256sum '$name' > '$name.sha256' && chmod 644 '$name' '$name.sha256'" || die "could not write remote sha256 sidecar"

  kind="file"
  if [ "$ipa" = 1 ]; then
    kind="ipa"
    local meta
    meta=$(ipa_metadata "$local_file") || die "could not parse IPA metadata"
    bundle=$(printf '%s' "$meta" | cut -d'|' -f1)
    version=$(printf '%s' "$meta" | cut -d'|' -f2)
    app_name=$(printf '%s' "$meta" | cut -d'|' -f3)
    source_url="$BASE_URL/tmp/$token/source.json"
    emit_source_json "dev.3ds2apple.transfer.$token" "$app_name" "$bundle" "$version" "$url" "$size" |
      vps "cat > '$web_dir/source.json' && chmod 644 '$web_dir/source.json'" || die "could not write SideStore source.json"
  fi

  created=$(now_utc)
  exp_epoch=$(( $(epoch_now) + ttl * 60 ))
  expires=$(epoch_to_utc "$exp_epoch")
  index_json=$(build_index_json "$token" "$name" "$size" "$sha" "$created" "$expires" "$ttl" "$url" "$kind" "$bundle" "$version" "$app_name" "$host")
  echo "$index_json" | vps "cat > '$INDEX_DIR/$token.json' && chmod 600 '$INDEX_DIR/$token.json'" || die "could not write remote index entry"

  if [ "$json" = 1 ]; then
    python3 - "$token" "$name" "$size" "$sha" "$url" "$expires" "$source_url" <<'PY'
import json, sys
token, name, size, sha, url, expires, source = sys.argv[1:8]
print(json.dumps({"token": token, "name": name, "bytes": int(size), "sha256": sha,
                  "url": url, "expires_utc": expires, "source_json_url": source or ""}))
PY
    return 0
  fi

  echo ""
  echo "=== dev artifact published (temporary, one-time token) ==="
  echo "name:      $name"
  echo "bytes:     $size ($(human_bytes "$size"))"
  echo "sha256:    $sha"
  echo "url:       $url"
  if [ -n "$source_url" ]; then
    echo "source:    $source_url  (SideStore source, IPA only)"
  fi
  echo "expires:   $expires (ttl $ttl min)"
  if [ -n "$vm_ms" ]; then
    echo "leg VM->host:  $vm_ms ms, $(rate_mb_s "$size" "$vm_ms") MB/s"
  fi
  echo "leg host->VPS: $push_ms ms, $(rate_mb_s "$size" "$push_ms") MB/s"
  echo ""
  echo "next:"
  echo "  fetch on Windows/WSL:"
  echo "    scripts/dev-transfer.sh fetch $url <dest> --sha256 $sha"
  if [ -n "$source_url" ]; then
    echo "  SideStore (on the iPhone):"
    echo "    Sources -> + -> $source_url -> pull to refresh -> Install"
  fi
  echo "  cleanup after use:"
  echo "    scripts/dev-transfer.sh clean $token"
}

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------
cmd_fetch() {
  local src="" dest="" want_sha="" no_verify=0 max_bytes="$DEFAULT_MAX_BYTES" dry=0
  local t0="" t1="" dl_ms="" got_sha="" dest_bytes="" sidecar=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha256) shift; want_sha="$1" ;;
      --no-verify) no_verify=1 ;;
      --max-bytes) shift; max_bytes="$1" ;;
      --dry-run|-n) dry=1 ;;
      -*) die "fetch: unknown option $1" ;;
      *) if [ -z "$src" ]; then src="$1"; elif [ -z "$dest" ]; then dest="$1"; else die "fetch: unexpected argument $1"; fi ;;
    esac
    shift || true
  done
  [ -n "$src" ] || die "fetch: missing <url>"
  case "$src" in
    *://*) : ;;
    *) die "fetch: pass the full https URL printed by push (a token alone has no public index)" ;;
  esac
  if ! printf '%s' "$src" | grep -Eq '^[A-Za-z0-9:/._~%?=&+@-]+$'; then
    die "fetch: refusing URL with unusual characters"
  fi
  if [ -z "$dest" ]; then
    dest=$(sanitize_name "$src")
  fi

  need_cmd curl
  if [ -f "$dest" ] && [ -n "$want_sha" ]; then
    got_sha=$(sha_of "$dest")
    if [ "$got_sha" = "$want_sha" ]; then
      echo "already complete: $dest ($(human_bytes "$(wc -c < "$dest")"), sha256 ok)"
      return 0
    fi
    log "existing $dest does not match the expected sha256; resuming"
  fi

  if [ "$dry" = 1 ]; then
    echo "dry-run: would curl (resume) $src -> $dest"
    [ -n "$want_sha" ] && echo "expected sha256: $want_sha"
    return 0
  fi

  t0=$(ms_now)
  if [ -t 2 ]; then
    curl --fail --location --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20 \
         --continue-at - --output "$dest" --progress-bar "$src" || die "download failed; partial file kept, rerun the same command to resume"
  else
    curl --fail --location --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20 \
         --continue-at - --output "$dest" --silent --show-error "$src" || die "download failed; partial file kept, rerun the same command to resume"
  fi
  t1=$(ms_now)
  dl_ms=$(( (t1 - t0) / 1000000 ))
  dest_bytes=$(wc -c < "$dest")
  if [ "$dest_bytes" -gt "$max_bytes" ]; then
    die "downloaded $dest_bytes bytes, above --max-bytes $max_bytes; remove $dest before retrying"
  fi

  if [ -z "$want_sha" ] && [ "$no_verify" = 0 ]; then
    sidecar=$(mktemp)
    if curl --fail --location --max-time 30 --silent --output "$sidecar" "$src.sha256" 2>/dev/null; then
      want_sha=$(cut -d' ' -f1 < "$sidecar")
      log "using published sha256 sidecar"
    fi
    rm -f "$sidecar"
  fi

  if [ -n "$want_sha" ]; then
    got_sha=$(sha_of "$dest")
    if [ "$got_sha" != "$want_sha" ]; then
      die "sha256 mismatch: expected $want_sha, got $got_sha (file kept at $dest; remove it and retry if the server copy is wrong)"
    fi
    echo "verified: $dest"
  elif [ "$no_verify" = 0 ]; then
    die "no sha256 supplied and no .sha256 sidecar available; pass --sha256 <hash> or --no-verify"
  else
    warn "sha256 NOT verified (--no-verify)"
  fi
  echo "bytes:     $dest_bytes ($(human_bytes "$dest_bytes"))"
  echo "download:  $dl_ms ms, $(rate_mb_s "$dest_bytes" "$dl_ms") MB/s"
  echo "sha256:    $(sha_of "$dest")"
}

# ---------------------------------------------------------------------------
# SideStore source
# ---------------------------------------------------------------------------
cmd_side_load() {
  local token="" dry=0 index_json="" size="" url="" source_url="" ident=""
  local bundle="" version="" app_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) dry=1 ;;
      -*) die "side-load: unknown option $1" ;;
      *) if [ -z "$token" ]; then token="$1"; else die "side-load: unexpected argument $1"; fi ;;
    esac
    shift || true
  done
  [ -n "$token" ] || die "side-load: missing <token> (printed by push --ipa)"
  validate_token "$token" || die "side-load: invalid token format"

  require_vps
  if ! vps "test -f '$INDEX_DIR/$token.json'"; then
    die "side-load: no index entry for token $token (was it cleaned already?)"
  fi
  index_json=$(load_index_json "$token")
  url=$(printf '%s' "$index_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("url",""))')
  size=$(printf '%s' "$index_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("bytes","0"))')
  bundle=$(printf '%s' "$index_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("ipa") or {}).get("bundle_id",""))')
  version=$(printf '%s' "$index_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("ipa") or {}).get("version",""))')
  app_name=$(printf '%s' "$index_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("ipa") or {}).get("app_name",""))')
  [ -n "$bundle" ] || die "side-load: this token was pushed without --ipa (no bundle id); re-push with --ipa"
  [ -n "$version" ] || die "side-load: this token has no IPA version metadata"
  source_url="$BASE_URL/tmp/$token/source.json"
  ident="dev.3ds2apple.transfer.$token"

  if [ "$dry" = 1 ]; then
    emit_source_json "$ident" "$app_name" "$bundle" "$version" "$url" "$size"
    return 0
  fi
  emit_source_json "$ident" "$app_name" "$bundle" "$version" "$url" "$size" |
    vps "cat > '$TMP_ROOT/$token/source.json' && chmod 644 '$TMP_ROOT/$token/source.json'" || die "could not upload source.json"
  echo "SideStore source: $source_url"
  echo "bundle: $bundle  version: $version  bytes: $size"
  echo "steps:"
  echo "  1. iPhone -> SideStore -> Sources -> + -> $source_url"
  echo "  2. Pull to refresh, open the app entry, tap Install (keep the iPhone on power/Wi-Fi)."
  echo "  3. After the install: scripts/dev-transfer.sh clean $token"
}

# ---------------------------------------------------------------------------
# list / clean
# ---------------------------------------------------------------------------
cmd_list() {
  local rows="" now=""
  require_vps
  rows=$(list_index_tsv)
  now=$(epoch_now)
  if [ -z "$rows" ]; then
    echo "no active relay tokens"
    echo "remote index: $VPS_TARGET:$INDEX_DIR"
    return 0
  fi
  printf '%-26s %-12s %-30s %-10s %s\n' "TOKEN" "SIZE" "NAME" "STATE" "URL"
  printf '%s\n' "$rows" | while IFS='|' read -r tok exp bytes kind name url; do
    state="active"
    if [ "$exp" -le "$now" ]; then state="EXPIRED"; fi
    printf '%-26s %-12s %-30s %-10s %s\n' "$tok" "$(human_bytes "$bytes")" "$name" "$state" "$url"
  done
}

cmd_clean() {
  local token="" expired=0 all=0 orphans=0 yes=0 dry=0 rows="" now="" dirs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --expired) expired=1 ;;
      --all) all=1 ;;
      --orphans) orphans=1 ;;
      --yes) yes=1 ;;
      --dry-run|-n) dry=1 ;;
      -*) die "clean: unknown option $1" ;;
      *) if [ -z "$token" ]; then token="$1"; else die "clean: unexpected argument $1"; fi ;;
    esac
    shift || true
  done
  require_vps
  now=$(epoch_now)

  if [ -n "$token" ]; then
    validate_token "$token" || die "clean: invalid token format (expected 24 lowercase hex characters)"
    if vps "test -d '$TMP_ROOT/$token' || test -f '$INDEX_DIR/$token.json'"; then
      if [ "$dry" = 1 ]; then
        echo "dry-run: would remove $VPS_TARGET:$TMP_ROOT/$token and $VPS_TARGET:$INDEX_DIR/$token.json"
        return 0
      fi
      vps "rm -rf '$TMP_ROOT/$token' '$INDEX_DIR/$token.json'" || die "clean: remote removal failed"
      echo "cleaned token $token (web dir + index entry removed)"
    else
      echo "token $token not found (already clean)"
    fi
    return 0
  fi

  if [ "$expired" = 1 ]; then
    rows=$(list_index_tsv)
    printf '%s\n' "$rows" | while IFS='|' read -r tok exp bytes kind name url; do
      [ -n "$tok" ] || continue
      if [ "$exp" -le "$now" ]; then
        if [ "$dry" = 1 ]; then
          echo "dry-run: would clean expired token $tok ($name)"
        else
          vps "rm -rf '$TMP_ROOT/$tok' '$INDEX_DIR/$tok.json'" && echo "cleaned expired token $tok ($name)"
        fi
      fi
    done
    return 0
  fi

  if [ "$orphans" = 1 ]; then
    dirs=$(vps "ls -1 '$TMP_ROOT' 2>/dev/null" || true)
    printf '%s\n' "$dirs" | while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      validate_token "$tok" || continue
      if ! vps "test -f '$INDEX_DIR/$tok.json'"; then
        if [ "$dry" = 1 ]; then
          echo "dry-run: would remove orphan dir $tok"
        else
          vps "rm -rf '$TMP_ROOT/$tok'" && echo "removed orphan dir $tok"
        fi
      fi
    done
    return 0
  fi

  if [ "$all" = 1 ]; then
    if [ "$yes" != 1 ]; then
      die "clean --all removes every token (web dirs + index entries); re-run with --yes"
    fi
    rows=$(list_index_tsv)
    printf '%s\n' "$rows" | while IFS='|' read -r tok exp bytes kind name url; do
      [ -n "$tok" ] || continue
      if [ "$dry" = 1 ]; then
        echo "dry-run: would clean $tok"
      else
        vps "rm -rf '$TMP_ROOT/$tok' '$INDEX_DIR/$tok.json'" && echo "cleaned $tok"
      fi
    done
    return 0
  fi

  echo "usage: clean <token> | clean --expired | clean --orphans | clean --all --yes" >&2
  return 2
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
cmd_doctor() {
  local rc=0 code tmpd="" n=""
  echo "dev-transfer doctor ($SCRIPT_NAME $SCRIPT_VERSION)"
  echo "host:        $(hostname 2>/dev/null || echo unknown)  uname: $(uname -s)"
  echo "vps:         $VPS_TARGET (key $VPS_KEY)"
  echo "base url:    $BASE_URL"
  echo ""
  for c in ssh scp python3 openssl curl rsync unzip; do
    if command -v "$c" >/dev/null 2>&1; then echo "ok:   $c"; else echo "warn: $c missing (needed for some commands)"; fi
  done
  if [ -f "$VPS_KEY" ]; then echo "ok:   VPS key present"; else echo "fail: VPS key missing at $VPS_KEY"; rc=1; fi
  if vps_ok; then
    echo "ok:   ssh $VPS_TARGET (BatchMode)"
    vps "mkdir -p '$TMP_ROOT' '$INDEX_DIR' && chmod 755 '$TMP_ROOT' && chmod 700 '$INDEX_DIR'" && echo "ok:   remote dirs ready"
    vps "df -h '$WEB_ROOT' | tail -1" | sed 's/^/      /'
    n=$(vps "ls -1 '$TMP_ROOT' 2>/dev/null | wc -l")
    echo "info: token dirs on VPS: $n"
  else
    echo "fail: ssh $VPS_TARGET failed (run this on the CachyOS host with the VPS root key)"; rc=1
  fi
  if [ -f "$VM_KEY" ]; then
    if vm_ok; then echo "ok:   macOS VM reachable at $VM_TARGET:$VM_PORT"; else echo "warn: macOS VM not reachable at $VM_TARGET:$VM_PORT (only needed for --vm)"; fi
  else
    echo "warn: VM key missing at $VM_KEY (only needed for --vm)"
  fi
  tmpd=$(mktemp)
  if curl --fail --location --max-time 20 --silent --output /dev/null --write-out '%{http_code}' "$BASE_URL/source.json" > "$tmpd" 2>/dev/null; then
    code=$(cat "$tmpd")
    echo "ok:   $BASE_URL/source.json -> HTTP $code"
  else
    echo "fail: cannot fetch $BASE_URL/source.json (HTTPS port 443, public cert)"; rc=1
  fi
  if curl --max-time 20 --silent --output /dev/null --write-out '%{http_code}' "$BASE_URL/tmp/" > "$tmpd" 2>/dev/null; then
    code=$(cat "$tmpd")
    if [ "$code" = "403" ] || [ "$code" = "404" ]; then
      echo "ok:   $BASE_URL/tmp/ is not listable (HTTP $code)"
    else
      echo "warn: $BASE_URL/tmp/ returned HTTP $code; check nginx autoindex off"
    fi
  fi
  rm -f "$tmpd"
  echo ""
  echo "expected throughput (measured 2026-11-14):"
  echo "  VM -> CachyOS host (QEMU localhost):  ~15.5 MB/s"
  echo "  CachyOS host -> VPS (upload):         ~4.7-4.9 MB/s"
  echo "  VPS -> client (download):             0.19-0.42 MB/s (VPS egress cap, shared; varies)"
  echo "  1.5 GB artifact via VPS relay:        ~6-9 min push + ~60-130 min pull"
  echo "recommended for 1.5 GB: direct LAN (lan push/lan fetch) or a VPS with more egress bandwidth."
  return "$rc"
}

# ---------------------------------------------------------------------------
# speedtest
# ---------------------------------------------------------------------------
cmd_speedtest() {
  local size_mb=32 keep=0
  local tmpd="" token="" url="" sha="" size_bytes="" t0="" t1="" push_ms="" dl_ms="" push_json=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --size-mb) shift; size_mb="$1" ;;
      --keep) keep=1 ;;
      --dry-run|-n) echo "dry-run: would push/fetch/clean a $size_mb MiB random file"; return 0 ;;
      -*) die "speedtest: unknown option $1" ;;
      *) die "speedtest: unexpected argument $1" ;;
    esac
    shift || true
  done
  case "$size_mb" in
    ''|*[!0-9]*) die "speedtest: --size-mb must be an integer" ;;
  esac
  [ "$size_mb" -ge 4 ] || die "speedtest: --size-mb must be >= 4"
  [ "$size_mb" -le 128 ] || die "speedtest: --size-mb must be <= 128 (keep operations short)"

  require_vps
  need_cmd curl
  tmpd=$(mktemp -d)
  log "creating $size_mb MiB random test file"
  head -c $(( size_mb * 1048576 )) /dev/urandom > "$tmpd/speedtest.bin"
  size_bytes=$(wc -c < "$tmpd/speedtest.bin")
  log "push leg (local -> VPS)"
  t0=$(ms_now)
  push_json=$(bash "$SELF" push "$tmpd/speedtest.bin" --name speedtest.bin --ttl 30 --json) || { rm -rf "$tmpd"; die "push failed"; }
  t1=$(ms_now)
  push_ms=$(( (t1 - t0) / 1000000 ))
  sha=$(printf '%s' "$push_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])') || { rm -rf "$tmpd"; die "push output was not valid JSON"; }
  token=$(printf '%s' "$push_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  url=$(printf '%s' "$push_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
  log "fetch leg (VPS -> local)"
  t0=$(ms_now)
  bash "$SELF" fetch "$url" "$tmpd/download.bin" --sha256 "$sha" >/dev/null || { rm -rf "$tmpd"; die "fetch failed"; }
  t1=$(ms_now)
  dl_ms=$(( (t1 - t0) / 1000000 ))
  echo ""
  echo "speedtest $size_mb MiB (sha256 verified):"
  echo "  push local->VPS:  $size_bytes bytes, $push_ms ms, $(rate_mb_s "$size_bytes" "$push_ms") MB/s"
  echo "  fetch VPS->local: $size_bytes bytes, $dl_ms ms, $(rate_mb_s "$size_bytes" "$dl_ms") MB/s"
  echo "  projected 1.5 GB: push ~$(project_min 1572864000 "$(rate_mb_s "$size_bytes" "$push_ms")") min, pull ~$(project_min 1572864000 "$(rate_mb_s "$size_bytes" "$dl_ms")") min"
  if [ "$keep" = 1 ]; then
    echo "kept token: $token  url: $url"
  else
    bash "$SELF" clean "$token" >/dev/null 2>&1 || warn "cleanup of $token failed; run: scripts/dev-transfer.sh clean $token"
    echo "cleaned token $token"
  fi
  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# LAN direct path
# ---------------------------------------------------------------------------
cmd_lan() {
  local sub="" spec="" path="" sha="" dry=0 got=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha256) shift; sha="$1" ;;
      --dry-run|-n) dry=1 ;;
      -*) die "lan: unknown option $1" ;;
      *) if [ -z "$sub" ]; then sub="$1"; elif [ -z "$spec" ]; then spec="$1"; elif [ -z "$path" ]; then path="$1"; else die "lan: unexpected argument $1"; fi ;;
    esac
    shift || true
  done
  need_cmd rsync
  case "$sub" in
    push)
      [ -n "$path" ] || die "usage: lan push <user@host:/dest/dir/> <file> [--dry-run]"
      [ -f "$path" ] || die "lan push: no such file: $path"
      if [ "$dry" = 1 ]; then echo "dry-run: rsync -avP --partial --inplace '$path' '$spec'"; return 0; fi
      rsync -avP --partial --inplace -e "ssh -o BatchMode=yes -o ConnectTimeout=15" "$path" "$spec" || die "lan push failed"
      echo "sent: $(sha_of "$path")  $path"
      ;;
    fetch)
      [ -n "$path" ] || die "usage: lan fetch <user@host:/path/file> <dest> [--sha256 HASH] [--dry-run]"
      if [ "$dry" = 1 ]; then echo "dry-run: rsync -avP --partial --inplace '$spec' '$path'"; return 0; fi
      rsync -avP --partial --inplace -e "ssh -o BatchMode=yes -o ConnectTimeout=15" "$spec" "$path" || die "lan fetch failed"
      if [ -n "$sha" ]; then
        got=$(sha_of "$path")
        [ "$got" = "$sha" ] || die "lan fetch: sha256 mismatch (expected $sha, got $got)"
        echo "verified: $path"
      else
        warn "no --sha256 given; verify on the sender with sha256sum"
      fi
      ;;
    *) die "lan: subcommand must be push or fetch (direct rsync; fastest once both hosts share a LAN)" ;;
  esac
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
cmd_help() {
  cat <<'EOF'
dev-transfer.sh - one-command, hash-verified dev file transfer for 3ds2apple

USAGE
  scripts/dev-transfer.sh <command> [options]

COMMANDS
  push <file> [--name NAME] [--ttl MIN] [--max-bytes N] [--ipa]
             [--vm <path-on-macOS-VM>] [--dry-run] [--json]
      Upload a file (or a file from the macOS VM via --vm) to the VPS under a
      random one-time path, verify sha256 end to end and print the https URL,
      the sha256 and the cleanup command. --ipa also publishes a SideStore
      source.json and prints install steps.

  fetch <url> [<dest>] [--sha256 HASH] [--no-verify] [--max-bytes N] [--dry-run]
      Download (resumable: rerun after an interruption) and verify sha256.
      Without --sha256 the published <url>.sha256 sidecar is used.

  side-load <token> [--dry-run]
      Re-generate/publish the SideStore source.json for an --ipa token and print
      the exact SideStore steps.

  list
      List active/expired relay tokens on the VPS (read only).

  clean <token> | clean --expired | clean --orphans | clean --all --yes
      Remove token paths and index entries. Always clean after the transfer.

  doctor
      Check keys, SSH, HTTPS, remote dirs, disk space and expected throughput.

  speedtest [--size-mb N] [--keep]
      Round trip push+fetch of N MiB (4..128, default 32) with sha256
      verification, prints MB/s per leg and projected 1.5 GB time, then cleans up.

  lan push <user@host:/dest/dir/> <file>
  lan fetch <user@host:/path/file> <dest> [--sha256 HASH]
      Direct rsync over a shared LAN. Fastest option when the build machine and
      the workstation are on the same network; no VPS involved.

ENVIRONMENT
  DT_VPS_TARGET  DT_VPS_KEY  DT_VPS_PORT   (default root@47.115.170.160, ~/.ssh/id_ed25519, 22)
  DT_VM_TARGET   DT_VM_KEY   DT_VM_PORT     (default kratoshuang@127.0.0.1, ~/.ssh/3ds2apple_macos, 2222)
  DT_TMP_ROOT    DT_INDEX_DIR DT_BASE_URL   (default /var/www/ios/tmp, /var/lib/dev-transfer,
                                             https://47.115.170.160/ios)
  DT_TTL_MINUTES DT_MAX_BYTES

EXAMPLES
  # CachyOS host: bundled-ROM IPA straight from the macOS VM to the VPS
  scripts/dev-transfer.sh push --vm "~/3ds2apple/IPA/3ds2apple-pokemon-y-bundled-rom.ipa" --ipa

  # Windows/WSL: resume-able download with the printed hash
  scripts/dev-transfer.sh fetch https://47.115.170.160/ios/tmp/<token>/<name>.ipa IPA/<name>.ipa --sha256 <hash>

  # after the install
  scripts/dev-transfer.sh clean <token>

NOTES
  Run push/list/clean/side-load/doctor/speedtest on the CachyOS build host (only it
  holds the VPS root key); fetch and lan fetch run anywhere. Artifact tokens are
  unauthenticated but unguessable random 96-bit paths: never share the URL, and always
  clean up. Never commit ROM/IPA content or paste artifact URLs into issues/logs.
EOF
}

# ---------------------------------------------------------------------------
# hidden helpers (used by scripts/tests/dev-transfer-selfcheck.sh)
# ---------------------------------------------------------------------------
cmd_internal() {
  local what=""
  if [ $# -gt 0 ]; then what="$1"; shift; fi
  case "$what" in
    validate-token) if validate_token "$1"; then echo valid; else echo invalid; fi ;;
    sanitize-name) sanitize_name "$1" ;;
    source-json) emit_source_json "$1" "$2" "$3" "$4" "$5" "$6" ;;
    ipa-meta) ipa_metadata "$1" ;;
    *) die "internal: unknown helper $what" ;;
  esac
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
load_env
SELF="$0"
cmd="help"
if [ $# -gt 0 ]; then cmd="$1"; shift; fi

case "$cmd" in
  push) cmd_push "$@" ;;
  fetch) cmd_fetch "$@" ;;
  side-load|sideload) cmd_side_load "$@" ;;
  list|ls) cmd_list "$@" ;;
  clean) cmd_clean "$@" ;;
  doctor|check) cmd_doctor "$@" ;;
  speedtest|bench) cmd_speedtest "$@" ;;
  lan) cmd_lan "$@" ;;
  help|--help|-h) cmd_help ;;
  version|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION" ;;
  __internal) cmd_internal "$@" ;;
  *) echo "unknown command: $cmd" >&2; cmd_help >&2; exit 2 ;;
esac
