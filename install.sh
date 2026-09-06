#!/usr/bin/env bash
#
# install.sh -- put the two NAS helpers on the system and register the polkit
# action that lets the bar widget mount without a terminal.
#
#   sudo ./install.sh          install or update
#   sudo ./install.sh --uninstall   remove everything this installed
#
# What lands where:
#   /usr/local/lib/omarchy-nas/nas-common.sh   shared path derivation
#   /usr/local/bin/omarchy-nas-status          unprivileged, reads state
#   /usr/local/bin/omarchy-nas-mountctl        ROOT via pkexec, mounts only
#   /usr/share/polkit-1/actions/org.omarchy.nas.policy
#
# Nothing here is setuid. omarchy-nas-mountctl gains privilege ONLY when
# invoked through pkexec against the action above, which authenticates first.
set -euo pipefail

LIBDIR=/usr/local/lib/omarchy-nas
BINDIR=/usr/local/bin
ACTIONS=/usr/share/polkit-1/actions
POLICY=org.omarchy.nas.policy

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This installs to /usr/local and /usr/share; run it with sudo:" >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

if [[ ${1:-} == --uninstall ]]; then
  rm -f "$BINDIR/omarchy-nas-status" "$BINDIR/omarchy-nas-mountctl" "$ACTIONS/$POLICY"
  rm -rf "$LIBDIR"
  echo "Removed NAS helpers and polkit action."
  echo "Note: this does NOT unmount anything. Your mounts are untouched."
  exit 0
fi

# Refuse to install a helper that is not there, rather than half-installing.
for f in lib/nas-common.sh bin/omarchy-nas-status bin/omarchy-nas-mountctl "polkit/$POLICY"; do
  [[ -f $here/$f ]] || { echo "missing: $here/$f" >&2; exit 1; }
done

# Sanity-gate the privileged helper before granting it a polkit action. If the
# test suite is present and failing, something is wrong and this is the last
# cheap moment to notice.
if [[ -f $here/tests/test-nas-mountctl.sh ]]; then
  if ! bash "$here/tests/test-nas-mountctl.sh" >/dev/null 2>&1; then
    echo "REFUSING TO INSTALL: tests/test-nas-mountctl.sh fails." >&2
    echo "That suite proves the root helper rejects malformed share names." >&2
    exit 1
  fi
  echo "  validation suite passes"
fi

# 0755 root:root everywhere. pkexec refuses to run a program that is group- or
# world-writable, so these modes are load-bearing, not cosmetic.
install -d -m 0755 -o root -g root "$LIBDIR"
install -m 0644 -o root -g root "$here/lib/nas-common.sh"       "$LIBDIR/nas-common.sh"
install -m 0755 -o root -g root "$here/bin/omarchy-nas-status"   "$BINDIR/omarchy-nas-status"
install -m 0755 -o root -g root "$here/bin/omarchy-nas-mountctl" "$BINDIR/omarchy-nas-mountctl"
install -m 0644 -o root -g root "$here/polkit/$POLICY"           "$ACTIONS/$POLICY"

echo "  installed helpers and polkit action"

# Prove the install actually works rather than assuming it did.
if ! "$BINDIR/omarchy-nas-status" >/dev/null 2>&1; then
  echo "WARNING: installed omarchy-nas-status did not run cleanly." >&2
  echo "         Most likely it cannot find $LIBDIR/nas-common.sh." >&2
  exit 1
fi
echo "  installed omarchy-nas-status runs and emits JSON"

if command -v pkaction >/dev/null 2>&1; then
  if pkaction --action-id org.omarchy.nas.manage-mounts >/dev/null 2>&1; then
    echo "  polkit action registered"
  else
    echo "WARNING: polkit did not pick up the action. Try: systemctl restart polkit" >&2
  fi
fi

cat <<'DONE'

Done.

Test it (this SHOULD prompt for your fingerprint or password):

    pkexec /usr/local/bin/omarchy-nas-mountctl umount Beers4TB
    findmnt -rn /mnt/Beers4TB          # expect: no output
    pkexec /usr/local/bin/omarchy-nas-mountctl mount Beers4TB
    findmnt -rn /mnt/Beers4TB          # expect: it is back

To remove everything:  sudo ./install.sh --uninstall
DONE
