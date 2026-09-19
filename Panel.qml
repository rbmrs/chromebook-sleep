import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Settings panel for chromebook-sleep. It reads and writes only through the
// `chromebook-sleep` CLI; the config file is never touched directly.
//
// Shell contract: `opened`, open(payloadJson), close(). Summon with
//   omarchy-shell shell toggle io.github.rbmrs.chromebook-sleep
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  property bool opened: false
  property var status: null
  property string errorText: ""

  function open(payloadJson) {
    root.opened = true
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.rbmrs.chromebook-sleep")
    else close()
  }

  function refresh() {
    statusProc.running = true
  }

  function applyStatus(text) {
    try {
      root.status = JSON.parse(text)
      root.errorText = ""
    } catch (e) {
      root.status = null
      root.errorText = "The chromebook-sleep CLI is not installed. Run system/setup.sh from the plugin folder."
    }
  }

  Process {
    id: statusProc
    command: ["chromebook-sleep", "status", "--json"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "chromebook-sleep"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(520), window.width - Style.gapsOut * 4)
      height: content.implicitHeight + Style.space(48)
      radius: Style.cornerRadius
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: Math.max(1, Style.space(2))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
        }
      }

      ColumnLayout {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(24) }
        spacing: Style.space(12)

        Text {
          text: "Chromebook Sleep"
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.space(20)
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.space(14)
          text: root.errorText !== "" ? root.errorText
            : root.status === null ? "Loading…"
            : !root.status.configValid ? "Config is invalid, so the hook treats it as disabled."
            : root.status.enabled ? "Powers off after " + root.status.poweroffAfter + " asleep."
            : "Disabled."
        }
      }
    }
  }
}
