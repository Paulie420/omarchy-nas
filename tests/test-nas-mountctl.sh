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

# --- nas_prepare_target() symlink-hazard guard -----------------------------
# NAS_MOUNT_ROOT is pinned to /mnt inside the real script by design (the
# CONTROLLER RULING) and we have no write access to /mnt as a non-root user,
# so these cases source the script (which, when sourced, defines
# nas_prepare_target() and returns without running the CLI body — see the
# BASH_SOURCE[0] guard in the script) and call the function directly against
# a disposable temp directory. This never touches /mnt or any real share.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
# shellcheck source=/dev/null
source "$BIN"

# 1. Target is a symlink to a directory: must refuse, must NOT create/replace
#    anything, and must leave the link pointing at its original victim.
victim="$fixture/victim"; mkdir -p "$victim"
linktgt="$fixture/evil-link"
ln -s "$victim" "$linktgt"
if nas_prepare_target "symlinktest" "$linktgt" 2>/dev/null; then
  bad "symlink target was accepted (should refuse)"
else
  ok "symlink target refused"
fi
[[ -L $linktgt ]] && [[ "$(readlink "$linktgt")" == "$victim" ]] && ok "symlink left untouched" || bad "symlink was modified"

# 2. Target exists as a regular file: must refuse cleanly.
filetgt="$fixture/plain-file"
: > "$filetgt"
if nas_prepare_target "filetest" "$filetgt" 2>/dev/null; then
  bad "regular-file target was accepted (should refuse)"
else
  ok "regular-file target refused"
fi
[[ -f $filetgt && ! -d $filetgt ]] && ok "regular file left untouched" || bad "regular file was altered"

# 3. Target is a normal, pre-existing directory: must still succeed (this is
#    the exact case the naive `mkdir` (no -p) fix would have broken, since
#    all four live mount points already exist as real directories).
dirtgt="$fixture/real-dir"; mkdir -p "$dirtgt"
if nas_prepare_target "dirtest" "$dirtgt" 2>/dev/null; then
  ok "pre-existing directory accepted"
else
  bad "pre-existing directory was refused"
fi
[[ -d $dirtgt ]] && ok "pre-existing directory still a directory" || bad "pre-existing directory disappeared"

# 4. Target absent: must be created.
absenttgt="$fixture/not-there-yet"
if nas_prepare_target "absenttest" "$absenttgt" 2>/dev/null; then
  ok "absent target accepted"
else
  bad "absent target was refused"
fi
[[ -d $absenttgt && ! -L $absenttgt ]] && ok "absent target created as a real directory" || bad "absent target not created correctly"

exit $fail
