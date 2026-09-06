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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: nas.totalCount > 0 ? "󰋊 " + nas.mountedCount + "/" + nas.totalCount : "󰋊"
    foreground: nas.totalCount > 0 && nas.mountedCount < nas.totalCount ? Color.urgent : root.foreground
    useActiveColor: false
    slotSize: Style.bar.statusSlot
    fontSize: Style.bar.iconFont
    tooltipText: "NAS"
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
