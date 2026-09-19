import QtQuick
import Quickshell

// Installs the launcher entry so the panel is reachable from SUPER+SPACE.
// Omarchy has no install hook or manifest field for this, so the service does
// it on load and removes it on unload (disable and remove both unload it).
//
// Only a file carrying the X-ChromebookSleep-Managed marker is written or deleted.
QtObject {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  // From this file's own URL: third-party plugins don't get __sourceDir.
  readonly property string source: decodeURIComponent(String(Qt.resolvedUrl("chromebook-sleep.desktop")).replace(/^file:\/\//, ""))
  readonly property string dest: Quickshell.env("HOME") + "/.local/share/applications/chromebook-sleep.desktop"
  readonly property string marker: "^X-ChromebookSleep-Managed=true$"

  readonly property string installScript:
      '[ -f "$1" ] || exit 0\n'
    + 'if [ -e "$2" ] && ! grep -q "$3" "$2"; then exit 0; fi\n'
    + 'mkdir -p "${2%/*}" || exit 0\n'
    + 'cmp -s "$1" "$2" || cp -f "$1" "$2"\n'

  readonly property string removeScript:
    'grep -q "$2" "$1" 2>/dev/null && rm -f "$1"\n'

  Component.onCompleted: {
    Quickshell.execDetached(["sh", "-c", installScript, "sh", source, dest, marker])
  }

  Component.onDestruction: {
    Quickshell.execDetached(["sh", "-c", removeScript, "sh", dest, marker])
  }
}
