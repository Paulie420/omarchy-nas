# paulie420.nas — NAS bar widget for Omarchy Quattro

Design doc — 2026-09-05

## Purpose

A Quickshell bar widget that shows which SpeakerOffice NFS shares are mounted,
mounts and unmounts them without opening a terminal, and lets new shares be
added by picking them off the NAS rather than typing paths.

Replaces the terminal-only flow of `nas-mount-smart.sh` +
`nas-unmount-all.sh` reached through the Omarchy menu.

## Constraints that shaped the design

1. **A bar panel has no TTY.** `sudo mount` cannot prompt there. Verified:
   `mount` has no NOPASSWD rule in this system's sudoers.
2. **polkit + fingerprint is already wired.** `/etc/pam.d/polkit-1` has
   `auth sufficient pam_fprintd.so` before `auth required pam_unix.so`, a
   Goodix sensor is enrolled, `polkit` is active and `omarchy.polkit` is
   enabled. So a `pkexec` call raises a dialog that takes a fingerprint *or*
   a typed password. Nothing needs building for that.
3. **NFS calls hang.** `mountpoint` and `df` `stat()` the path and block for
   the full NFS timeout when the server is gone. Anything on the paint path
   must read `/proc/self/mountinfo` instead, or carry a `timeout`.
4. **PiVPN carries the mounts.** Dropping the tunnel mid-transfer hangs
   rather than fails, so unmount-over-VPN needs care.
5. **`wg-quick` lies about readiness.** It is `Type=oneshot` and reports
   active once the interface and routes exist, without contacting the peer.
   Only `rx_bytes > 0` proves a real handshake.

## Components

    paulie420.nas/
      manifest.json          id, kinds:["bar-widget"], entry BarWidget.qml
      BarWidget.qml          root qs.Ui.Panel, ipcTarget "paulie420.nas"
      NasService.qml         polls status JSON, exposes model to the panel
      MountController.qml    dispatches mount/unmount/add via pkexec
      docs/design.md         this file

    /usr/local/bin/omarchy-nas-status     unprivileged, emits JSON
    /usr/local/bin/omarchy-nas-mountctl   root via pkexec, mount/umount only
    /usr/share/polkit-1/actions/org.omarchy.nas.policy

### omarchy-nas-status (unprivileged)

Single source of truth for everything the panel displays. One process call,
one `JSON.parse` in QML — no command logic scattered through the UI.

    {
      "reachable":  true,
      "transport":  "lan" | "pivpn" | "none",
      "pivpn":      { "up": true, "handshake": true },
      "shares": [
        { "name":"Backup4TB", "target":"/mnt/Backup4TB",
          "mounted":true, "free":"2.1T" }
      ],
      "available": ["extra", "TimeMachine", "Backup4TB/ISOs"]
    }

Rules:

- `mounted` from `findmnt -rn <target>` (reads `/proc/self/mountinfo`).
  Never `mountpoint`.
- `free` from `timeout 2 df -h`; on timeout the field is `null` and the panel
  renders `—`. A slow NAS must never freeze the bar.
- `reachable` from `nc -z -w1 10.0.0.118 2049` (NFSv4 port), not ping.
- `transport` comes from `ip route get <nasHost>`, which names the actual
  outgoing interface: `pivpn` if the route leaves via the tunnel, `lan`
  otherwise, `none` when unreachable. "Reachable without the tunnel" is not
  testable while the tunnel is up, so the route is the authority.
- `available` from `timeout 6 showmount -e`, minus already-configured shares.
  On failure the key is `[]` and the panel collapses that section quietly.

### omarchy-nas-mountctl (root, via pkexec)

The entire privileged surface. Two verbs, each taking a list so that
"Mount all" costs one authentication rather than one per share.

    omarchy-nas-mountctl mount  <name> [name...]
    omarchy-nas-mountctl umount <name> [name...]

- Each name must match `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$` — one optional
  slash for nested exports such as `Backup4TB/ISOs`. Anything else is
  rejected before use. No `..`, no absolute paths, no shell interpolation of
  caller input.
- Source and target are *constructed*, never accepted:
  `10.0.0.118:/mnt/SpeakerOffice/<name>` → `/mnt/<name>`.
- Nested names flatten with `-` for the local dir (`Backup4TB/ISOs` →
  `/mnt/Backup4TB-ISOs`) so two exports cannot collide on basename.
- **`omarchy-nas-status` MUST derive targets by this same rule**, or a nested
  share would mount at one path and be checked at another and read as
  permanently unmounted. The rule lives in one shell function sourced by both
  scripts; it is not reimplemented per script.
- `mkdir -p` the target, then `mount -t nfs4`.
- `umount` tries plain, then `-l` (lazy) on failure.
- Exit non-zero with a one-line reason on stderr; the panel surfaces it.

### BarWidget.qml

Root `qs.Ui.Panel` with `ipcTarget: "paulie420.nas"`, mirroring
`paulie420.vpn`. This matters: the panel contract (`open()`, `close()`,
`opened`) is what `Bar.qml:412` requires for the widget to be reachable via
`SUPER+CTRL+<n>` and `omarchy-shell shell toggle paulie420.nas`. A widget
rooted in `BarWidget` instead is silently skipped by that numbering.

Bar icon: NAS glyph plus `3/4`. Normal when all mounted, warning tint when
partial, dim when none.

Panel:

    ┌─ NAS ──────────────── via LAN ─┐
    │ ● Backup4TB        2.1T   [⏏]  │
    │ ● Backup6TB         800G  [⏏]  │
    │ ○ newBackupXTB        —   [↑]  │
    │── Available on NAS ────────────│
    │ + TimeMachine                  │
    │ + extra                        │
    │────────────────────────────────│
    │ [ Mount all ]  [ Open /mnt ]   │
    └────────────────────────────────┘

Polling runs on open and every `refreshIntervalSec` (default 10) **only
while the panel is open**, so a closed panel generates no NFS traffic.

## Flows

**Mount all** → `pkexec omarchy-nas-mountctl mount <all unmounted>`. If
`transport` is `none`, first run `pivpn-connect.sh`, wait for
`rx_bytes > 0` (max 20s), then mount. One auth prompt.

**Unmount** → when `transport` is `pivpn`, the row asks for confirmation
first and the helper goes straight to `umount -l`, because dropping NFS over
the tunnel hangs rather than fails.

**Add share** → tick an entry under "Available on NAS" → mount it → on
success append to the plugin's `shares` setting so it persists. `extra` is
the reserved end-to-end test for this flow.

## Settings and persistence

**Correction found during planning:** plugin settings are READ-ONLY. `Panel.qml:39`
exposes `setting(name, fallback)` and values flow one way out of `shell.json`
via `Bar.qml:1790 entrySettings()`. There is no plugin-facing write API, so
"remember the share I just added" cannot live in plugin settings.

Added shares therefore persist to a state file the plugin owns:

    ~/.config/omarchy/state/nas-shares.json     ["Backup4TB", "Backup6TB", ...]

This is an unprivileged write to `$HOME` — adding a share and mounting it are
two separate operations, and only the mount needs `pkexec`. The file is the
source of truth for "my shares"; it is seeded on first run from the
`shares` setting if present, else from whatever is mounted at that moment.

Read-only settings (`shell.json`, optional):

    shares              seed list, used only when the state file is absent
    nasHost             default "10.0.0.118"
    exportBase          default "/mnt/SpeakerOffice"
    mountRoot           default "/mnt"
    refreshIntervalSec  integer 5–120, default 10

## Error handling

| Condition | Behavior |
|---|---|
| NAS unreachable | rows show last known state greyed; "Available" hidden |
| `df` times out | free space renders `—`; row still usable |
| `showmount` fails | "Available" section collapses, no error toast |
| pkexec cancelled | no change, row returns to prior state, no toast |
| mount fails | inline reason on the row from helper stderr |
| PiVPN no handshake | "PiVPN: no handshake" on the transport line |

## Testing

1. `omarchy plugin validate ~/.config/omarchy/plugins/paulie420.nas`
2. Helper argument tests **before** it is ever installed privileged:
   `../etc/shadow`, `/etc/x`, `a;rm -rf /`, `a b`, empty, 3-deep nesting —
   all must be rejected.
3. Panel opened with the NAS deliberately unreachable: must paint within
   ~2s and never block the bar.
4. Mount / unmount round trip on one share, confirming a single fingerprint
   prompt for a multi-share mount.
5. Add-share flow with `extra`, ending mounted at `/mnt/extra` and persisted
   into settings.

## Out of scope for v1

Write access controls, per-share credentials (these exports are
host-allowlisted, not authenticated), automount on boot, and Samba/CIFS.

## Fate of the existing scripts

`nas-mount-smart.sh` and `nas-unmount-all.sh` stay untouched until the widget
is proven. Once it is, the menu rows repoint at the new helpers and the old
scripts are retired in a separate change — not as part of this one.
