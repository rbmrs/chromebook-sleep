#!/bin/bash
# Exercises the CLI against a temporary config. Usage: tests/cli-test.sh

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cli=$root/system/chromebook-sleep
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export CHROMEBOOK_SLEEP_LIB=$root/system/common.sh
export CHROMEBOOK_SLEEP_CONF=$tmp/conf
export CHROMEBOOK_SLEEP_RTC=$tmp/rtc
export CHROMEBOOK_SLEEP_PSU=$tmp/psu
export CHROMEBOOK_SLEEP_HOOK=$tmp/hook

pass=0 fail=0
check() {
  local name=$1; shift
  if "$@"; then ((++pass)); else ((++fail)); echo "FAIL: $name"; sed 's/^/    /' "$tmp/out"; fi
}
run() { "$cli" "$@" >"$tmp/out" 2>&1; }
has() { grep -q -- "$1" "$tmp/out"; }
conf_is() { diff <(printf '%s\n' "$@") "$tmp/conf" >/dev/null; }

reset() {
  rm -rf "$tmp"/{conf,rtc,psu,hook}
  mkdir -p "$tmp/rtc/device/power" "$tmp/psu/AC"
  echo enabled >"$tmp/rtc/device/power/wakeup"
  echo Mains >"$tmp/psu/AC/type"; echo 0 >"$tmp/psu/AC/online"
  printf '%s\n' '# chromebook-sleep' 'ENABLED=yes      # on' 'POWEROFF_AFTER=12h  # when' 'ON_AC=skip' >"$tmp/conf"
}

reset
run set 8h
check "set succeeds" test $? -eq 0
check "set keeps comments and order" conf_is '# chromebook-sleep' 'ENABLED=yes      # on' 'POWEROFF_AFTER=8h  # when' 'ON_AC=skip'
check "set reports the limit" has "after 8h asleep"

for badval in 12 1m 29d 0h '8h;reboot' '' 8H; do
  reset
  run set "$badval"
  check "set rejects '$badval'" test $? -ne 0
  check "set '$badval' leaves config untouched" conf_is '# chromebook-sleep' 'ENABLED=yes      # on' 'POWEROFF_AFTER=12h  # when' 'ON_AC=skip'
done

reset
run disable
check "disable" grep -qx 'ENABLED=no      # on' "$tmp/conf"
run enable
check "enable" grep -qx 'ENABLED=yes      # on' "$tmp/conf"

reset
run on-ac poweroff
check "on-ac poweroff" grep -qx 'ON_AC=poweroff' "$tmp/conf"
run on-ac maybe
check "on-ac rejects junk" test $? -ne 0

reset; printf 'ENABLED=yes\n' >"$tmp/conf"
run set 2d
check "set appends a missing key" grep -qx 'POWEROFF_AFTER=2d' "$tmp/conf"
check "set warns when config still invalid" has "ON_AC must be"

reset; rm "$tmp/conf"
run set 2d
check "set without config fails" test $? -ne 0
check "set without config says to run setup" has "run setup.sh"

reset; chmod 0444 "$tmp/conf"
run enable
check "read-only config fails" test $? -ne 0
chmod 0644 "$tmp/conf"

reset
run status
check "status shows enabled" has "enabled: power off after 12h asleep"
check "status shows hook missing" has "NOT installed"
: >"$tmp/hook"; chmod +x "$tmp/hook"
run status
check "status shows hook installed" has "Hook:        installed"

reset; printf 'ENABLED=yes\nPOWEROFF_AFTER=nope\nON_AC=skip\n' >"$tmp/conf"
run status
check "status flags invalid config" has "invalid config"

reset; echo 1 >"$tmp/psu/AC/online"
run status --json
check "status --json is valid JSON" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/out"
check "json fields" python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))
assert d["enabled"] is True and d["limitSeconds"] == 43200 and d["poweroffAfter"] == "12h"
assert d["onAc"] == "skip" and d["onAcNow"] is True and d["installed"] is False
assert d["configValid"] is True and d["configErrors"] == [] and d["rtcWakeup"] == "enabled"' "$tmp/out"

reset; printf 'ENABLED=yes\nPOWEROFF_AFTER="x"\n' >"$tmp/conf"
run status --json
check "json with invalid config still valid JSON" python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))
assert d["configValid"] is False and d["enabled"] is False and d["limitSeconds"] is None and d["configErrors"]' "$tmp/out"

run bogus
check "unknown command exits 2" test $? -eq 2
run
check "no command exits 2" test $? -eq 2
run test 1m
check "test rejects invalid duration" test $? -ne 0
reset; run test
check "test refuses without the hook" has "not installed"

echo "$pass passed, $fail failed"
((fail == 0))
