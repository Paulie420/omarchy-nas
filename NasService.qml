import QtQuick
import Quickshell.Io

// All system knowledge arrives as one JSON blob from omarchy-nas-status. The
// panel never shells out to anything else, so every hang-guard (timeouts,
// unreachable-host handling) lives in that script, not here.
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
    // Repo path for now: bin/omarchy-nas-status is not yet installed to
    // /usr/local (that's Task 4, run by a human). Switch this to
    // /usr/local/bin/omarchy-nas-status once Task 4 lands.
    command: ["/home/paulie420/.config/omarchy/plugins/paulie420.nas/bin/omarchy-nas-status"]
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
          // Keep the last good model on screen rather than blanking the
          // panel: a transient parse failure should not wipe out the last
          // known-good share list.
          svc.lastError = "status unreadable"
        }
      }
    }
  }
}
