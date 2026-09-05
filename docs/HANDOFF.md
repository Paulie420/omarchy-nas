# paulie420.nas — handoff (paused 2026-09-05)

Paused mid-build to conserve tokens. This file plus `.superpowers/sdd/plan/progress.md`
(the SDD ledger) are the full record. Git history is authoritative.

## Where we are

Branch **`feat/nas-widget`** in `~/.config/omarchy/plugins/paulie420.nas`
(off `master` @ `b79f0b5`). The plugin is NOT yet visible to Omarchy —
`omarchy plugin list` shows nothing, because `manifest.json` does not exist
until Task 5. Nothing is installed system-wide. Nothing privileged has run.
Your live NAS mounts are untouched, and `extra` is still unmounted as reserved.

### Done

| Task | State | Commits |
|---|---|---|
| 1 — `lib/nas-common.sh` (name validation + path derivation) | **complete, review clean** | `71db185..b5ce423` |
| 2 — `bin/omarchy-nas-status` (JSON state) | **fix round 3 of 5 IN FLIGHT** | `cae22e8..954c041` + uncommitted |

Both test suites pass right now:
`bash tests/test-nas-common.sh` and `bash tests/test-nas-status.sh`.

### ⚠️ Uncommitted work in the tree

`bin/omarchy-nas-status` and `tests/test-nas-status.sh` are modified but NOT
committed — a fix-round-3 subagent was still working when we stopped. Tests pass
with these changes present, but I did not verify the round is complete, so I did
not commit it under a "fix:" message that might be a lie.

**First action next session:** `git diff` and decide — commit if round 3 looks
finished, `git checkout --` those two files to fall back to `954c041` if not.
Either is safe; `954c041` is a good state.

## What round 3 was doing

Two items, both small:

- **A.** The "df timeout" test in `tests/test-nas-status.sh` does not test a df
  timeout — it uses an unmounted share, taking the empty-array path so `df` is
  never called. Replace it with a real PATH-shim test (below), and make it SKIP
  honestly (not pass) when nothing is mounted. Also required: proof the new test
  CAN fail, by temporarily reverting `mounted` to depend on `df`.
- **B.** Dead header-skip at `bin/omarchy-nas-status:60`. `tr -s ' '` splits
  `Mounted on` into three fields, so `read -r target avail` gets
  `target="Mounted"` and the comparison never matches; a junk `target_free["Mounted"]`
  entry is inserted each run. Harmless. Fix by matching a leading `/` instead.

The shim test to encode (I ran this by hand; it passed in 3.36s):

```bash
SHIM=$(mktemp -d); printf '#!/bin/sh\nsleep 30\n' > "$SHIM/df"; chmod +x "$SHIM/df"
PATH="$SHIM:$PATH" bin/omarchy-nas-status
# must: return <12s, exit 0, mounted:true for mounted shares, free:null
rm -rf "$SHIM"
```

## What's next, in order

- **Task 3** — `bin/omarchy-nas-mountctl`, the root helper. Brief ready at
  `.superpowers/sdd/plan/task-3-brief.md`. **Carries a controller ruling:** it
  must PIN `NAS_HOST`/`NAS_EXPORT_BASE`/`NAS_MOUNT_ROOT` to literals after
  sourcing the shared lib. `nas-common.sh` takes them as `${VAR:-default}`, and
  this script runs as root — `man pkexec` confirms pkexec scrubs the
  environment, but nothing stops `sudo -E`, where `NAS_MOUNT_ROOT=/etc` would
  aim a root mount at `/etc`. Validation must be proven via `NAS_DRYRUN=1`
  BEFORE anything is installed privileged.
- **Task 4 — STOPS FOR YOU.** Installs the root helper and polkit policy
  (`sudo ./install.sh`), then verifies the fingerprint prompt. Security-sensitive
  and needs a physical touch; no subagent can do it. Also contains a known,
  deliberately-flagged bug: the installer's lib path does not match how the
  helpers resolve `../lib/nas-common.sh` from `/usr/local/bin`. Plan Task 4
  Step 2 fixes it by widening the source lookup.
- **Task 5** — `manifest.json` + minimal `BarWidget.qml`. First point the widget
  becomes visible in your bar.
- **Task 6** — `NasService.qml`, polling while the panel is open.
- **Task 7 — NEEDS YOU** for fingerprint touches, and ends with the reserved
  `extra` add-share end-to-end test.
- **Task 8** — README + final sweep, then the whole-branch review.

## Deferred minors (for the final review to triage)

- No upper bound on share-name length.
- A state file containing a JSON *object* seeds phantom shares via `.[]`;
  should assert `type=="array"` first. Confirmed live: `{"a":"b"}` yields a
  share named `b`.
- Seeding heuristic trusts mount SOURCE without cross-checking that
  `nas_target()` resolves to where it is actually mounted.
- `nas-mount-smart.sh`'s PiVPN auto-dial is NOT in the 8 tasks. "Mount all"
  mounts what is reachable; if transport is `none` it fails rather than dialing
  the tunnel. Follow-up task.

## Rulings made so far (rework these if you disagree)

1. **Branch, not master.** Implemented on `feat/nas-widget`.
2. **Plan QML was wrong in 4 ways** — caught in pre-flight against the real
   `qs.Ui` sources, fixed in `71db185`: `Color.warning` doesn't exist (use
   `Color.urgent`); `Ui/Panel.qml` already owns a `PanelController` so content
   must go in a `KeyboardPanel`; `ConfirmDialog` uses `opened`/`confirmed()`,
   not `title`/`open()`/`onAccepted`; no `QtQuick.Layouts` — house style is
   plain `Column`/`Row`.
3. **Stricter name regex** `^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$`
   — my plan contradicted itself (test said reject `-rf`, regex accepted it).
   Propagated to plan and spec. Cost: a share starting with `-` or `.` cannot be
   added; none exists.
4. **Env-override hardening promoted** from Minor to a hard Task 3 requirement
   (see Task 3 above).
5. **Overrode the process on the fake timeout test** — it was rated
   sub-Important (defer), I opened round 3 anyway, because the untested property
   is the design's core safety guarantee and a test had already slipped a bug
   through once. Cost if wrong: one cheap round.
6. **Tasks 4 and 7 stop for the human** — security-sensitive install and
   physical fingerprint touches.

## Also outstanding (agreed, not started)

Private git repo for `~/.config/omarchy/{bin,extensions}` + `~/.config/hypr`.
Your last full backup is **2026-08-14, pre-Quattro on 3.8.4** — it predates the
`.jsonc` menu port, the cheatgen repair, the scratchpad work and the new
bindings, and we deleted all `.bak` files. The five plugins are safe (all have
GitHub remotes, clean and pushed); the customizations are not.

## To resume

Read `.superpowers/sdd/plan/progress.md` (the ledger) — it holds every ruling
and finding with commit ranges. Then handle the uncommitted diff above, and
continue at Task 3.
