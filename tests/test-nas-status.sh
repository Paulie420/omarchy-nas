#!/usr/bin/env bash
# tests/test-nas-status.sh — shape and hang-safety, not NAS truth.
set -uo pipefail
BIN="$(dirname "$0")/../bin/omarchy-nas-status"
fail=0
ok(){ printf '  ok   %s\n' "$1"; }
bad(){ printf '  FAIL %s\n' "$1"; fail=1; }

start=$(date +%s)
out="$("$BIN" 2>/dev/null)"; rc=$?
elapsed=$(( $(date +%s) - start ))

[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc"
echo "$out" | jq -e . >/dev/null 2>&1 && ok "valid JSON" || bad "not JSON: $out"
[ "$elapsed" -le 12 ] && ok "returned in ${elapsed}s" || bad "took ${elapsed}s (must not hang)"
for k in reachable transport pivpn shares available; do
  echo "$out" | jq -e "has(\"$k\")" >/dev/null && ok "has .$k" || bad "missing .$k"
done
echo "$out" | jq -e '.transport|test("^(lan|pivpn|none)$")' >/dev/null && ok "transport enum" || bad "bad transport"
echo "$out" | jq -e '.shares|type=="array"' >/dev/null && ok "shares array" || bad "shares not array"
echo "$out" | jq -e '.available|type=="array"' >/dev/null && ok "available array" || bad "available not array"
echo "$out" | jq -e '.pivpn.up|type=="boolean"' >/dev/null && ok "pivpn.up boolean" || bad "pivpn.up not boolean"
echo "$out" | jq -e '.pivpn.handshake|type=="boolean"' >/dev/null && ok "pivpn.handshake boolean" || bad "pivpn.handshake not boolean"
echo "$out" | jq -e '.shares[]|has("name")' >/dev/null && ok "shares[].name present" || bad "shares[].name missing"
echo "$out" | jq -e '.shares[]|has("target")' >/dev/null && ok "shares[].target present" || bad "shares[].target missing"
echo "$out" | jq -e '.shares[]|has("mounted")' >/dev/null && ok "shares[].mounted present" || bad "shares[].mounted missing"
echo "$out" | jq -e '.shares[]|.free==null or (.free|type=="string" and . != "null")' >/dev/null && ok "shares[].free null-or-string (not literal null)" || bad "shares[].free is literal string \"null\" or wrong type"

# Test with unmounted shares (df timeout simulation): when no shares are mounted,
# free should be JSON null, not the string "null".
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/omarchy/state"
echo '["extra"]' > "$TEST_DIR/omarchy/state/nas-shares.json"
test_out=$(XDG_CONFIG_HOME="$TEST_DIR" "$BIN" 2>/dev/null)
echo "$test_out" | jq -e '.shares[0].free == null' >/dev/null && ok "unmounted share free is JSON null" || bad "unmounted share free is not JSON null: $(echo "$test_out" | jq -c '[.shares[].free]')"
rm -rf "$TEST_DIR"

exit $fail
