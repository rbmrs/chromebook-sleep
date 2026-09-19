#!/bin/bash
# Runs setup.sh and uninstall.sh into a staging DESTDIR. Usage: tests/install-test.sh

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DESTDIR=$tmp/root

pass=0 fail=0
check() {
  local name=$1; shift
  if "$@"; then ((++pass)); else ((++fail)); echo "FAIL: $name"; sed 's/^/    /' "$tmp/out"; fi
}
setup() { "$root/system/setup.sh" "$@" >"$tmp/out" 2>&1 </dev/null; }
uninstall() { "$root/system/uninstall.sh" "$@" >"$tmp/out" 2>&1 </dev/null; }
mode() { stat -c %a "$DESTDIR$1"; }
has() { grep -q -- "$1" "$tmp/out"; }

hook=/usr/lib/systemd/system-sleep/chromebook-sleep
cli=/usr/local/bin/chromebook-sleep
lib=/usr/local/lib/chromebook-sleep/common.sh
conf=/etc/chromebook-sleep.conf

setup
check "first install without --after and no TTY fails" test $? -ne 0
check "asks for --after" has "pass --after"

rm -rf "$DESTDIR"
setup --after 45d
check "rejects invalid --after" test $? -ne 0

rm -rf "$DESTDIR"
setup --after 12h
check "install succeeds" test $? -eq 0
check "hook is 755" test "$(mode $hook)" = 755
check "cli is 755" test "$(mode $cli)" = 755
check "lib is 644" test "$(mode $lib)" = 644
check "config is 664" test "$(mode $conf)" = 664
check "config has the chosen time" grep -q '^POWEROFF_AFTER=12h ' "$DESTDIR$conf"

# The installed pieces work together and accept the generated config.
export CHROMEBOOK_SLEEP_LIB=$DESTDIR$lib CHROMEBOOK_SLEEP_CONF=$DESTDIR$conf CHROMEBOOK_SLEEP_HOOK=$DESTDIR$hook
"$DESTDIR$cli" status >"$tmp/out" 2>&1
check "generated config is valid" has "enabled: power off after 12h asleep"
check "status sees the hook" has "Hook:        installed"
"$DESTDIR$cli" set 3d >"$tmp/out" 2>&1
check "cli edits generated config" grep -q '^POWEROFF_AFTER=3d ' "$DESTDIR$conf"

setup --after 1h
check "re-run succeeds" test $? -eq 0
check "re-run keeps config" grep -q '^POWEROFF_AFTER=3d ' "$DESTDIR$conf"
check "re-run says so" has "Keeping config"

mkdir -p "$DESTDIR/etc/systemd/system-sleep" "$DESTDIR/run/chromebook-sleep"
touch "$DESTDIR/etc/systemd/system-sleep/chromebook-sleep" "$DESTDIR/run/chromebook-sleep/test"
setup
check "re-run removes hook from /etc (never executed there)" test ! -e "$DESTDIR/etc/systemd/system-sleep/chromebook-sleep"
check "re-run removes a leftover test override" test ! -e "$DESTDIR/run/chromebook-sleep/test"

chmod 0600 "$DESTDIR$conf"
setup
check "re-run repairs config mode" test "$(mode $conf)" = 664

mkdir -p "$DESTDIR/run/chromebook-sleep" "$DESTDIR/sys/class/rtc/rtc0"
echo "1 2 skip" >"$DESTDIR/run/chromebook-sleep/state"
echo 999 >"$DESTDIR/sys/class/rtc/rtc0/wakealarm"
uninstall --keep-config
check "uninstall succeeds" test $? -eq 0
check "hook removed" test ! -e "$DESTDIR$hook"
check "cli removed" test ! -e "$DESTDIR$cli"
check "lib dir removed" test ! -e "$DESTDIR/usr/local/lib/chromebook-sleep"
check "armed alarm cleared" test "$(cat "$DESTDIR/sys/class/rtc/rtc0/wakealarm")" = 0
check "--keep-config keeps it" test -f "$DESTDIR$conf"

setup --after 12h >/dev/null
echo 999 >"$DESTDIR/sys/class/rtc/rtc0/wakealarm"
uninstall
check "no TTY keeps config by default" test -f "$DESTDIR$conf"
check "foreign alarm untouched" test "$(cat "$DESTDIR/sys/class/rtc/rtc0/wakealarm")" = 999

setup >/dev/null
uninstall --purge
check "--purge removes config" test ! -e "$DESTDIR$conf"

uninstall
check "uninstall on clean system succeeds" test $? -eq 0

echo "$pass passed, $fail failed"
((fail == 0))
