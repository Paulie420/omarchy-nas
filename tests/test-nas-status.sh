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

# Test zero-mounted case: when no shares are mounted, free should be JSON null,
# not the string "null". This verifies the unmounted path only, not df behavior.
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/omarchy/state"
echo '["extra"]' > "$TEST_DIR/omarchy/state/nas-shares.json"
test_out=$(XDG_CONFIG_HOME="$TEST_DIR" "$BIN" 2>/dev/null)
echo "$test_out" | jq -e '.shares[0].free == null' >/dev/null && ok "zero-mounted case produces JSON null" || bad "zero-mounted case produces not JSON null: $(echo "$test_out" | jq -c '[.shares[].free]')"
rm -rf "$TEST_DIR"

# Test df timeout: mounted status must survive df hanging. When df stalls,
# shares that findmnt reports as mounted must stay mounted:true with free:null.
# This is the core hang-safety guarantee: findmnt (which cannot hang) is the
# authority on mounted status, df (which can hang) affects only free space.
if [ "$elapsed" -le 12 ] && [ $rc -eq 0 ]; then
  # Only run this test if the normal case has mounted shares to test with.
  mount_count=$(echo "$out" | jq '[.shares[]|select(.mounted==true)]|length')
  if [ "$mount_count" -gt 0 ]; then
    SHIM=$(mktemp -d)
    printf '#!/bin/sh\nsleep 30\n' > "$SHIM/df"
    chmod +x "$SHIM/df"

    shim_start=$(date +%s)
    shim_out=$(PATH="$SHIM:$PATH" "$BIN" 2>/dev/null); shim_rc=$?
    shim_elapsed=$(( $(date +%s) - shim_start ))

    rm -rf "$SHIM"

    [ $shim_rc -eq 0 ] && ok "df-timeout: exit 0" || bad "df-timeout: exit $shim_rc"
    [ "$shim_elapsed" -le 12 ] && ok "df-timeout: returned in ${shim_elapsed}s" || bad "df-timeout: took ${shim_elapsed}s"

    # Verify mounted shares stayed mounted even though df hung.
    shim_mounted=$(echo "$shim_out" | jq '[.shares[]|select(.mounted==true)]|length')
    [ "$shim_mounted" -eq "$mount_count" ] && ok "df-timeout: mounted=$mount_count preserved" || bad "df-timeout: mounted=$shim_mounted but expected $mount_count"

    # Verify free space became null since df timed out.
    shim_free_all_null=$(echo "$shim_out" | jq -e '[.shares[]|select(.mounted==true)|.free]|all(. == null)')
    $shim_free_all_null >/dev/null && ok "df-timeout: all mounted .free is null" || bad "df-timeout: free not all null: $(echo "$shim_out" | jq -c '[.shares[]|select(.mounted==true)|.free]')"
  else
    printf '  skip df-timeout test (no mounted shares to test with)\n'
  fi
else
  printf '  skip df-timeout test (normal test already slow or failed)\n'
fi

exit $fail
