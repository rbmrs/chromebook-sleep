# Shared helpers for chromebook-sleep. Sourced by the sleep hook and the CLI.
# Installed to /usr/local/lib/chromebook-sleep/common.sh.
#
# The CHROMEBOOK_SLEEP_* overrides exist for tests only; systemd-sleep runs
# hooks with a clean environment.

CS_CONF=${CHROMEBOOK_SLEEP_CONF:-/etc/chromebook-sleep.conf}
CS_RTC=${CHROMEBOOK_SLEEP_RTC:-/sys/class/rtc/rtc0}
CS_PSU=${CHROMEBOOK_SLEEP_PSU:-/sys/class/power_supply}
CS_RUN=${CHROMEBOOK_SLEEP_RUN:-/run/chromebook-sleep}

CS_MIN_SECONDS=$((2 * 60))
# rtc_cmos only supports alarms up to one month ahead; 28d fits in any month.
CS_MAX_SECONDS=$((28 * 24 * 3600))

cs_log() {
  local priority=$1
  shift
  if [[ -n ${CHROMEBOOK_SLEEP_LOG_STDERR:-} ]]; then
    echo "chromebook-sleep[$priority]: $*" >&2
  else
    logger -t chromebook-sleep -p "user.$priority" -- "$*"
  fi
}

# Duration like 30m, 8h, 3d -> seconds on stdout. Returns 1 if malformed or out of range.
cs_duration_seconds() {
  [[ $1 =~ ^([1-9][0-9]{0,4})([mhd])$ ]] || return 1
  local n=${BASH_REMATCH[1]} seconds
  case ${BASH_REMATCH[2]} in
    m) seconds=$((n * 60)) ;;
    h) seconds=$((n * 3600)) ;;
    d) seconds=$((n * 86400)) ;;
  esac
  ((seconds >= CS_MIN_SECONDS && seconds <= CS_MAX_SECONDS)) || return 1
  echo "$seconds"
}

# Parse the config without sourcing it. Sets CS_ENABLED (yes|no), CS_POWEROFF_AFTER,
# CS_LIMIT_SECONDS, CS_ON_AC and CS_CONFIG_ERRORS (array). Any missing or invalid
# value forces CS_ENABLED=no.
cs_load_config() {
  CS_ENABLED=no
  CS_POWEROFF_AFTER=
  CS_LIMIT_SECONDS=
  CS_ON_AC=
  CS_CONFIG_ERRORS=()

  if [[ ! -r $CS_CONF ]]; then
    CS_CONFIG_ERRORS+=("cannot read $CS_CONF")
    return 1
  fi

  local line key value enabled= after= on_ac= lineno=0
  local re='^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*([^[:space:]#]*)[[:space:]]*(#.*)?$'
  while IFS= read -r line || [[ -n $line ]]; do
    ((++lineno))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ ! $line =~ $re ]]; then
      CS_CONFIG_ERRORS+=("line $lineno: unparseable")
      continue
    fi
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case $key in
      ENABLED) enabled=$value ;;
      POWEROFF_AFTER) after=$value ;;
      ON_AC) on_ac=$value ;;
      *) CS_CONFIG_ERRORS+=("line $lineno: unknown key $key") ;;
    esac
  done <"$CS_CONF"

  [[ $enabled =~ ^(yes|no)$ ]] || CS_CONFIG_ERRORS+=("ENABLED must be yes or no (got '$enabled')")
  [[ $on_ac =~ ^(skip|poweroff)$ ]] || CS_CONFIG_ERRORS+=("ON_AC must be skip or poweroff (got '$on_ac')")
  if ! CS_LIMIT_SECONDS=$(cs_duration_seconds "$after"); then
    CS_CONFIG_ERRORS+=("POWEROFF_AFTER must be <number><m|h|d> between 2m and 28d (got '$after')")
    CS_LIMIT_SECONDS=
  fi

  CS_POWEROFF_AFTER=$after
  CS_ON_AC=$on_ac
  ((${#CS_CONFIG_ERRORS[@]} == 0)) || return 1
  CS_ENABLED=$enabled
}

# True if any mains or USB charger input is online.
cs_on_ac() {
  local psu type
  for psu in "$CS_PSU"/*; do
    [[ -r $psu/type && -r $psu/online ]] || continue
    read -r type <"$psu/type"
    [[ $type == Mains || $type == USB* ]] || continue
    [[ $(<"$psu/online") == 1 ]] && return 0
  done
  return 1
}

# 45s, 12m, 3d 4h style rendering of a number of seconds.
cs_human() {
  local s=$1 d h m out=
  ((s < 60)) && { echo "${s}s"; return; }
  d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  ((d)) && out+="${d}d "
  ((h)) && out+="${h}h "
  ((m)) && out+="${m}m "
  echo "${out% }"
}
