#!/usr/bin/env bash
#
# system_health.sh - Collect host health metrics, log them, and flag problems.
#
# Exit codes: 0 = healthy, 1 = warning, 2 = critical, 3 = usage/runtime error
#
set -euo pipefail

# ---------- Defaults (override with flags) ----------
CPU_THRESHOLD=90
MEM_THRESHOLD=85
DISK_THRESHOLD=80
CRIT_MARGIN=10            # critical level = threshold + this (capped at 100)
LOG_FILE="./health_log.txt"
MAX_LOG_KB=1024
KEEP_LOGS=3
JSON_OUTPUT=false

# ---------- State ----------
STATUS=0                  # 0 ok, 1 warning, 2 critical
WARNINGS=()

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Collects CPU, memory, disk, load average and the top 5 processes by memory,
appends a timestamped entry to a log file and exits with a status code.

Options:
  --cpu PCT          CPU warning threshold in percent    (default: ${CPU_THRESHOLD})
  --mem PCT          Memory warning threshold in percent (default: ${MEM_THRESHOLD})
  --disk PCT         Disk warning threshold in percent   (default: ${DISK_THRESHOLD})
  --json             Print and log JSON instead of plain text
  --log-file PATH    Log file path                       (default: ${LOG_FILE})
  --max-size-kb N    Rotate the log above N KB           (default: ${MAX_LOG_KB})
  -h, --help         Show this help

Exit codes:
  0 healthy | 1 warning (>= threshold) | 2 critical (>= threshold + ${CRIT_MARGIN}) | 3 error
EOF
}

die() { echo "ERROR: $*" >&2; exit 3; }

require_int() {
  local name=$1 value=${2:-}
  if ! [[ $value =~ ^[0-9]+$ ]] || (( value < 1 )); then
    die "${name} needs a positive integer (got '${value}')"
  fi
}

require_pct() {
  local name=$1 value=${2:-}
  require_int "$name" "$value"
  if (( value > 100 )); then
    die "${name} must be between 1 and 100 (got '${value}')"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu)         require_pct "$1" "${2:-}"; CPU_THRESHOLD=$2; shift 2 ;;
      --mem)         require_pct "$1" "${2:-}"; MEM_THRESHOLD=$2; shift 2 ;;
      --disk)        require_pct "$1" "${2:-}"; DISK_THRESHOLD=$2; shift 2 ;;
      --max-size-kb) require_int "$1" "${2:-}"; MAX_LOG_KB=$2; shift 2 ;;
      --log-file)
        [[ -n ${2:-} ]] || die "--log-file needs a path"
        LOG_FILE=$2; shift 2 ;;
      --json)        JSON_OUTPUT=true; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "unknown option: $1" ;;
    esac
  done
}

# ---------- Collectors ----------

# Prints "<total jiffies> <idle jiffies>" from the first line of /proc/stat
cpu_times() {
  local u n s i w irq sirq st
  read -r _ u n s i w irq sirq st _ < /proc/stat
  echo "$((u + n + s + i + w + irq + sirq + st)) $((i + w))"
}

# CPU usage in percent, measured over a 1-second window
get_cpu_usage() {
  local total1 idle1 total2 idle2
  read -r total1 idle1 <<< "$(cpu_times)"
  sleep 1
  read -r total2 idle2 <<< "$(cpu_times)"
  local total_d=$((total2 - total1)) idle_d=$((idle2 - idle1))
  if (( total_d <= 0 )); then
    echo 0
    return 0
  fi
  echo $(( 100 * (total_d - idle_d) / total_d ))
}

# Prints "<total MB> <used MB> <used %>" (used = total - MemAvailable)
get_mem_info() {
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      if (total > 0) printf "%d %d %d\n", total/1024, (total-avail)/1024, (total-avail)*100/total
      else print "0 0 0"
    }' /proc/meminfo
}

# One line per real filesystem: mount|percent|used|size
get_disk_info() {
  { df -Ph -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || true; } |
    awk 'NR > 1 && $5 ~ /^[0-9]+%$/ { gsub("%", "", $5); print $6 "|" $5 "|" $3 "|" $2 }'
}

# One line per process (top 5 by memory): pid|mem%|command
get_top_processes() {
  ps -eo pid=,%mem=,comm= --sort=-%mem |
    awk 'NR <= 5 { pid = $1; mem = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); print pid "|" mem "|" $0 }'
}

# ---------- Evaluation ----------

raise_status() {
  if (( $1 > STATUS )); then STATUS=$1; fi
}

check_threshold() {
  local label=$1 value=$2 threshold=$3
  local critical=$((threshold + CRIT_MARGIN))
  if (( critical > 100 )); then critical=100; fi
  if (( value >= critical )); then
    WARNINGS+=("[CRITICAL] ${label} at ${value}% (critical level ${critical}%)")
    raise_status 2
  elif (( value >= threshold )); then
    WARNINGS+=("[WARNING] ${label} at ${value}% (threshold ${threshold}%)")
    raise_status 1
  fi
}

status_label() {
  case $STATUS in
    0) echo "OK" ;;
    1) echo "WARNING" ;;
    *) echo "CRITICAL" ;;
  esac
}

# ---------- Output builders ----------

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

build_text() {
  local mount pct used size pid mem comm w
  echo "[${TS}] host=${HOST} status=$(status_label)"
  echo "  cpu:    ${CPU_PCT}%"
  echo "  memory: ${MEM_PCT}% (${MEM_USED_MB}MB of ${MEM_TOTAL_MB}MB)"
  echo "  load:   ${LOAD1} ${LOAD5} ${LOAD15} (1/5/15 min)"
  echo "  disks:"
  while IFS='|' read -r mount pct used size; do
    [[ -n $mount ]] || continue
    echo "    ${mount}: ${pct}% (${used} of ${size})"
  done <<< "$DISK_DATA"
  echo "  top 5 processes by memory:"
  while IFS='|' read -r pid mem comm; do
    [[ -n $pid ]] || continue
    echo "    ${pid} ${comm} ${mem}%"
  done <<< "$PROC_DATA"
  if (( ${#WARNINGS[@]} > 0 )); then
    for w in "${WARNINGS[@]}"; do
      echo "  ${w}"
    done
  fi
}

build_json() {
  local mount pct used size pid mem comm w sep
  local disks="" procs="" warns=""
  sep=""
  while IFS='|' read -r mount pct used size; do
    [[ -n $mount ]] || continue
    disks+="${sep}{\"mount\":\"$(json_escape "$mount")\",\"used_percent\":${pct},\"used\":\"${used}\",\"size\":\"${size}\"}"
    sep=","
  done <<< "$DISK_DATA"
  sep=""
  while IFS='|' read -r pid mem comm; do
    [[ -n $pid ]] || continue
    procs+="${sep}{\"pid\":${pid},\"name\":\"$(json_escape "$comm")\",\"mem_percent\":${mem}}"
    sep=","
  done <<< "$PROC_DATA"
  sep=""
  if (( ${#WARNINGS[@]} > 0 )); then
    for w in "${WARNINGS[@]}"; do
      warns+="${sep}\"$(json_escape "$w")\""
      sep=","
    done
  fi
  printf '{"timestamp":"%s","host":"%s","status":"%s","cpu_percent":%s,"memory":{"used_percent":%s,"used_mb":%s,"total_mb":%s},"load_average":{"1m":%s,"5m":%s,"15m":%s},"disks":[%s],"top_memory_processes":[%s],"warnings":[%s]}\n' \
    "$TS" "$(json_escape "$HOST")" "$(status_label)" "$CPU_PCT" \
    "$MEM_PCT" "$MEM_USED_MB" "$MEM_TOTAL_MB" \
    "$LOAD1" "$LOAD5" "$LOAD15" \
    "$disks" "$procs" "$warns"
}

# ---------- Log rotation ----------
# When the log exceeds MAX_LOG_KB: .2 -> .3, .1 -> .2, current -> .1 (keeps KEEP_LOGS old files)
rotate_log() {
  [[ -f $LOG_FILE ]] || return 0
  local size i
  size=$(wc -c < "$LOG_FILE")
  if (( size < MAX_LOG_KB * 1024 )); then
    return 0
  fi
  for (( i = KEEP_LOGS - 1; i >= 1; i-- )); do
    if [[ -f "${LOG_FILE}.${i}" ]]; then
      mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    fi
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

main() {
  local mount pct
  parse_args "$@"
  [[ -r /proc/stat && -r /proc/meminfo ]] || die "this script needs a Linux /proc filesystem"

  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  HOST=$(uname -n)
  CPU_PCT=$(get_cpu_usage)
  read -r MEM_TOTAL_MB MEM_USED_MB MEM_PCT <<< "$(get_mem_info)"
  read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
  DISK_DATA=$(get_disk_info)
  PROC_DATA=$(get_top_processes)

  check_threshold "CPU usage" "$CPU_PCT" "$CPU_THRESHOLD"
  check_threshold "Memory usage" "$MEM_PCT" "$MEM_THRESHOLD"
  while IFS='|' read -r mount pct _ _; do
    [[ -n $mount ]] || continue
    check_threshold "Disk ${mount}" "$pct" "$DISK_THRESHOLD"
  done <<< "$DISK_DATA"

  if [[ $JSON_OUTPUT == true ]]; then
    ENTRY=$(build_json)
  else
    ENTRY=$(build_text)
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  rotate_log
  printf '%s\n' "$ENTRY" >> "$LOG_FILE"
  printf '%s\n' "$ENTRY"

  # In JSON mode stdout must stay pure JSON, so warnings also go to stderr
  if [[ $JSON_OUTPUT == true && ${#WARNINGS[@]} -gt 0 ]]; then
    printf '%s\n' "${WARNINGS[@]}" >&2
  fi

  exit "$STATUS"
}

main "$@"