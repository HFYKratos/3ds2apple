#!/usr/bin/env bash
# dev-transfer self-check: static checks + offline unit tests for scripts/dev-transfer.sh.
# No ROM/IPA content, no credentials and (by default) no network traffic.
#
#   bash scripts/tests/dev-transfer-selfcheck.sh
#   DT_NETWORK_TEST=1 bash scripts/tests/dev-transfer-selfcheck.sh   # optional 16 MiB
#                                                                    # push/fetch/clean on the VPS
#
# Run on Linux (WSL or the CachyOS host). The network test needs the VPS root key
# and is normally run on the CachyOS host.

set -o pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/dev-transfer.sh"
DOC="$ROOT/docs/dev-transfer.md"
README="$ROOT/scripts/README.md"

checks=0
fails=0
pass() { checks=$((checks + 1)); echo "ok: $*"; }
skip() { echo "skip: $*"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 2; }

tmpd=$(mktemp -d)
cleanup() { rm -rf "$tmpd"; }
trap cleanup EXIT

echo "== syntax and static checks =="
if bash -n "$SCRIPT"; then pass "bash -n dev-transfer.sh"; else fail "bash -n dev-transfer.sh"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$SCRIPT"; then pass "shellcheck -S error"; else fail "shellcheck -S error"; fi
else
  skip "shellcheck not installed"
fi
if grep -q 'PRIVATE KEY' "$SCRIPT"; then fail "script must not contain private key markers"; else pass "no private key material"; fi
if grep -Eq 'sshpass|ssh __|password=' "$SCRIPT"; then fail "script must not handle passwords"; else pass "no password handling"; fi
if grep -Eq 'curl[^|]* -k( |$)|--insecure' "$SCRIPT"; then fail "curl must not disable TLS verification"; else pass "TLS verification not disabled"; fi
if grep -Eq '/etc/nginx|sites-enabled|nginx -s' "$SCRIPT"; then fail "script must not change nginx config"; else pass "no nginx config changes"; fi
if grep -q 'clean TOKEN' "$SCRIPT"; then pass "cleanup documented"; else fail "cleanup documentation missing"; fi

echo "== token and path validation =="
goodtoken=$(openssl rand -hex 12 2>/dev/null || echo 0123456789abcdef01234567)
if [ "$(bash "$SCRIPT" __internal validate-token "$goodtoken")" = "valid" ]; then pass "24-hex token accepted"; else fail "24-hex token rejected"; fi
for bad in "../../etc" "c45ba06dc7d9c299" "0123456789ABCDEF01234567" "" "0123456789abcdef0123456g"; do
  if [ "$(bash "$SCRIPT" __internal validate-token "$bad")" = "invalid" ]; then pass "bad token rejected: [$bad]"; else fail "bad token accepted: [$bad]"; fi
done
[ "$(bash "$SCRIPT" __internal sanitize-name '../evil name.ipa')" = "evilname.ipa" ] && pass "path traversal sanitized" || fail "path traversal not sanitized"
[ "$(bash "$SCRIPT" __internal sanitize-name '')" = "artifact.bin" ] && pass "empty name fallback" || fail "empty name fallback"

echo "== SideStore source.json =="
srcjson=$(bash "$SCRIPT" __internal source-json "dev.3ds2apple.transfer.0123456789abcdef01234567" "3ds2apple" "com.kratos.3ds2apple" "0.1.5-beta3" "https://example.invalid/ios/tmp/t/a.ipa" "3937961")
if printf '%s' "$srcjson" | python3 -c 'import json,sys
d=json.load(sys.stdin)
app=d["apps"][0]
v=app["versions"][0]
assert app["bundleIdentifier"]=="com.kratos.3ds2apple"
assert v["version"]=="0.1.5-beta3"
assert v["downloadURL"]=="https://example.invalid/ios/tmp/t/a.ipa"
assert int(v["size"])==3937961
assert d["identifier"].startswith("dev.3ds2apple.transfer.")
print("valid")' | grep -q valid; then pass "source.json shape"; else fail "source.json shape"; fi

echo "== IPA metadata parsing =="
if command -v unzip >/dev/null 2>&1; then
  python3 - "$tmpd/fake.ipa" <<'PY'
import plistlib, sys, zipfile
plist = {
    "CFBundleIdentifier": "com.kratos.3ds2apple",
    "CFBundleShortVersionString": "0.1.5-beta3",
    "CFBundleDisplayName": "3ds2apple Test",
}
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("Payload/Test.app/Info.plist", plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
PY
  meta=$(bash "$SCRIPT" __internal ipa-meta "$tmpd/fake.ipa" 2>/dev/null)
  if [ "$meta" = "com.kratos.3ds2apple|0.1.5-beta3|3ds2apple Test" ]; then
    pass "synthetic IPA Info.plist parsed"
  else
    fail "synthetic IPA Info.plist parsed (got [$meta])"
  fi
else
  skip "zip/unzip not installed; IPA metadata test skipped"
fi

echo "== dry-run / argument handling (no network) =="
head -c 1048576 /dev/urandom > "$tmpd/small.bin"
out=$(bash "$SCRIPT" push "$tmpd/small.bin" --name test.bin --dry-run 2>&1)
if printf '%s' "$out" | grep -q "dry-run: no remote changes" && printf '%s' "$out" | grep -q "clean <token>"; then
  pass "push --dry-run"
else
  fail "push --dry-run"
fi
if bash "$SCRIPT" push "$tmpd/nope.bin" >/dev/null 2>&1; then fail "push accepts a missing file"; else pass "push rejects a missing file"; fi
if bash "$SCRIPT" push >/dev/null 2>&1; then fail "push accepts no arguments"; else pass "push rejects no arguments"; fi
if bash "$SCRIPT" fetch "not-a-url" "$tmpd/x" >/dev/null 2>&1; then fail "fetch accepts a token as URL"; else pass "fetch rejects a token as URL"; fi
out=$(bash "$SCRIPT" fetch "https://example.invalid/x.ipa" "$tmpd/x.ipa" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "dry-run: would curl"; then pass "fetch --dry-run"; else fail "fetch --dry-run"; fi
out=$(bash "$SCRIPT" speedtest --size-mb 8 --dry-run 2>&1)
if printf '%s' "$out" | grep -q "dry-run: would push/fetch/clean"; then pass "speedtest --dry-run"; else fail "speedtest --dry-run"; fi
if bash "$SCRIPT" not-a-command >/dev/null 2>&1; then fail "unknown command accepted"; else pass "unknown command rejected"; fi
if bash "$SCRIPT" clean invalid-token >/dev/null 2>&1; then fail "clean accepts an invalid token"; else pass "clean rejects an invalid token"; fi

echo "== docs hook =="
if [ -f "$DOC" ]; then
  if grep -q "0.42 MB/s" "$DOC" && grep -q "VPS egress" "$DOC"; then pass "docs/dev-transfer.md records measured numbers"; else fail "docs/dev-transfer.md missing measured numbers"; fi
else
  fail "docs/dev-transfer.md missing"
fi
if [ -f "$README" ] && grep -q "dev-transfer.sh" "$README"; then pass "scripts/README.md lists dev-transfer.sh"; else fail "scripts/README.md not updated"; fi

echo "== repo hygiene =="
if grep -Il -E 'BEGIN OPENSSH PRIVATE KEY|ssh-ed25519 AAAA' "$SCRIPT" "$DOC" 2>/dev/null | grep -q .; then
  fail "no private keys in the new files"
else
  pass "no private keys in the new files"
fi

if [ -n "$DT_NETWORK_TEST" ]; then
  echo "== optional network round trip (16 MiB) =="
  if bash "$SCRIPT" speedtest --size-mb 16 > "$tmpd/speedtest.out" 2>&1; then
    pass "network speedtest push+fetch+clean"
    cat "$tmpd/speedtest.out"
  else
    fail "network speedtest"
    cat "$tmpd/speedtest.out" >&2
  fi
else
  skip "network round trip (set DT_NETWORK_TEST=1 on the CachyOS host)"
fi

echo ""
echo "self-check: $checks checks, $fails failure(s)"
if [ "$fails" -ne 0 ]; then exit 1; fi
echo "PASS"
