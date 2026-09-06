import QtQuick
import Quickshell
import Quickshell.Io

// Every state change goes through pkexec. command is an ARRAY, so a share
// name can never be interpolated into a shell string.
//
// The privileged helper (/usr/local/bin/omarchy-nas-mountctl) is installed by
// a separate, human-run `sudo ./install.sh` step and may not exist yet when
// this panel is used. Its presence is checked for explicitly, inside the
// same bash script that would otherwise exec pkexec, so there is no separate
// async existence probe to race against the real call. A missing helper exits
// 90 -- a code pkexec itself never produces -- so the panel can surface a
// clear "run sudo ./install.sh" message instead of a silent no-op or a
// confusing pkexec "not authorized" (exit 127, which `man pkexec` says is
// also what a missing target program produces -- the two are otherwise
// indistinguishable by exit code alone).
QtObject {
  id: ctl
  signal finished(bool ok, string message)

  readonly property string helperPath: "/usr/local/bin/omarchy-nas-mountctl"
  property string stateFile: (Quickshell.env("HOME") || "") + "/.config/omarchy/state/nas-shares.json"

  // True from the click until the helper exits. The panel shows this, because
  // pkexec raises a full-screen polkit dialog and the click otherwise looks
  // like it did nothing at all while the prompt waits for an answer.
  property bool busy: proc.running || addProc.running

  function mount(names)       { run("mount", names) }
  function umount(names)      { run("umount", names) }
  function forceUmount(names) { run("force-umount", names) }

  function run(verb, names) {
    if (!names || names.length === 0 || proc.running) return
    // $0 is the helper path, $1 is the verb, and shifting once leaves "$@"
    // as exactly the share names -- each still a distinct argv element
    // handed straight to exec, never rejoined into a parsed string.
    // `timeout 150` matters: pkexec blocks until the polkit dialog is answered,
    // and a dialog that is dismissed or ignored would otherwise leave this
    // Process running forever. Because run() returns early while proc.running,
    // ONE wedged authentication silently swallows every later click -- which is
    // exactly what "I clicked Unmount five times and nothing happened" looks
    // like. The timeout guarantees the controller always frees itself.
    proc.command = ["bash", "-c",
      'h="$0"; if [ ! -x "$h" ]; then exit 90; fi; ' +
      'verb="$1"; shift; exec timeout 150 pkexec "$h" "$verb" "$@"',
      ctl.helperPath, verb].concat(names)
    proc.running = true
  }

  // Persisting an added share is an unprivileged write to $HOME -- only the
  // mount itself needs pkexec, so the two are deliberately separate steps.
  function addShare(name) {
    if (addProc.running) return
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
      else if (code === 90) ctl.finished(false, "helper not installed — run sudo ./install.sh")
      // 124 is `timeout` firing: the polkit dialog was never answered.
      else if (code === 124) ctl.finished(false, "authentication timed out")
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
