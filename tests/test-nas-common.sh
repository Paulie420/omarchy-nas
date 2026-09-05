#!/usr/bin/env bash
# tests/test-nas-common.sh
set -uo pipefail
. "$(dirname "$0")/../lib/nas-common.sh"
fail=0
ok(){ printf '  ok   %s\n' "$1"; }
bad(){ printf '  FAIL %s\n' "$1"; fail=1; }

for good in Backup4TB newBackupXTB extra Backup4TB/ISOs a.b-c_d; do
  nas_valid_name "$good" && ok "accept $good" || bad "should accept $good"
done
for evil in "../etc/shadow" "/etc/passwd" "a;rm -rf /" "a b" "" "a/b/c" "a//b" ".." "-rf" '$(id)' 'a`id`'; do
  nas_valid_name "$evil" && bad "should reject: $evil" || ok "reject $evil"
done

[ "$(nas_target Backup4TB)" = /mnt/Backup4TB ] && ok "target flat" || bad "target flat"
[ "$(nas_target Backup4TB/ISOs)" = /mnt/Backup4TB-ISOs ] && ok "target nested" || bad "target nested"
[ "$(nas_source extra)" = 10.0.0.118:/mnt/SpeakerOffice/extra ] && ok "source" || bad "source"
exit $fail
