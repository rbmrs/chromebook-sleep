import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Settings panel for chromebook-sleep. It reads and writes only through the
// `chromebook-sleep` CLI; the config file is never touched directly, so the CLI
// stays the single place that validates values.
//
// Shell contract: `opened`, open(payloadJson), close(). Summon with
//   omarchy-shell shell toggle io.github.rbmrs.chromebook-sleep
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.rbmrs.chromebook-sleep"
  // From this file's own URL: third-party plugins don't get __sourceDir.
  readonly property string setupScript: decodeURIComponent(String(Qt.resolvedUrl("system/setup.sh")).replace(/^file:\/\//, ""))

  readonly property var presets: [
    { value: "4h", label: "4h" },
    { value: "12h", label: "12h" },
    { value: "1d", label: "1 day" },
    { value: "3d", label: "3 days" },
    { value: "custom", label: "Custom" }
  ]
  readonly property var units: [
    { value: "m", label: "minutes" },
    { value: "h", label: "hours" },
    { value: "d", label: "days" }
  ]
  // Mirrors the CLI's 2m..28d range so the spin box can't offer values it rejects.
  readonly property var unitRange: ({ m: [2, 40320], h: [1, 672], d: [1, 28] })

  property bool opened: false
  property var status: null
  property bool cliMissing: false
  property string errorText: ""

  // The custom editor is shown when the saved value isn't a preset, or after
  // "Custom" is picked until a value is applied.
  property bool customMode: false
  property bool customPicked: false
  property int customNumber: 12
  property string customUnit: "h"

  property var queue: []

  readonly property bool installed: status !== null && status.installed === true
  readonly property bool configValid: status !== null && status.configValid === true
  readonly property bool enabled: status !== null && status.enabled === true
  readonly property string after: status !== null ? String(status.poweroffAfter || "") : ""
  readonly property string durationChoice: customMode ? "custom" : after

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.opened = true
    root.errorText = ""
    root.customMode = false
    root.customPicked = false
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (customTimer.running) { customTimer.stop(); applyCustom() }
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else close()
  }

  // ------------------------------------------------------------- CLI

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(text) {
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) {}
    root.cliMissing = parsed === null
    root.status = parsed
    if (parsed === null) return

    var after = String(parsed.poweroffAfter || "")
    var isPreset = presets.some(function(p) { return p.value === after })
    var m = after.match(/^([0-9]+)([mhd])$/)
    if (m && !customTimer.running) {
      root.customNumber = parseInt(m[1], 10)
      root.customUnit = m[2]
    }
    root.customMode = root.customPicked || (m !== null && !isPreset)
  }

  // Commands run one at a time, in order, then status is re-read.
  function run(args) {
    root.queue = root.queue.concat([args])
    runNext()
  }

  function runNext() {
    if (actionProc.running || root.queue.length === 0) return
    actionProc.command = ["chromebook-sleep"].concat(root.queue[0])
    root.queue = root.queue.slice(1)
    actionProc.running = true
  }

  function setEnabled(on) { run([on ? "enable" : "disable"]) }
  function setOnAc(value) { run(["on-ac", value]) }

  function chooseDuration(value) {
    if (value === "custom") {
      root.customPicked = true
      root.customMode = true
      return
    }
    root.customPicked = false
    root.customMode = false
    customTimer.stop()
    run(["set", value])
  }

  function applyCustom() {
    root.customPicked = false
    run(["set", root.customNumber + root.customUnit])
  }

  function install() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "bash " + shellQuote(root.setupScript)])
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function clamp(n, unit) {
    var r = unitRange[unit]
    return Math.max(r[0], Math.min(r[1], n))
  }

  // ------------------------------------------------------------- text

  function human(after) {
    var m = String(after).match(/^([0-9]+)([mhd])$/)
    if (!m) return after
    var n = parseInt(m[1], 10)
    var word = { m: "minute", h: "hour", d: "day" }[m[2]]
    return n + " " + word + (n === 1 ? "" : "s")
  }

  function summary() {
    if (root.cliMissing) return "The chromebook-sleep command isn't installed yet."
    if (root.status === null) return "Loading…"
    if (!root.configValid) return "The config is invalid, so nothing will happen until it's fixed."
    if (!root.enabled) return "Off. The laptop sleeps as long as it likes."
    var s = "When the laptop has been asleep for " + human(root.after) + ", it wakes up and powers off."
    if (root.status.onAc === "skip" && root.status.onAcNow) s += " It's plugged in now, so it will stay asleep."
    return s
  }

  function lastEventText() {
    var ev = root.status && root.status.lastEvent
    if (!ev) return "No sleep recorded yet."
    var when = new Date(ev.time * 1000)
    return Qt.formatDateTime(when, "ddd d MMM, HH:mm") + ": " + ev.message
  }

  // ------------------------------------------------------------- processes

  Process {
    id: statusProc
    command: ["chromebook-sleep", "status", "--json"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var err = String(actionErr.text || "").trim()
      root.errorText = exitCode === 0 ? "" : (err.replace(/^chromebook-sleep: /, "") || ("chromebook-sleep exited with " + exitCode))
      if (root.queue.length > 0) root.runNext()
      else root.refresh()
    }
  }

  Timer {
    id: customTimer
    interval: 600
    onTriggered: root.applyCustom()
  }

  // Picks up an install finishing in the terminal, or edits made from the CLI.
  Timer {
    interval: 4000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------- UI

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

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(560), window.width - Style.gapsOut * 4)
      height: content.implicitHeight + Style.spacing.panelPadding * 2
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

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
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.spacing.panelPadding }
        spacing: Style.spacing.panelGap

        // Header: title + master switch
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xs
            Text {
              text: "Chromebook Sleep"
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              Layout.fillWidth: true
              text: "Power off after sleeping too long, like ChromeOS."
              color: Qt.darker(Color.menu.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          ToggleSwitch {
            visible: !root.cliMissing
            checked: root.enabled
            busy: actionProc.running
            interactive: root.configValid
            onToggled: root.setEnabled(!root.enabled)
          }
        }

        // Install banner
        BorderSurface {
          Layout.fillWidth: true
          visible: root.cliMissing || (root.status !== null && !root.installed)
          implicitHeight: installRow.implicitHeight + Style.spacing.xl * 2
          radius: Style.cornerRadius
          color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
          borderSpec: Border.surfaceSpec("menu", "border", Color.urgent, 1)

          RowLayout {
            id: installRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Style.spacing.xl }
            spacing: Style.spacing.controlGap
            Text {
              Layout.fillWidth: true
              text: "The system hook isn't installed, so nothing happens during sleep. Installing needs your sudo password."
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
            Button {
              text: "Install"
              bordered: true
              onClicked: root.install()
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: Color.menu.text }

        // Settings; dimmed while off, but still editable.
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.panelGap
          enabled: !root.cliMissing && root.status !== null
          opacity: root.enabled ? 1 : 0.55

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            PanelSectionHeader { text: "Power off after"; foreground: Color.menu.text }
            ButtonGroup {
              Layout.fillWidth: true
              options: root.presets
              value: root.durationChoice
              foreground: Color.menu.text
              onChanged: function(value) { root.chooseDuration(value) }
            }
            RowLayout {
              visible: root.customMode
              spacing: Style.spacing.controlGap
              NumberField {
                value: root.customNumber
                from: root.unitRange[root.customUnit][0]
                to: root.unitRange[root.customUnit][1]
                foreground: Color.menu.text
                onModified: function(value) {
                  root.customNumber = value
                  customTimer.restart()
                }
              }
              ButtonGroup {
                options: root.units
                value: root.customUnit
                foreground: Color.menu.text
                onChanged: function(value) {
                  root.customUnit = value
                  root.customNumber = root.clamp(root.customNumber, value)
                  customTimer.restart()
                }
              }
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            PanelSectionHeader { text: "When plugged in"; foreground: Color.menu.text }
            ButtonGroup {
              Layout.fillWidth: true
              options: [
                { value: "skip", label: "Stay asleep", tooltip: "Never power off while charging (ChromeOS behaviour)" },
                { value: "poweroff", label: "Power off too", tooltip: "Treat charging like running on battery" }
              ]
              value: root.status ? String(root.status.onAc || "") : ""
              foreground: Color.menu.text
              onChanged: function(value) { root.setOnAc(value) }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: Color.menu.text }

        // Status
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          Text {
            Layout.fillWidth: true
            text: root.summary()
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }
          Text {
            Layout.fillWidth: true
            visible: root.status !== null
            text: "Last event: " + root.lastEventText()
            color: Qt.darker(Color.menu.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
          Repeater {
            model: root.status && !root.configValid ? root.status.configErrors : []
            delegate: Text {
              required property var modelData
              Layout.fillWidth: true
              text: "• " + modelData
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }
          Text {
            Layout.fillWidth: true
            visible: root.status !== null && root.status.rtcWakeup !== "enabled"
            text: "The RTC can't wake this machine (wakeup: " + (root.status ? root.status.rtcWakeup : "") + "), so it can't power itself off."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
          Text {
            Layout.fillWidth: true
            visible: root.errorText !== ""
            text: root.errorText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }
}
