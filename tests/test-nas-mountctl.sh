#!/usr/bin/env bash
# tests/test-nas-mountctl.sh — argument rejection, WITHOUT root.
# NAS_DRYRUN=1 makes the script print what it would run instead of running it.
set -uo pipefail
BIN="$(dirname "$0")/../bin/omarchy-nas-mountctl"
fail=0
ok(){ printf '  ok   %s\n' "$1"; }
bad(){ printf '  FAIL %s\n' "$1"; fail=1; }

for evil in "../etc/shadow" "/etc/passwd" "a;rm -rf /" "a b" "a/b/c" ".." "" '$(id)'; do
  if NAS_DRYRUN=1 "$BIN" mount "$evil" >/dev/null 2>&1; then bad "accepted: $evil"; else ok "rejected: $evil"; fi
done
NAS_DRYRUN=1 "$BIN" bogusverb Backup4TB >/dev/null 2>&1 && bad "accepted bad verb" || ok "rejected bad verb"
NAS_DRYRUN=1 "$BIN" mount >/dev/null 2>&1 && bad "accepted no args" || ok "rejected no args"

out=$(NAS_DRYRUN=1 "$BIN" mount Backup4TB/ISOs 2>&1)
grep -q "/mnt/Backup4TB-ISOs" <<<"$out" && ok "nested flattens" || bad "nested target wrong: $out"
grep -q "10.0.0.118:/mnt/SpeakerOffice/Backup4TB/ISOs" <<<"$out" && ok "nested source" || bad "nested source wrong: $out"
exit $fail
