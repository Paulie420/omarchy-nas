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
exit $fail
