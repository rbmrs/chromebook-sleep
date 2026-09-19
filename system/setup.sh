#!/bin/bash

# Install the chromebook-sleep system parts. Safe to re-run for upgrades; an
# existing config is kept.
#
# Usage: system/setup.sh [--after <duration>]
#   --after  power-off time for a first install, e.g. 12h (otherwise asked)
#
# DESTDIR installs into a staging root without sudo (tests only).

set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
DESTDIR=${DESTDIR:-}

if [[ -z $DESTDIR && $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

after=
while (($#)); do
  case $1 in
    --after) after=${2:-}; shift 2 || { echo "--after needs a value" >&2; exit 2; } ;;
    -h | --help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=common.sh
source "$src/common.sh"

hook=$DESTDIR/usr/lib/systemd/system-sleep/chromebook-sleep
lib=$DESTDIR/usr/local/lib/chromebook-sleep/common.sh
cli=$DESTDIR/usr/local/bin/chromebook-sleep
conf=$DESTDIR/etc/chromebook-sleep.conf

owner=(-o root -g root)
[[ -n $DESTDIR ]] && owner=()

install -D -m 0644 "${owner[@]}" "$src/common.sh" "$lib"
install -D -m 0755 "${owner[@]}" "$src/chromebook-sleep.hook" "$hook"
install -D -m 0755 "${owner[@]}" "$src/chromebook-sleep" "$cli"
echo "Installed hook:  ${hook#"$DESTDIR"}"
echo "Installed CLI:   ${cli#"$DESTDIR"}"

# systemd-sleep only runs hooks from /usr/lib/systemd/system-sleep; an early
# version installed to /etc, where it was never executed.
legacy_hook=$DESTDIR/etc/systemd/system-sleep/chromebook-sleep
if [[ -e $legacy_hook ]]; then
  rm -f "$legacy_hook"
  echo "Removed unused:  ${legacy_hook#"$DESTDIR"}"
fi
# A test override left over from an unfinished `chromebook-sleep test` would make the
# next ordinary suspend power off after a couple of minutes.
rm -f "$DESTDIR/run/chromebook-sleep/test"

if [[ -f $conf ]]; then
  echo "Keeping config:  ${conf#"$DESTDIR"}"
else
  if [[ -z $after ]]; then
    if [[ ! -t 0 ]]; then
      echo "No config yet: pass --after <duration> or run in a terminal." >&2
      exit 1
    fi
    echo
    echo "How long may the laptop sleep before it powers off?"
    echo "Use <number><m|h|d>, between 2m and 28d. Examples: 8h, 12h, 1d, 3d."
    while :; do
      read -r -p "Power off after: " after
      cs_duration_seconds "$after" >/dev/null && break
      echo "  '$after' is not valid, try again."
    done
  fi
  cs_duration_seconds "$after" >/dev/null || { echo "invalid duration '$after'" >&2; exit 1; }

  mkdir -p "$(dirname "$conf")"
  cat >"$conf" <<EOF
# chromebook-sleep: power off after the laptop has been asleep this long.
# Edit with the chromebook-sleep CLI or the Omarchy settings panel.

ENABLED=yes
POWEROFF_AFTER=$after      # <number><m|h|d>, 2m to 28d
ON_AC=skip                 # skip = never power off while plugged in | poweroff
EOF
  echo "Created config:  ${conf#"$DESTDIR"} (power off after $after)"
fi

# Group-writable so the CLI and UI can edit it without sudo; wheel already has sudo.
chmod 0664 "$conf"
[[ -z $DESTDIR ]] && chown root:wheel "$conf"

rtc=$DESTDIR/sys/class/rtc/rtc0
if [[ ! -e $rtc/wakealarm ]]; then
  echo "warning: no RTC wake alarm at $rtc; this machine can't wake itself to power off." >&2
elif [[ $(cat "$rtc/device/power/wakeup" 2>/dev/null) != enabled ]]; then
  echo "warning: rtc0 is not an enabled wakeup source; the alarm may not wake the machine." >&2
fi

echo
if [[ -z $DESTDIR ]]; then
  "$cli" status
fi
