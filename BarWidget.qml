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
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  NasService { id: nas }
  MountController {
    id: ctl
    onFinished: function (ok, message) { nas.lastError = ok ? "" : message; nas.refresh() }
  }

  // The full status helper touches the network (a reachability probe and,
  // when reachable, showmount) so it only runs while the panel is open, as
  // before. The names/targets it last reported are kept in `knownTargets`
  // below for the cheap closed-panel probe to check against.
  Timer {
    interval: Math.max(5, root.setting("refreshIntervalSec", 10)) * 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: nas.refresh()
  }

  // Share targets last seen from a full poll. Derives straight from
  // nas.shares so it always tracks the latest known set with no extra state
  // to keep in sync.
  readonly property var knownTargets: {
    var t = []
    for (var i = 0; i < nas.shares.length; i++) t.push(nas.shares[i].target)
    return t
  }

  // Mounted count as seen by the cheap, always-on probe below. Used for the
  // icon only while the panel is closed -- while it's open, nas.mountedCount
  // (from the real poll) takes precedence, per the last line of this block.
  property int cheapMountedCount: 0

  // At-a-glance status is the whole point of a bar icon: a closed panel that
  // shows nothing until clicked defeats it. This timer runs unconditionally
  // (not gated on root.opened) but only ever shells out to `findmnt`, which
  // reads /proc/self/mountinfo -- no stat(), no network, never the full
  // status helper. 45s keeps it well inside the brief's 30-60s band.
  Timer {
    interval: 45000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!cheapProc.running) cheapProc.running = true
  }

  Process {
    id: cheapProc
    command: ["findmnt", "-rn", "-o", "TARGET"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var mounted = {}
        var lines = this.text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var l = lines[i].trim()
          if (l) mounted[l] = true
        }
        var kt = root.knownTargets
        var n = 0
        for (var j = 0; j < kt.length; j++) if (mounted[kt[j]]) n++
        root.cheapMountedCount = n
      }
    }
  }

  readonly property int displayMounted: root.opened ? nas.mountedCount : root.cheapMountedCount

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: nas.totalCount > 0 ? "󰋊 " + root.displayMounted + "/" + nas.totalCount : "󰋊"
    foreground: nas.totalCount > 0 && root.displayMounted < nas.totalCount ? Color.urgent : root.foreground
    useActiveColor: false
    slotSize: Style.bar.statusSlot
    fontSize: Style.bar.iconFont
    tooltipText: "NAS"
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  // Names of currently-unmounted shares, for "Mount all".
  function unmountedNames() {
    var out = []
    for (var i = 0; i < nas.shares.length; i++) if (!nas.shares[i].mounted) out.push(nas.shares[i].name)
    return out
  }

  // Over PiVPN a busy NFS umount hangs rather than fails, so make it
  // deliberate: confirm first instead of unmounting straight away.
  function confirmOrUmount(name) {
    if (nas.transport === "pivpn") {
      confirmDialog.pending = name
      confirmDialog.opened = true
    } else {
      ctl.umount([name])
    }
  }

  // KeyboardPanel (extends PopupCard) is the content host. Ui/Panel.qml
  // already owns a PanelController -- do NOT declare another. No
  // QtQuick.Layouts here: the house pattern is plain Column/Row with
  // explicit widths.
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) { if (t === "r" || t === "R") nas.refresh() }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: nas.transport === "lan" ? "NAS — via LAN"
                : nas.transport === "pivpn" ? "NAS — via PiVPN" : "NAS — unreachable"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: nas.shares
            delegate: Row {
              width: column.width
              spacing: Style.space(8)
              Text {
                text: modelData.mounted ? "●" : "○"
                color: root.foreground
                font.family: root.fontFamily
              }
              Text {
                text: modelData.name
                color: root.foreground
                font.family: root.fontFamily
                width: column.width * 0.4
                elide: Text.ElideRight
              }
              Text {
                text: modelData.free ? modelData.free : "—"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                width: column.width * 0.2
              }
              Button {
                text: modelData.mounted ? "Unmount" : "Mount"
                fontFamily: root.fontFamily
                foreground: root.foreground
                onClicked: modelData.mounted ? root.confirmOrUmount(modelData.name) : ctl.mount([modelData.name])
              }
            }
          }

          Text {
            text: "No shares yet"
            visible: nas.shares.length === 0
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "Available on NAS"
            visible: nas.available.length > 0
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: nas.available
            delegate: Row {
              width: column.width
              spacing: Style.space(8)
              Text {
                text: "+ " + modelData
                color: root.foreground
                font.family: root.fontFamily
                width: column.width * 0.7
                elide: Text.ElideRight
              }
              Button {
                text: "Add"
                fontFamily: root.fontFamily
                foreground: root.foreground
                onClicked: { ctl.addShare(modelData); ctl.mount([modelData]) }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Row {
            spacing: Style.space(8)
            Button {
              text: "Mount all"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: ctl.mount(root.unmountedNames())
            }
            Button {
              text: "Open /mnt"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: Quickshell.execDetached(["uwsm-app", "--", "nautilus", "/mnt"])
            }
          }

          Text {
            text: nas.lastError
            color: Color.urgent
            visible: nas.lastError !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Text {
            text: "r  refresh      esc  close"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.7
          }
        }
      }
    }
  }

  // Real ConfirmDialog API: `opened` bool, `message`, confirmed()/canceled().
  // There is no `title`, `open()`, or `onAccepted`.
  ConfirmDialog {
    id: confirmDialog
    property string pending: ""
    message: "The PiVPN tunnel is carrying this mount. If a transfer is running it will hang rather than fail."
    confirmText: "Unmount"
    onConfirmed: { confirmDialog.opened = false; ctl.umount([confirmDialog.pending]) }
    onCanceled: confirmDialog.opened = false
  }
}
