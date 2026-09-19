#!/bin/bash
# Runs the sleep hook against a fake config, RTC and power_supply tree.
# Usage: tests/hook-test.sh

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/system/chromebook-sleep.hook
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export CHROMEBOOK_SLEEP_LIB=$root/system/common.sh
export CHROMEBOOK_SLEEP_CONF=$tmp/conf
export CHROMEBOOK_SLEEP_RTC=$tmp/rtc
export CHROMEBOOK_SLEEP_PSU=$tmp/psu
export CHROMEBOOK_SLEEP_RUN=$tmp/run
export CHROMEBOOK_SLEEP_LOG_STDERR=1
export CHROMEBOOK_SLEEP_DRY_RUN=1

pass=0 fail=0
ok() { ((++pass)); }
bad() { ((++fail)); echo "FAIL: $*"; }

reset() {
  rm -rf "$tmp"/{rtc,psu,run,conf,log}
  mkdir -p "$tmp/rtc" "$tmp/psu/AC" "$tmp/psu/BAT0"
  echo > "$tmp/rtc/wakealarm"
  echo Mains >"$tmp/psu/AC/type"
  echo Battery >"$tmp/psu/BAT0/type"
  set_ac 0
}
set_ac() { echo "$1" >"$tmp/psu/AC/online"; }
conf() { printf '%s\n' "$@" >"$tmp/conf"; }
run() { "$hook" "$@" 2>>"$tmp/log"; }
log_has() { grep -q -- "$1" "$tmp/log"; }
armed() { [[ -f $tmp/run/state ]]; }
alarm() { tr -d '\n' <"$tmp/rtc/wakealarm"; }
# Pretend we went to sleep $1 seconds ago with limit $2 and policy $3.
slept() { mkdir -p "$tmp/run"; echo "$(($(date +%s) - $1)) $2 ${3:-skip}" >"$tmp/run/state"; echo 123 >"$tmp/rtc/wakealarm"; }

check() { local name=$1; shift; if "$@"; then ok; else bad "$name"; sed 's/^/    /' "$tmp/log"; fi; }

# --- pre ---
reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=skip
run pre suspend
check "pre arms on battery" armed
now=$(date +%s); a=$(alarm)
check "alarm is now+2h" test $((a - now - 7200)) -le 1 -a $((a - now - 7200)) -ge -1
check "state records limit and policy" grep -q " 7200 skip$" "$tmp/run/state"

reset; conf 'ENABLED=yes      # comment' '  POWEROFF_AFTER = 3d  # x' 'ON_AC=poweroff' '# full comment' ''
run pre suspend
check "inline comments and spaces parse" armed

reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=skip; set_ac 1
run pre suspend
check "on AC + skip does not arm" bash -c "! test -f $tmp/run/state"
check "on AC + skip logs" log_has "on AC with ON_AC=skip"

reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=poweroff; set_ac 1
run pre suspend
check "on AC + poweroff arms" armed

reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=skip
echo USB >"$tmp/psu/AC/type"; set_ac 1
run pre suspend
check "USB charger counts as AC" bash -c "! test -f $tmp/run/state"

reset; conf ENABLED=no POWEROFF_AFTER=2h ON_AC=skip
run pre suspend
check "disabled does not arm" bash -c "! test -f $tmp/run/state"
check "disabled is silent" bash -c "! test -s $tmp/log"

for bad_conf in "POWEROFF_AFTER=12" "POWEROFF_AFTER=1m" "POWEROFF_AFTER=29d" "POWEROFF_AFTER=0h" \
  "POWEROFF_AFTER=12h;reboot" 'POWEROFF_AFTER=$(reboot)' "POWEROFF_AFTER=12H"; do
  reset; conf ENABLED=yes "$bad_conf" ON_AC=skip
  run pre suspend
  check "invalid '$bad_conf' does not arm" bash -c "! test -f $tmp/run/state"
  check "invalid '$bad_conf' warns" log_has "invalid config"
done

reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=maybe
run pre suspend
check "invalid ON_AC does not arm" bash -c "! test -f $tmp/run/state"

reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=skip EVIL=1
run pre suspend
check "unknown key does not arm" bash -c "! test -f $tmp/run/state"

reset
run pre suspend
check "missing config does not arm" bash -c "! test -f $tmp/run/state"

reset; conf ENABLED=yes POWEROFF_AFTER=2m ON_AC=skip
run pre suspend
check "2m minimum accepted" armed
reset; conf ENABLED=yes POWEROFF_AFTER=28d ON_AC=skip
run pre suspend
check "28d maximum accepted" armed

for other in hibernate hybrid-sleep suspend-then-hibernate; do
  reset; conf ENABLED=yes POWEROFF_AFTER=2h ON_AC=skip
  run pre "$other"
  check "ignores $other" bash -c "! test -f $tmp/run/state"
done

# --- post ---
reset; slept 7200 7200
run post suspend
check "limit reached powers off" log_has "would start poweroff.target"
check "post clears alarm" test "$(alarm)" = 0
check "post removes state" bash -c "! test -f $tmp/run/state"

reset; slept 7185 7200
run post suspend
check "within tolerance powers off" log_has "would start poweroff.target"

reset; slept 600 7200
run post suspend
check "early wake resumes normally" log_has "normal resume"
check "early wake does not power off" bash -c "! grep -q poweroff.target $tmp/log"
check "early wake clears alarm" test "$(alarm)" = 0

reset; slept 7200 7200 skip; set_ac 1
run post suspend
check "plugged in during sleep + skip does not power off" bash -c "! grep -q poweroff.target $tmp/log"

reset; slept 7200 7200 poweroff; set_ac 1
run post suspend
check "on AC + poweroff powers off" log_has "would start poweroff.target"

reset; echo 555 >"$tmp/rtc/wakealarm"
run post suspend
check "post without state leaves foreign alarm alone" test "$(alarm)" = 555

reset; mkdir -p "$tmp/run"; echo "garbage here" >"$tmp/run/state"
run post suspend
check "corrupt state is ignored" log_has "corrupt state"

reset; slept 7200 7200
run post hibernate
check "post ignores hibernate" armed

echo "$pass passed, $fail failed"
((fail == 0))
