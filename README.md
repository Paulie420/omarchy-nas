# paulie420.nas

A NAS bar widget for the [Omarchy](https://omarchy.org) Quattro shell. Shows which
NFS shares are mounted, mounts and unmounts them without opening a terminal, and
lets you add new shares by picking them off the NAS instead of typing paths.

Built for a NFS export layout where every share lives under one export base
(`/mnt/SpeakerOffice/<name>` by default) and mounts to `/mnt/<name>`.

## Requirements

- **Omarchy Quattro** (the Quickshell-based shell). This is a `bar-widget`
  plugin using the `qs.Ui.Panel` contract; it will not load on the pre-Quattro
  waybar shell.
- `nfs-utils` (`showmount`, `mount.nfs4`), `jq`, `findmnt` (util-linux), and a
  running polkit agent — Omarchy ships `omarchy.polkit`.
- A fingerprint reader is optional. If `pam_fprintd` is `sufficient` in
  `/etc/pam.d/polkit-1`, the auth prompt takes a finger; otherwise it takes a
  password. Nothing here needs configuring either way.

## What it looks like

    ┌─ NAS ──────────────── via LAN ─┐
    │ ● Backup4TB  4.0T / 4.5T  [⏏]  │
    │ ● Backup6TB  5.1T / 5.5T  [⏏]  │
    │ ○ newBackupXTB      —     [↑]  │
    │── Available on NAS ────────────│
    │ + TimeMachine                  │
    │ + extra                        │
    │────────────────────────────────│
    │ [ Mount all ]  [ Open /mnt ]   │
    │ [ Unmount all ]                │
    └────────────────────────────────┘

The bar icon is a single glyph, coloured by state:

| Colour | Meaning |
|---|---|
| grey  | NAS not reachable — mounting is not even possible |
| red   | reachable, but **nothing** mounted |
| amber | reachable, **some** mounted |
| green | reachable, **all** mounted |

Grey rather than red for unreachable: being away from home is normal, whereas
"the NAS is right there and nothing is mounted" is the actionable state.

## Install

    git clone https://github.com/Paulie420/omarchy-nas.git ~/.config/omarchy/plugins/paulie420.nas
    cd ~/.config/omarchy/plugins/paulie420.nas
    sudo ./install.sh
    omarchy plugin enable paulie420.nas right

`install.sh` puts these on the system, registers a polkit action, and enables
a systemd service:

| Path | Purpose |
|---|---|
| `/usr/local/lib/omarchy-nas/nas-common.sh` | shared path derivation |
| `/usr/local/bin/omarchy-nas-status` | unprivileged; prints state as JSON |
| `/usr/local/bin/omarchy-nas-mountctl` | root via pkexec; mounts only |
| `/usr/local/bin/omarchy-nas-shutdown-unmount` | root via systemd; umounts only |
| `/usr/share/polkit-1/actions/org.omarchy.nas.policy` | the auth action |
| `/etc/systemd/system/nas-unmount.service` | runs the shutdown-unmount helper |

Remove it all with `sudo ./install.sh --uninstall` (this does **not** unmount
anything right now — it only removes the automatic unmount-at-shutdown).

## Unmounting cleanly at shutdown

NFS/CIFS mounts can hang a shutdown or reboot for a minute or more if the
server has already gone away — the kernel's generic filesystem-unmount pass
waits on it. `nas-unmount.service` fixes this by force-unmounting every
mounted NFS/CIFS share (`umount -l`, via `omarchy-nas-shutdown-unmount`)
*before* that generic pass runs, using the standard "run something on
shutdown" systemd idiom: a unit that's active from boot and declares
`Conflicts=`/`Before=shutdown.target`, so stopping it — which runs its
`ExecStop` — is forced as part of *reaching* `shutdown.target`.

`shutdown.target` is the one synchronization point `poweroff.target`,
`reboot.target`, `halt.target`, and `kexec.target` all pull in, so this fires
the same way for `systemctl poweroff`/`reboot`, the GUI shutdown menu, and
`shutdown` — including `sudo shutdown now`, which on a systemd machine is
itself a systemd shutdown request, not a separate code path. No fstab entries
or specific share names are involved: it force-unmounts *whatever* is mounted
with type `nfs`, `nfs4`, `cifs`, or `smb3` at the time, so it needs no
maintenance as shares are added or removed. Installed and enabled
automatically by `install.sh`; see its closing output for how to test it
without actually shutting down.

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

## Two plugins, one machine

Pairs with [omarchy-vpn](https://github.com/Paulie420/omarchy-vpn) when the
shares live behind a tunnel. The interaction is deliberate and worth knowing if
you fork this: `pivpn-disconnect.sh` detaches dead mounts **in the background**.
Running that inline held the VPN widget on "Working…" until the NAS prompt was
answered, and the tunnel could not be reconnected until it finished. A network
operation must not block on an interactive filesystem operation.

## Design notes

**Nothing on the paint path can hang.** NFS calls block for the full timeout when
a server disappears, which would take the whole status bar down with it. So:

- Mount state comes from `findmnt`, which reads `/proc/self/mountinfo`. Never
  `mountpoint`, which `stat()`s the path and hangs.
- Used and total come from a single `timeout 2 df` covering **all** targets at
  once (`--output=target,size,used,avail`, so the extra columns are free),
  not one call per share — otherwise the worst case grew by 2s for every share
  added, and adding shares is the point of the widget.
- A `df` timeout degrades `free` to `—`. It must never flip `mounted` to false;
  those two signals are deliberately decoupled, and there is a test that shims
  `df` with a 30-second hang to prove it.
- With the panel closed the widget runs `omarchy-nas-status --probe` on a 10s
  timer: `findmnt` plus the single TCP SYN of the reachability test, ~80ms. No
  `df`, no `showmount`. The full status query — the part that actually talks to
  the NAS — runs only at startup and while the panel is open.

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

    lib/nas-common.sh                  name validation + path derivation (shared)
    bin/omarchy-nas-status             unprivileged state reader -> JSON
    bin/omarchy-nas-mountctl           the entire root mount/unmount surface
    bin/omarchy-nas-shutdown-unmount   root; force-umounts at shutdown
    polkit/                            the polkit action
    systemd/nas-unmount.service        runs the above during shutdown
    manifest.json                      plugin metadata
    BarWidget.qml                      bar icon + panel
    NasService.qml                     polls the status helper
    MountController.qml                dispatches mount/unmount/add
    tests/                             shell test suites
    docs/design.md                     why it is built this way

## Tests

    bash tests/test-nas-common.sh
    bash tests/test-nas-status.sh
    bash tests/test-nas-mountctl.sh
    bash tests/test-nas-shutdown-unmount.sh

`install.sh` refuses to install if the mountctl or shutdown-unmount suites
fail — those are what prove the root helpers behave (reject malformed names;
only ever issue `umount -l` against findmnt's own list), and neither should be
granted root while red.

## Who made this

I'm paulie420. I run a homelab, a BBS, and [techheart.life](https://techheart.life),
and I put the builds and the debugging up on YouTube at
**[@techheart6090](https://youtube.com/@techheart6090)**.

## License

MIT
