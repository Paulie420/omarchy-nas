# paulie420.nas

A NAS bar widget for the [Omarchy](https://omarchy.org) Quattro shell. Shows which
NFS shares are mounted, mounts and unmounts them without opening a terminal, and
lets you add new shares by picking them off the NAS instead of typing paths.

Built for a Synology-style export layout where every share lives under one export
base (`/mnt/SpeakerOffice/<name>`) and mounts to `/mnt/<name>`.

## What it looks like

    ┌─ NAS ──────────────── via LAN ─┐
    │ ● Backup4TB        573G   [⏏]  │
    │ ● Backup6TB        439G   [⏏]  │
    │ ○ newBackupXTB       —    [↑]  │
    │── Available on NAS ────────────│
    │ + TimeMachine                  │
    │ + extra                        │
    │────────────────────────────────│
    │ [ Mount all ]  [ Open /mnt ]   │
    └────────────────────────────────┘

The bar icon shows a live mounted count (`4/4`), tinted when some are missing.

## Install

    git clone <this repo> ~/.config/omarchy/plugins/paulie420.nas
    cd ~/.config/omarchy/plugins/paulie420.nas
    sudo ./install.sh
    omarchy plugin enable paulie420.nas right

`install.sh` puts two helpers on the system and registers a polkit action:

| Path | Purpose |
|---|---|
| `/usr/local/lib/omarchy-nas/nas-common.sh` | shared path derivation |
| `/usr/local/bin/omarchy-nas-status` | unprivileged; prints state as JSON |
| `/usr/local/bin/omarchy-nas-mountctl` | root via pkexec; mounts only |
| `/usr/share/polkit-1/actions/org.omarchy.nas.policy` | the auth action |

Remove it all with `sudo ./install.sh --uninstall` (this does **not** unmount
anything).

## Authentication

Mounting asks polkit, which means the graphical prompt — **no terminal, no
password typed into a shell**. If your PAM stack lists `pam_fprintd` as
`sufficient` ahead of `pam_unix` in `/etc/pam.d/polkit-1` (Omarchy's default when
a fingerprint reader is enrolled), the prompt takes a fingerprint *or* a typed
password: a successful touch short-circuits, anything else falls through to the
password field.

The action uses `auth_admin_keep`, so mounting one share and immediately
unmounting another does not ask twice. "Mount all" passes every share to the
helper in a single call, so it costs **one** authentication, not one per share.

## Configuration

Settings are read-only, from the widget's entry in `~/.config/omarchy/shell.json`:

    refreshIntervalSec   5-120, default 10 (poll rate while the panel is open)

Your share list is **not** a setting — the shell provides no way for a plugin to
write its own settings back. It lives in a state file the plugin owns:

    ~/.config/omarchy/state/nas-shares.json      ["Backup4TB", "Backup6TB", ...]

Seeded on first run from whatever is already mounted, so an existing setup adopts
itself. Adding a share is an unprivileged write to `$HOME`; only the mount needs
polkit.

## Design notes

**Nothing on the paint path can hang.** NFS calls block for the full timeout when
a server disappears, which would take the whole status bar down with it. So:

- Mount state comes from `findmnt`, which reads `/proc/self/mountinfo`. Never
  `mountpoint`, which `stat()`s the path and hangs.
- Free space comes from a single `timeout 2 df` covering **all** targets at once,
  not one call per share — otherwise the worst case grew by 2s for every share
  added, and adding shares is the point of the widget.
- A `df` timeout degrades `free` to `—`. It must never flip `mounted` to false;
  those two signals are deliberately decoupled, and there is a test that shims
  `df` with a 30-second hang to prove it.
- While the panel is closed the widget polls only `findmnt`, so a live bar count
  costs zero network traffic.

**The privileged surface is as small as it can be.** `omarchy-nas-mountctl` does
`mkdir`, `mount` and `umount` and nothing else. It accepts share *names*, never
paths — source and target are constructed from pinned constants. Names must match
`^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$`, every name in a list
is validated before any is acted on, and the three config values are pinned to
literals after sourcing the shared library so an inherited environment cannot
redirect a root mount (pkexec scrubs the environment; `sudo -E` does not).

Target directories are prepared with an explicit symlink guard. `mkdir -p`
*follows* symlinks, so a symlinked mount point would let a root mount land
outside the export base entirely — the code tests `-L` before any `-e`/`-d`,
because those two `stat()` straight through a link.

**Unmounting over a VPN asks first.** When the NAS is reached through a tunnel, a
busy NFS unmount hangs rather than fails, so that path is gated behind a
confirmation and uses a lazy unmount.

## Layout

    lib/nas-common.sh          name validation + path derivation (shared)
    bin/omarchy-nas-status     unprivileged state reader -> JSON
    bin/omarchy-nas-mountctl   the entire root surface
    polkit/                    the polkit action
    manifest.json              plugin metadata
    BarWidget.qml              bar icon + panel
    NasService.qml             polls the status helper
    MountController.qml        dispatches mount/unmount/add
    tests/                     shell test suites
    docs/design.md             why it is built this way

## Tests

    bash tests/test-nas-common.sh
    bash tests/test-nas-status.sh
    bash tests/test-nas-mountctl.sh

`install.sh` refuses to install if the mountctl suite fails — that suite is what
proves the root helper rejects malformed names, and it should not be granted a
polkit action while red.

## License

MIT
