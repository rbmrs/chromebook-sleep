#!/bin/bash

# Remove the chromebook-sleep system parts.
#
# Usage: system/uninstall.sh [--purge | --keep-config]
#   --purge        also delete /etc/chromebook-sleep.conf
#   --keep-config  keep it without asking
#
# DESTDIR removes from a staging root without sudo (tests only).

set -euo pipefail

DESTDIR=${DESTDIR:-}

if [[ -z $DESTDIR && $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

purge=
case ${1:-} in
  --purge) purge=yes ;;
  --keep-config) purge=no ;;
  "") ;;
  -h | --help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

conf=$DESTDIR/etc/chromebook-sleep.conf
run=$DESTDIR/run/chromebook-sleep
rtc=$DESTDIR/sys/class/rtc/rtc0

# Only clear the alarm if the hook armed it; someone else's alarm stays.
if [[ -f $run/state ]]; then
  echo 0 >"$rtc/wakealarm" 2>/dev/null || true
  echo "Cleared the pending RTC alarm."
fi
rm -rf "$run"

for f in \
  "$DESTDIR/etc/systemd/system-sleep/chromebook-sleep" \
  "$DESTDIR/usr/local/bin/chromebook-sleep" \
  "$DESTDIR/usr/local/lib/chromebook-sleep"; do
  if [[ -e $f ]]; then
    rm -rf "$f"
    echo "Removed ${f#"$DESTDIR"}"
  fi
done

if [[ -f $conf ]]; then
  if [[ -z $purge ]]; then
    purge=no
    if [[ -t 0 ]]; then
      read -r -p "Also delete ${conf#"$DESTDIR"}? [y/N] " reply
      [[ $reply =~ ^[Yy] ]] && purge=yes
    fi
  fi
  if [[ $purge == yes ]]; then
    rm -f "$conf"
    echo "Removed ${conf#"$DESTDIR"}"
  else
    echo "Kept ${conf#"$DESTDIR"}"
  fi
fi
