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
  readonly property string source: fromUrl(Qt.resolvedUrl("chromebook-sleep.desktop"))
  readonly property string icon: fromUrl(Qt.resolvedUrl("icon.png"))
  readonly property string dest: Quickshell.env("HOME") + "/.local/share/applications/chromebook-sleep.desktop"
  readonly property string marker: "^X-ChromebookSleep-Managed=true$"

  readonly property string installScript:
      '[ -f "$1" ] || exit 0\n'
    + 'if [ -e "$2" ] && ! grep -q "$3" "$2"; then exit 0; fi\n'
    + 'mkdir -p "${2%/*}" || exit 0\n'
    + 'tmp=$2.chromebook-sleep.new\n'
    + 'sed "s|@ICON@|$4|" "$1" > "$tmp" || exit 0\n'
    + 'if cmp -s "$tmp" "$2"; then rm -f "$tmp"; else mv -f "$tmp" "$2"; fi\n'

  readonly property string removeScript:
    'grep -q "$2" "$1" 2>/dev/null && rm -f "$1"\n'

  function fromUrl(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

  Component.onCompleted: {
    Quickshell.execDetached(["sh", "-c", installScript, "sh", source, dest, marker, icon])
  }

  Component.onDestruction: {
    Quickshell.execDetached(["sh", "-c", removeScript, "sh", dest, marker])
  }
}
