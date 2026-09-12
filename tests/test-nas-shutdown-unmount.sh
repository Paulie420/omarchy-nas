#!/usr/bin/env bash
# tests/test-nas-shutdown-unmount.sh — WITHOUT root, WITHOUT real mounts.
# NAS_DRYRUN=1 makes unmount_one() print what it would run instead of
# running it; a fake findmnt on PATH stands in for real mount state.
set -uo pipefail
BIN="$(dirname "$0")/../bin/omarchy-nas-shutdown-unmount"
fail=0
ok(){ printf '  ok   %s\n' "$1"; }
bad(){ printf '  FAIL %s\n' "$1"; fail=1; }

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/findmnt" <<'EOF'
#!/bin/bash
# Stand-in for `findmnt -rn -t nfs,nfs4,cifs,smb3 -o TARGET`.
printf '/mnt/Backup4TB\n/mnt/Beers4TB\n'
EOF
chmod +x "$fixture/findmnt"
PATH="$fixture:$PATH"

# shellcheck source=/dev/null
source "$BIN"

out=$(list_targets)
[[ $out == $'/mnt/Backup4TB\n/mnt/Beers4TB' ]] \
  && ok "list_targets reads findmnt's target list" \
  || bad "list_targets returned: $out"

out=$(NAS_DRYRUN=1 unmount_one "/mnt/Backup4TB")
[[ $out == "would umount -l /mnt/Backup4TB" ]] \
  && ok "dry-run reports the lazy umount it would issue" \
  || bad "dry-run output: $out"

exit $fail
