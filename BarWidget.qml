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
  // qs.Commons has Color.urgent but no "ok"/green role, so name one here.
  readonly property color okColor: "#6fcf82"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  NasService { id: nas }
  MountController {
    id: ctl
    onFinished: function (ok, message) { nas.lastError = ok ? "" : message; nas.refresh() }
  }

  // No background polling. The cheap findmnt probe that used to run while the
  // panel was closed existed solely to feed the bar count, and the count is
  // gone -- so a closed panel now does literally nothing.

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Glyph only. A "3/4" suffix made this slot far wider than every other
    // bar icon and threw the row's spacing out; the count belongs in the panel,
    // which is one click away.
    text: "󰋊"
    // Dimmed when the homelab is unreachable. This reflects the LAST completed
    // status poll (startup, and whenever the panel is open) -- there is no
    // background polling any more, so it can lag until the panel is opened.
    foreground: nas.reachable ? root.foreground : Qt.darker(root.foreground, 1.9)
    useActiveColor: false
    slotSize: Style.bar.statusSlot
    fontSize: Style.bar.iconFont
    tooltipText: "NAS"
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  readonly property color staleColor: "#e0a75e"

  // Mounted shares whose server has gone away: mounted, but any read blocks.
  function staleNames() {
    var out = []
    for (var i = 0; i < nas.shares.length; i++)
      if (nas.shares[i].stale) out.push(nas.shares[i].name)
    return out
  }

  function mountedNames() {
    var out = []
    for (var i = 0; i < nas.shares.length; i++)
      if (nas.shares[i].mounted) out.push(nas.shares[i].name)
    return out
  }

  // Only unmounting over the tunnel needs a second press. On the LAN an
  // unmount either works or fails fast, so a confirm there is pure friction.
  readonly property bool needsConfirm: nas.transport === "pivpn"

  // "" = nothing armed, "*" = the bulk action, otherwise a share name.
  property string armed: ""

  function arm(what) { root.armed = what; disarmTimer.restart() }

  // Names of currently-unmounted shares, for "Mount all".
  function unmountedNames() {
    var out = []
    for (var i = 0; i < nas.shares.length; i++) if (!nas.shares[i].mounted) out.push(nas.shares[i].name)
    return out
  }

  // An armed button disarms itself, so a half-pressed confirm never lingers
  // into the next time the panel is opened.
  property Timer disarmTimer: Timer {
    interval: 4000
    onTriggered: root.armed = ""
  }

  // Closing the panel always disarms -- reopening should start from a clean
  // state rather than one press away from unmounting something.
  onOpenedChanged: if (!root.opened) root.armed = ""

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
        // Named, because children of a Flickable are reparented into its
        // contentItem: `parent.width` inside the Column would resolve to
        // contentItem.width, which is driven by contentWidth, which is driven
        // by width -- a circular binding that collapses the panel to zero.
        // paulie420.vpn references `flick.width` for exactly this reason.
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: flick.width
          spacing: Style.space(8)

          // Connectivity lamp. These shares are only reachable at home or with
          // PiVPN up, so "can I see the homelab right now" is the first thing
          // worth knowing when the panel opens -- before any row is read.
          Row {
            width: flick.width
            spacing: Style.space(6)

            Rectangle {
              width: Style.space(9); height: width; radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: nas.reachable ? root.okColor : Color.urgent
            }

            Text {
              text: nas.transport === "lan" ? "NAS — via LAN"
                  : nas.transport === "pivpn" ? "NAS — via PiVPN"
                  : "NAS — homelab not reachable"
              color: nas.reachable ? root.foreground : Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Only shown when disconnected: says what to actually do about it.
          Text {
            visible: !nas.reachable
            width: flick.width
            wrapMode: Text.WordWrap
            text: nas.pivpn.up && !nas.pivpn.handshake
                ? "PiVPN interface is up but the peer has not answered — no handshake."
                : "Connect to your home network, or bring PiVPN up, to mount these shares."
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: nas.shares
            delegate: Row {
              width: column.width
              spacing: Style.space(8)
              Text {
                // Amber for stale: still in the mount table, but the server is
                // unreachable, so touching this path blocks. Visually distinct
                // from both healthy (normal) and simply-absent (hollow).
                text: modelData.mounted ? "●" : "○"
                color: modelData.stale ? root.staleColor : root.foreground
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
                // Unmounting over the tunnel is the one destructive-ish action
                // (a busy NFS umount over PiVPN hangs rather than fails), so it
                // arms first and acts on the second press. Done INLINE rather
                // than with Ui/ConfirmDialog: that component fills its parent,
                // and a bar widget's parent is the tiny bar slot, so it renders
                // at icon size with hit-testing to match. Confirming in the row
                // also keeps the pointer where it already is.
                text: root.armed === modelData.name ? "Confirm?"
                    : modelData.stale ? "Force unmount"
                    : (modelData.mounted ? "Unmount" : "Mount")
                enabled: !ctl.busy
                fontFamily: root.fontFamily
                foreground: root.armed === modelData.name ? Color.urgent
                          : modelData.stale ? root.staleColor : root.foreground
                onClicked: {
                  if (modelData.stale) { ctl.forceUmount([modelData.name]); return }
                  if (!modelData.mounted) { ctl.mount([modelData.name]); return }
                  if (root.needsConfirm) {
                    if (root.armed === modelData.name) { root.armed = ""; ctl.umount([modelData.name]) }
                    else root.arm(modelData.name)
                  } else ctl.umount([modelData.name])
                }
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

          // Shown only while a polkit prompt is outstanding. Without it a click
          // looks like it did nothing while the dialog waits for an answer.
          Text {
            visible: ctl.busy
            width: flick.width
            text: "Waiting for authentication…"
            color: Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(8)
            Button {
              text: "Mount all"
              enabled: !ctl.busy && root.unmountedNames().length > 0
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: ctl.mount(root.unmountedNames())
            }
            Button {
              // One call for every share, so the whole batch costs a single
              // authentication rather than one prompt per share.
              text: root.armed === "*" ? "Confirm — unmount all?"
                  : root.staleNames().length > 0 ? "Force unmount all" : "Unmount all"
              enabled: !ctl.busy && root.mountedNames().length > 0
              fontFamily: root.fontFamily
              foreground: root.armed === "*" ? Color.urgent
                        : root.staleNames().length > 0 ? root.staleColor : root.foreground
              onClicked: {
                if (root.staleNames().length > 0) { ctl.forceUmount(root.mountedNames()); return }
                if (root.needsConfirm) {
                  if (root.armed === "*") { root.armed = ""; ctl.umount(root.mountedNames()) }
                  else root.arm("*")
                } else ctl.umount(root.mountedNames())
              }
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


}
