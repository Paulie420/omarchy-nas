# paulie420.nas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Quickshell bar widget that shows SpeakerOffice NFS mount state and mounts/unmounts/adds shares without opening a terminal.

**Architecture:** Two shell scripts carry all system logic — `omarchy-nas-status` (unprivileged, emits JSON) and `omarchy-nas-mountctl` (root via `pkexec`, mount/umount only). QML does one `Process` + one `JSON.parse` and never shells out to anything else. Both scripts source one shared function file so path derivation cannot drift.

**Tech Stack:** bash, jq, QML (Quickshell), polkit, NFSv4

**Spec:** `~/.config/omarchy/plugins/paulie420.nas/docs/design.md`

## Global Constraints

- NAS host `10.0.0.118`, export base `/mnt/SpeakerOffice`, mount root `/mnt`.
- Never use `mountpoint` or bare `df` on the paint path — they `stat()` and hang for the full NFS timeout. Use `findmnt` (reads `/proc/self/mountinfo`) and `timeout 2 df`.
- Share names must match `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$`. Reject everything else before use.
- `omarchy-nas-mountctl` constructs source and target; it never accepts a path from the caller.
- Local target for name `a/b` is `/mnt/a-b`. Both scripts derive this via the shared `nas_target()` function — never reimplemented.
- QML `Process.command` is an **array** (no shell interpolation).
- Plugin settings are read-only. Added shares persist to `~/.config/omarchy/state/nas-shares.json`.
- The share `extra` is RESERVED as the end-to-end add test. Do not add it before Task 7.
- Plugin dir: `~/.config/omarchy/plugins/paulie420.nas/`. Commit after every task.

---

### Task 1: Shared path derivation + validation

**Files:**
- Create: `lib/nas-common.sh`
- Test: `tests/test-nas-common.sh`

**Interfaces:**
- Produces: `nas_valid_name(name)` → exit 0/1; `nas_target(name)` → prints `/mnt/<flattened>`; `nas_source(name)` → prints `10.0.0.118:/mnt/SpeakerOffice/<name>`

- [ ] **Step 1: Write the failing test**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-nas-common.sh`
Expected: FAIL — `lib/nas-common.sh` does not exist

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# lib/nas-common.sh — shared by omarchy-nas-status and omarchy-nas-mountctl.
# Sourced, never executed. Both scripts MUST derive paths through here: if
# status and mountctl disagreed on a target, a nested share would mount at one
# path and be checked at another and read as permanently unmounted.

NAS_HOST="${NAS_HOST:-10.0.0.118}"
NAS_EXPORT_BASE="${NAS_EXPORT_BASE:-/mnt/SpeakerOffice}"
NAS_MOUNT_ROOT="${NAS_MOUNT_ROOT:-/mnt}"

# One optional slash for nested exports (Backup4TB/ISOs). No "..", no absolute
# paths, no whitespace, no shell metacharacters. Anchored at both ends.
nas_valid_name() {
  [[ $# -eq 1 ]] || return 1
  [[ $1 =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]] || return 1
  # ".." is spelled with legal characters, so exclude it explicitly.
  local part
  for part in ${1//\// }; do
    [[ $part == ".." || $part == "." ]] && return 1
  done
  return 0
}

# Flatten the one legal slash so two exports cannot collide on basename.
nas_target() { printf '%s/%s\n' "$NAS_MOUNT_ROOT" "${1//\//-}"; }
nas_source() { printf '%s:%s/%s\n' "$NAS_HOST" "$NAS_EXPORT_BASE" "$1"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-nas-common.sh`
Expected: every line `ok`, exit 0

- [ ] **Step 5: Commit**

```bash
git add lib/nas-common.sh tests/test-nas-common.sh
git commit -m "feat: shared NAS path derivation and name validation"
```

---

### Task 2: omarchy-nas-status (unprivileged JSON)

**Files:**
- Create: `bin/omarchy-nas-status`
- Test: `tests/test-nas-status.sh`

**Interfaces:**
- Consumes: `nas_valid_name`, `nas_target`, `nas_source` from Task 1
- Produces: JSON on stdout with keys `reachable` (bool), `transport` ("lan"|"pivpn"|"none"), `pivpn` ({up,handshake}), `shares` (array of {name,target,mounted,free}), `available` (array of names)

- [ ] **Step 1: Write the failing test**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-nas-status.sh`
Expected: FAIL — `bin/omarchy-nas-status` does not exist

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# omarchy-nas-status — everything the NAS panel displays, as one JSON blob.
# Unprivileged. Every NFS-touching call is bounded; the bar must never block.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/nas-common.sh"

STATE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/state/nas-shares.json"

# Source of truth for "my shares": the state file. Seeded on first run from
# whatever is mounted, so an existing setup adopts itself.
if [[ -r $STATE ]]; then
  mapfile -t SHARES < <(jq -r '.[]' "$STATE" 2>/dev/null)
else
  mapfile -t SHARES < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null |
    awk -v b="$NAS_EXPORT_BASE/" '$2 ~ b {sub(".*"b,"",$2); print $2}' | sort -u)
fi

# findmnt reads /proc/self/mountinfo — no stat(), so a dead server cannot hang.
is_mounted() { findmnt -rn "$1" >/dev/null 2>&1; }

# df DOES stat(). Bound it and degrade to null rather than freeze the panel.
free_of() {
  local out
  out=$(timeout 2 df -h --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' ')
  [[ -n $out ]] && printf '%s' "$out" || printf 'null_marker'
}

nc -z -w1 "$NAS_HOST" 2049 >/dev/null 2>&1 && reachable=true || reachable=false

pv_up=false; pv_hs=false
if [[ -d /sys/class/net/pivpn ]]; then
  pv_up=true
  [[ $(cat /sys/class/net/pivpn/statistics/rx_bytes 2>/dev/null || echo 0) -gt 0 ]] && pv_hs=true
fi

# The route names the real egress interface. "Reachable without the tunnel" is
# not testable while the tunnel is up, so the route is the authority.
transport=none
if [[ $reachable == true ]]; then
  if ip route get "$NAS_HOST" 2>/dev/null | grep -qw pivpn; then transport=pivpn; else transport=lan; fi
fi

shares_json='[]'
for n in "${SHARES[@]}"; do
  [[ -n $n ]] || continue
  nas_valid_name "$n" || continue
  t=$(nas_target "$n")
  m=false; f=null_marker
  if is_mounted "$t"; then m=true; f=$(free_of "$t"); fi
  shares_json=$(jq -c --arg n "$n" --arg t "$t" --argjson m "$m" --arg f "$f" \
    '. += [{name:$n,target:$t,mounted:$m,free:(if $f=="null_marker" then null else $f end)}]' <<<"$shares_json")
done

# showmount can stall when the NAS is gone; an empty list collapses the
# "Available" section quietly rather than raising an error.
avail_json='[]'
if [[ $reachable == true ]]; then
  avail_json=$(timeout 6 showmount -e "$NAS_HOST" 2>/dev/null |
    awk -v b="$NAS_EXPORT_BASE/" '$1 ~ "^"b {sub("^"b,"",$1); print $1}' |
    jq -R . | jq -sc "map(select(. as \$x | $(jq -c . <<<"$shares_json") | map(.name) | index(\$x) | not))") || avail_json='[]'
  [[ -z $avail_json || $avail_json == "null" ]] && avail_json='[]'
fi

jq -nc --argjson reachable "$reachable" --arg transport "$transport" \
  --argjson up "$pv_up" --argjson hs "$pv_hs" \
  --argjson shares "$shares_json" --argjson available "$avail_json" \
  '{reachable:$reachable,transport:$transport,pivpn:{up:$up,handshake:$hs},shares:$shares,available:$available}'
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x bin/omarchy-nas-status && bash tests/test-nas-status.sh`
Expected: every line `ok`. Then eyeball real output: `bin/omarchy-nas-status | jq .` should list the four mounted shares and offer `extra` under `.available`.

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-nas-status tests/test-nas-status.sh
git commit -m "feat: omarchy-nas-status emits panel state as JSON"
```

---

### Task 3: omarchy-nas-mountctl (root helper) — validation before privilege

**Files:**
- Create: `bin/omarchy-nas-mountctl`
- Test: `tests/test-nas-mountctl.sh`

**Interfaces:**
- Consumes: `nas_valid_name`, `nas_target`, `nas_source` from Task 1
- Produces: CLI `omarchy-nas-mountctl mount|umount <name>...`; exit 0 on success, non-zero with one line on stderr otherwise

**This task installs nothing privileged.** Rejection is proven first; installation is Task 4.

- [ ] **Step 1: Write the failing test**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-nas-mountctl.sh`
Expected: FAIL — `bin/omarchy-nas-mountctl` does not exist

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# omarchy-nas-mountctl — the ENTIRE privileged surface of paulie420.nas.
# Runs as root via pkexec. Takes a verb and a list of share NAMES; never a
# path. Source and target are constructed here, so a caller cannot point this
# at anything outside the export base.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/nas-common.sh"

die() { printf '%s\n' "$1" >&2; exit 1; }

verb="${1:-}"; shift || true
[[ $verb == mount || $verb == umount ]] || die "usage: omarchy-nas-mountctl mount|umount <name>..."
[[ $# -ge 1 ]] || die "no shares given"

# Validate EVERY name before acting on ANY, so a bad argument late in the list
# cannot leave the system half-changed.
for n in "$@"; do
  nas_valid_name "$n" || die "illegal share name: $n"
done

rc=0
for n in "$@"; do
  src=$(nas_source "$n"); tgt=$(nas_target "$n")
  if [[ ${NAS_DRYRUN:-0} == 1 ]]; then
    echo "would $verb $src -> $tgt"; continue
  fi
  case $verb in
    mount)
      findmnt -rn "$tgt" >/dev/null 2>&1 && continue      # already mounted
      mkdir -p "$tgt" || { echo "mkdir failed: $tgt" >&2; rc=1; continue; }
      if ! timeout 15 mount -t nfs4 "$src" "$tgt" 2>/dev/null; then
        echo "mount failed: $n" >&2; rc=1
      fi
      ;;
    umount)
      findmnt -rn "$tgt" >/dev/null 2>&1 || continue      # already gone
      # Lazy on fallback: over PiVPN a busy NFS umount hangs rather than fails.
      if ! timeout 10 umount "$tgt" 2>/dev/null && ! umount -l "$tgt" 2>/dev/null; then
        echo "umount failed: $n" >&2; rc=1
      fi
      ;;
  esac
done
exit $rc
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x bin/omarchy-nas-mountctl && bash tests/test-nas-mountctl.sh`
Expected: every line `ok`

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-nas-mountctl tests/test-nas-mountctl.sh
git commit -m "feat: omarchy-nas-mountctl root helper with strict name validation"
```

---

### Task 4: Install helpers + polkit policy

**Files:**
- Create: `polkit/org.omarchy.nas.policy`
- Create: `install.sh`

**Interfaces:**
- Consumes: `bin/omarchy-nas-status`, `bin/omarchy-nas-mountctl`, `lib/nas-common.sh`
- Produces: `/usr/local/lib/omarchy-nas/nas-common.sh`, `/usr/local/bin/omarchy-nas-{status,mountctl}`, polkit action `org.omarchy.nas.manage-mounts`

- [ ] **Step 1: Write the policy and installer**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>paulie420.nas</vendor>
  <action id="org.omarchy.nas.manage-mounts">
    <description>Mount and unmount SpeakerOffice NAS shares</description>
    <message>Authentication is required to change NAS mounts</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <!-- auth_admin_keep: caches for a few minutes so a mount followed by an
           unmount does not ask twice. pam_fprintd is `sufficient` in
           /etc/pam.d/polkit-1, so this prompt takes a fingerprint OR a
           typed password with no extra work. -->
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/omarchy-nas-mountctl</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
```

```bash
#!/usr/bin/env bash
# install.sh — copies helpers to system paths and registers the polkit action.
# Run once: sudo ./install.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

install -d /usr/local/lib/omarchy-nas
install -m 0644 "$here/lib/nas-common.sh" /usr/local/lib/omarchy-nas/nas-common.sh
# Helpers resolve ../lib/nas-common.sh relative to their real path, so /usr/local/bin
# + /usr/local/lib/omarchy-nas keeps that layout intact.
install -d /usr/local/lib/omarchy-nas/../bin
install -m 0755 "$here/bin/omarchy-nas-status"  /usr/local/bin/omarchy-nas-status
install -m 0755 "$here/bin/omarchy-nas-mountctl" /usr/local/bin/omarchy-nas-mountctl
install -m 0644 "$here/polkit/org.omarchy.nas.policy" /usr/share/polkit-1/actions/org.omarchy.nas.policy
echo "installed. verify: pkaction --action-id org.omarchy.nas.manage-mounts"
```

> **Note for the implementer:** the helpers source `../lib/nas-common.sh` relative to
> `readlink -f "$0"`. Installed at `/usr/local/bin/omarchy-nas-status`, that resolves to
> `/usr/local/lib/nas-common.sh`, NOT `/usr/local/lib/omarchy-nas/nas-common.sh`.
> Fix by installing the lib to `/usr/local/lib/nas-common.sh`, or by changing the
> source line to check both paths. Resolve this in Step 2 before proceeding.

- [ ] **Step 2: Fix the lib path, then install and verify**

Make the source line in both helpers tolerant:

```bash
for c in "$(dirname "$(readlink -f "$0")")/../lib/nas-common.sh" \
         /usr/local/lib/omarchy-nas/nas-common.sh; do
  [[ -r $c ]] && { . "$c"; break; }
done
```

Run:
```bash
sudo ./install.sh
pkaction --action-id org.omarchy.nas.manage-mounts
omarchy-nas-status | jq .shares
```
Expected: `pkaction` prints the action; status still emits the four shares.

- [ ] **Step 3: Verify the fingerprint prompt end-to-end**

Run: `pkexec /usr/local/bin/omarchy-nas-mountctl umount Beers4TB`
Expected: a graphical dialog appears; touch the sensor OR type the password; then
`findmnt -rn /mnt/Beers4TB` prints nothing.

Then remount and confirm a single prompt covers a list:
```bash
pkexec /usr/local/bin/omarchy-nas-mountctl mount Beers4TB
findmnt -rn /mnt/Beers4TB
```

- [ ] **Step 4: Commit**

```bash
git add polkit/org.omarchy.nas.policy install.sh bin/
git commit -m "feat: polkit policy and installer for NAS helpers"
```

---

### Task 5: Plugin manifest + minimal bar widget

**Files:**
- Create: `manifest.json`
- Create: `BarWidget.qml`

**Interfaces:**
- Produces: plugin id `paulie420.nas`, `ipcTarget "paulie420.nas"`, reachable via `omarchy-shell shell toggle paulie420.nas`

- [ ] **Step 1: Write the manifest**

```json
{
  "schemaVersion": 1,
  "id": "paulie420.nas",
  "name": "NAS",
  "version": "0.1.0",
  "author": "paulie420",
  "license": "MIT",
  "description": "Mount, unmount and discover SpeakerOffice NFS shares from the Omarchy bar.",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "NAS",
    "description": "NFS mount state with one-touch mount, unmount and share discovery.",
    "category": "Files",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": { "refreshIntervalSec": 10 },
    "schema": [
      { "key": "refreshIntervalSec", "type": "integer", "label": "Refresh interval (seconds)",
        "min": 5, "max": 120, "step": 5, "defaultValue": 10 }
    ]
  }
}
```

- [ ] **Step 2: Validate the manifest**

Run: `omarchy plugin validate ~/.config/omarchy/plugins/paulie420.nas`
Expected: no output (silent success)

- [ ] **Step 3: Write the minimal widget**

```qml
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Rooted in Panel, not BarWidget: Bar.qml:412 only counts a widget as a
// numbered panel when it exposes open()/close()/opened. A BarWidget root is
// silently skipped by SUPER+CTRL+<n>, which is why omamail is not in that range.
Panel {
  id: root
  moduleName: "paulie420.nas"
  ipcTarget: "paulie420.nas"

  // The bar's ModuleSlot sizes itself from the loaded item's implicit size.
  // Panel derives from a plain Item and has none, so without these two lines
  // the slot collapses to 0x0 and the widget is invisible despite loading.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground

  BarIconButton {
    id: button
    text: "󰋊"
    color: root.foreground
    onClicked: root.toggle()
  }
}
```

- [ ] **Step 4: Enable and verify it appears**

Run:
```bash
omarchy plugin enable paulie420.nas right
omarchy plugin list | grep paulie420.nas
```
Expected: listed `enabled third-party bar-widget`, and a disk glyph appears in the bar's right section. Confirm the panel contract works: `omarchy-shell shell toggle paulie420.nas` opens it.

- [ ] **Step 5: Commit**

```bash
git add manifest.json BarWidget.qml
git commit -m "feat: NAS plugin manifest and minimal bar widget"
```

---

### Task 6: NasService — poll status, drive the panel

**Files:**
- Create: `NasService.qml`
- Modify: `BarWidget.qml` (wire service in, add panel body)

**Interfaces:**
- Consumes: `/usr/local/bin/omarchy-nas-status` from Task 2; `Panel.opened` from Task 5
- Produces: `NasService` with properties `reachable` (bool), `transport` (string), `shares` (array), `available` (array), `mountedCount` (int), `totalCount` (int), and `refresh()`

- [ ] **Step 1: Write the service**

```qml
import QtQuick
import Quickshell.Io

// All system knowledge arrives as one JSON blob. The panel never shells out
// to anything else, so every hang-guard lives in omarchy-nas-status.
QtObject {
  id: svc

  property bool   reachable: false
  property string transport: "none"
  property var    shares: []
  property var    available: []
  property bool   busy: false
  property string lastError: ""

  readonly property int totalCount: shares ? shares.length : 0
  readonly property int mountedCount: {
    if (!shares) return 0
    var n = 0
    for (var i = 0; i < shares.length; i++) if (shares[i].mounted) n++
    return n
  }

  function refresh() { if (!proc.running) { svc.busy = true; proc.running = true } }

  property Process proc: Process {
    command: ["/usr/local/bin/omarchy-nas-status"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        svc.busy = false
        try {
          var d = JSON.parse(this.text)
          svc.reachable = !!d.reachable
          svc.transport = d.transport || "none"
          svc.shares    = d.shares || []
          svc.available = d.available || []
          svc.lastError = ""
        } catch (e) {
          // Keep the last good model on screen rather than blanking the panel.
          svc.lastError = "status unreadable"
        }
      }
    }
  }
}
```

- [ ] **Step 2: Wire it into the widget with open-only polling**

Add inside `Panel { ... }` in `BarWidget.qml`:

```qml
  NasService { id: nas }

  // Poll only while the panel is open: a closed panel must generate no NFS
  // traffic at all.
  Timer {
    interval: Math.max(5, root.setting("refreshIntervalSec", 10)) * 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: nas.refresh()
  }
```

and change the button to show the count:

```qml
  BarIconButton {
    id: button
    text: nas.totalCount > 0 ? "󰋊 " + nas.mountedCount + "/" + nas.totalCount : "󰋊"
    color: nas.mountedCount === nas.totalCount ? root.foreground : Color.warning
    onClicked: root.toggle()
  }
```

- [ ] **Step 3: Verify live**

Save the files (plugin code hot-reloads). Open the panel.
Expected: the bar reads `󰋊 4/4`. Run `bin/omarchy-nas-status | jq -c '{transport,n:(.shares|length)}'` and confirm the widget agrees.

- [ ] **Step 4: Prove it cannot hang**

Run: `sudo ip route add blackhole 10.0.0.118` then open the panel.
Expected: panel paints within ~2s, free space shows `—`, no bar freeze.
Then: `sudo ip route del blackhole 10.0.0.118`

- [ ] **Step 5: Commit**

```bash
git add NasService.qml BarWidget.qml
git commit -m "feat: poll NAS status into the panel while open"
```

---

### Task 7: Panel body — rows, actions, and the add-share flow

**Files:**
- Create: `MountController.qml`
- Modify: `BarWidget.qml` (panel content)

**Interfaces:**
- Consumes: `NasService` from Task 6; `/usr/local/bin/omarchy-nas-mountctl` from Task 3
- Produces: `MountController` with `mount(names)`, `umount(names)`, `addShare(name)`; signal `finished(ok, message)`

- [ ] **Step 1: Write the controller**

```qml
import QtQuick
import Quickshell.Io

// Every state change goes through pkexec. command is an ARRAY, so a share
// name can never be interpolated into a shell string.
QtObject {
  id: ctl
  signal finished(bool ok, string message)

  property string stateFile: (Quickshell.env("HOME") || "") + "/.config/omarchy/state/nas-shares.json"

  function mount(names)  { run("mount", names) }
  function umount(names) { run("umount", names) }

  function run(verb, names) {
    if (!names || names.length === 0 || proc.running) return
    proc.command = ["pkexec", "/usr/local/bin/omarchy-nas-mountctl", verb].concat(names)
    proc.running = true
  }

  // Persisting an added share is an unprivileged write to $HOME -- only the
  // mount itself needs pkexec, so the two are deliberately separate steps.
  function addShare(name) {
    addProc.command = ["bash", "-c",
      'f="$1"; n="$2"; mkdir -p "$(dirname "$f")"; ' +
      '[ -r "$f" ] || echo "[]" > "$f"; ' +
      'jq --arg n "$n" \'. + [$n] | unique\' "$f" > "$f.tmp" && mv "$f.tmp" "$f"',
      "bash", stateFile, name]
    addProc.running = true
  }

  property Process proc: Process {
    command: []
    running: false
    stderr: StdioCollector { id: errCollector }
    onExited: function(code) {
      // 126/127 are pkexec's "dismissed / not authorised" -- a cancelled
      // prompt is a normal outcome, not an error worth shouting about.
      if (code === 0) ctl.finished(true, "")
      else if (code === 126 || code === 127) ctl.finished(false, "")
      else ctl.finished(false, errCollector.text || "failed")
    }
  }

  property Process addProc: Process {
    command: []
    running: false
    onExited: function(code) { ctl.finished(code === 0, code === 0 ? "" : "could not save share") }
  }
}
```

- [ ] **Step 2: Build the panel body**

Inside `Panel { ... }`, add:

```qml
  MountController {
    id: ctl
    onFinished: function(ok, message) { nas.lastError = ok ? "" : message; nas.refresh() }
  }

  PanelController {
    ColumnLayout {
      spacing: 6

      PanelSectionHeader {
        text: "NAS"
        // The route, not a guess: "reachable without the tunnel" is untestable
        // while the tunnel is up.
        subtitle: nas.transport === "lan" ? "via LAN"
                : nas.transport === "pivpn" ? "via PiVPN" : "unreachable"
      }

      Repeater {
        model: nas.shares
        delegate: RowLayout {
          spacing: 8
          Text { text: modelData.mounted ? "●" : "○"; color: root.foreground }
          Text { text: modelData.name; color: root.foreground; Layout.fillWidth: true }
          Text { text: modelData.free ? modelData.free : "—"; color: Qt.darker(root.foreground, 1.5) }
          Button {
            text: modelData.mounted ? "Unmount" : "Mount"
            onClicked: modelData.mounted ? confirmOrUmount(modelData.name) : ctl.mount([modelData.name])
          }
        }
      }

      PanelSeparator { visible: nas.available.length > 0 }
      PanelSectionHeader { text: "Available on NAS"; visible: nas.available.length > 0 }

      Repeater {
        model: nas.available
        delegate: RowLayout {
          Text { text: "+ " + modelData; color: root.foreground; Layout.fillWidth: true }
          Button { text: "Add"; onClicked: { ctl.addShare(modelData); ctl.mount([modelData]) } }
        }
      }

      PanelSeparator {}
      RowLayout {
        Button { text: "Mount all"; onClicked: ctl.mount(unmountedNames()) }
        Button { text: "Open /mnt"; onClicked: Quickshell.execDetached(["uwsm-app", "--", "nautilus", "/mnt"]) }
      }

      Text { text: nas.lastError; color: Color.urgent; visible: nas.lastError !== "" }
    }
  }

  function unmountedNames() {
    var out = []
    for (var i = 0; i < nas.shares.length; i++) if (!nas.shares[i].mounted) out.push(nas.shares[i].name)
    return out
  }

  // Over PiVPN a busy NFS umount hangs rather than fails, so make it deliberate.
  function confirmOrUmount(name) {
    if (nas.transport === "pivpn") confirmDialog.ask(name)
    else ctl.umount([name])
  }

  ConfirmDialog {
    id: confirmDialog
    property string pending: ""
    function ask(n) { pending = n; title = "Unmount over PiVPN?";
      message = "The tunnel is carrying this mount. If a transfer is running it will hang rather than fail."; open() }
    onAccepted: ctl.umount([confirmDialog.pending])
  }
```

- [ ] **Step 3: Verify mount / unmount round trip**

Open the panel. Click Unmount on `Beers4TB` → authenticate with the fingerprint.
Expected: row flips to `○` within one refresh; `findmnt -rn /mnt/Beers4TB` is empty.
Click Mount → row returns to `●` with free space.
Click "Mount all" with two shares down → **one** prompt, both mount.

- [ ] **Step 4: The reserved end-to-end test — add `extra`**

`extra` has been held back for exactly this. In the panel's "Available on NAS"
section, click **Add** next to `extra`.

Expected, all four:
```bash
findmnt -rn /mnt/extra                                  # mounted, nfs4
jq . ~/.config/omarchy/state/nas-shares.json            # includes "extra"
bin/omarchy-nas-status | jq '.shares[].name'            # includes "extra"
bin/omarchy-nas-status | jq '.available'                # no longer offers "extra"
```
And after `omarchy restart shell`, `extra` is still a normal row — proving persistence.

- [ ] **Step 5: Commit**

```bash
git add MountController.qml BarWidget.qml
git commit -m "feat: NAS panel rows, mount actions and add-share flow"
```

---

### Task 8: README and final verification

**Files:**
- Create: `README.md`
- Create: `.gitignore`

- [ ] **Step 1: Write README and .gitignore**

`.gitignore`: `*.tmp`
`README.md` covers: what it does, `sudo ./install.sh`, `omarchy plugin enable paulie420.nas right`, the settings keys, the state file location, and that mounting authenticates via polkit (fingerprint or password).

- [ ] **Step 2: Full verification sweep**

```bash
bash tests/test-nas-common.sh
bash tests/test-nas-mountctl.sh
bash tests/test-nas-status.sh
omarchy plugin validate ~/.config/omarchy/plugins/paulie420.nas
omarchy plugin list | grep paulie420.nas
hyprctl configerrors
```
Expected: all tests pass, validate silent, plugin enabled, no Hyprland errors.

- [ ] **Step 3: Commit**

```bash
git add README.md .gitignore
git commit -m "docs: README for paulie420.nas"
```

---

## Self-Review

**Spec coverage:** state display → T2/T6; mount/unmount → T3/T4/T7; add-share → T7 (+ state file per the spec's persistence correction); polkit/fingerprint → T4; panel contract → T5; hang-proofing → T2 with an explicit blackhole-route test in T6; PiVPN unmount guard → T7 `ConfirmDialog`; testing plan → T1/T2/T3 plus the reserved `extra` test in T7.

**Known gap deliberately left for the implementer:** Task 4 Step 1 ships an installer whose lib path does not match how the helpers resolve `nas-common.sh`. This is called out in-line and fixed in Step 2 — it is flagged, not hidden, because the two plausible fixes (move the lib, or widen the source lookup) are a judgment call best made against the installed layout.

**Not yet implemented from the spec:** the "Mount all (smart)" PiVPN auto-connect fallback. Task 7's "Mount all" mounts what is reachable; if `transport` is `none` it will fail rather than dial the tunnel. Add as a follow-up task once the core is proven — it needs `pivpn-connect.sh` plus a handshake wait, and is not worth blocking first light on.
