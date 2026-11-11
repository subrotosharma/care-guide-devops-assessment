#!/usr/bin/env bash
#
# system_health.sh - point-in-time host health check for CPU, memory, disk,
# load and the heaviest processes. Meant to run from cron/systemd every few
# minutes and to be consumed by monitoring tools through its exit code.
#
# Exit codes follow the Nagios plugin convention:
#   0 healthy, 1 warning, 2 critical, 3 unknown (bad usage or unreadable data)

set -euo pipefail

readonly PROGRAM="${0##*/}"

DISK_THRESHOLD=80
CPU_THRESHOLD=90
MEM_THRESHOLD=85
CRITICAL_OFFSET=10
SAMPLE_INTERVAL=1
LOG_FILE="${HEALTH_LOG_FILE:-health_log.txt}"
MAX_LOG_BYTES=1048576
KEEP_LOGS=5
JSON_OUTPUT=false
WRITE_LOG=true

usage() {
  cat <<EOF
Usage: ${PROGRAM} [options]

Collects CPU, memory, disk (all real mounted filesystems), load average and
the top 5 processes by memory, appends a timestamped entry to the log file and
prints the same entry to stdout.

Thresholds (percent used; a [WARNING] is raised when value >= threshold):
  --disk N             per-filesystem disk usage        (default ${DISK_THRESHOLD})
  --cpu N              CPU busy over the sample window  (default ${CPU_THRESHOLD})
  --mem N              memory in use, excl. cache       (default ${MEM_THRESHOLD})
  --critical-offset N  critical when value >= threshold + N, capped at 100
                       (default ${CRITICAL_OFFSET})

Output:
  --json               emit one JSON object per run instead of text
  --log-file PATH      log file (default: \$HEALTH_LOG_FILE or ./health_log.txt)
  --no-log             print only, do not touch the log file
  --max-log-bytes N    rotate when the log reaches N bytes (default ${MAX_LOG_BYTES})
  --keep N             rotated files to keep, health_log.txt.1..N (default ${KEEP_LOGS})
  --interval SECONDS   CPU sampling window, minimum 1 (default ${SAMPLE_INTERVAL})
  -h, --help           show this help

Exit codes: 0 healthy, 1 warning, 2 critical, 3 usage or data error.
Warnings are printed to stderr in --json mode so stdout stays valid JSON.
EOF
}

die() {
  echo "${PROGRAM}: $*" >&2
  exit 3
}

require_number() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 expects a non-negative integer, got '$2'"
}

require_percent() {
  require_number "$1" "$2"
  (("$2" >= 1 && "$2" <= 100)) || die "$1 must be between 1 and 100, got '$2'"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --disk | --cpu | --mem | --critical-offset | --log-file | --max-log-bytes | --keep | --interval)
        (($# >= 2)) || die "$1 requires a value"
        ;;&
      --disk) require_percent "$1" "$2"; DISK_THRESHOLD=$2; shift 2 ;;
      --cpu) require_percent "$1" "$2"; CPU_THRESHOLD=$2; shift 2 ;;
      --mem) require_percent "$1" "$2"; MEM_THRESHOLD=$2; shift 2 ;;
      --critical-offset) require_number "$1" "$2"; CRITICAL_OFFSET=$2; shift 2 ;;
      --log-file) LOG_FILE=$2; shift 2 ;;
      --max-log-bytes) require_number "$1" "$2"; MAX_LOG_BYTES=$2; shift 2 ;;
      --keep) require_number "$1" "$2"; KEEP_LOGS=$2; shift 2 ;;
      --interval)
        require_number "$1" "$2"
        (("$2" >= 1)) || die "--interval must be at least 1 second (a shorter window is dominated by tick noise)"
        SAMPLE_INTERVAL=$2
        shift 2
        ;;
      --json) JSON_OUTPUT=true; shift ;;
      --no-log) WRITE_LOG=false; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# collectors
# ---------------------------------------------------------------------------

# Reads the aggregate "cpu" line of /proc/stat and prints "<busy> <total>".
# idle and iowait count as not busy.
read_cpu_counters() {
  local _ user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat ||
    die "cannot read /proc/stat"
  local idle_all=$((idle + iowait))
  local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  echo "$((total - idle_all)) ${total}"
}

collect_cpu() {
  local busy1 total1 busy2 total2
  read -r busy1 total1 < <(read_cpu_counters)
  sleep "${SAMPLE_INTERVAL}"
  read -r busy2 total2 < <(read_cpu_counters)
  awk -v b="$((busy2 - busy1))" -v t="$((total2 - total1))" \
    'BEGIN { printf "%.1f", (t > 0 ? 100 * b / t : 0) }'
}

collect_memory() {
  # "used" is total minus MemAvailable, so page cache does not trigger alerts.
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      if (total == 0) exit 1
      printf "%.1f %d %d\n", 100 * (total - avail) / total, (total - avail) / 1024, total / 1024
    }' /proc/meminfo || die "cannot read /proc/meminfo"
}

# One line per filesystem: "<use%> <source> <mountpoint>". Pseudo filesystems
# are skipped, and a device mounted in several places is listed once.
collect_disks() {
  local out
  out=$(df --output=pcent,source,target \
    -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x ramfs 2>/dev/null) ||
    die "df failed"
  awk 'NR > 1 {
      pct = $1; sub(/%/, "", pct)
      src = $2
      target = $0
      sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", target)
      if (!(src in seen)) { seen[src] = 1; print pct, src, target }
    }' <<<"${out}"
}

collect_load() {
  local l1 l5 l15 _
  read -r l1 l5 l15 _ </proc/loadavg || die "cannot read /proc/loadavg"
  echo "${l1} ${l5} ${l15} $(nproc)"
}

collect_top_processes() {
  local out
  out=$(ps -eo pid=,user=,pmem=,rss=,comm= --sort=-pmem) || die "ps failed"
  # head after the variable assignment: piping ps straight into head would make
  # ps die of SIGPIPE, which pipefail turns into a script failure.
  head -n 5 <<<"${out}"
}

# ---------------------------------------------------------------------------
# evaluation
# ---------------------------------------------------------------------------

STATUS_CODE=0
WARNINGS=()

# check <label> <value> <threshold>
check() {
  local label=$1 value=$2 threshold=$3
  local critical=$((threshold + CRITICAL_OFFSET))
  ((critical > 100)) && critical=100
  if awk -v v="${value}" -v c="${critical}" 'BEGIN { exit !(v >= c) }'; then
    WARNINGS+=("[CRITICAL] ${label} at ${value}% (critical >= ${critical}%)")
    STATUS_CODE=2
  elif awk -v v="${value}" -v t="${threshold}" 'BEGIN { exit !(v >= t) }'; then
    WARNINGS+=("[WARNING] ${label} at ${value}% (threshold ${threshold}%)")
    ((STATUS_CODE < 1)) && STATUS_CODE=1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

json_escape() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "${s}" | tr -d '\000-\037'
}

status_label() {
  case $1 in
    0) echo "healthy" ;;
    1) echo "warning" ;;
    *) echo "critical" ;;
  esac
}

render_text() {
  local ts=$1 host=$2
  echo "=== ${ts} host=${host} status=$(status_label "${STATUS_CODE}") ==="
  echo "cpu_used_pct=${CPU_PCT}"
  echo "mem_used_pct=${MEM_PCT} (${MEM_USED_MB}MB of ${MEM_TOTAL_MB}MB)"
  echo "load_avg=${LOAD_1} ${LOAD_5} ${LOAD_15} cores=${CORES}"
  echo "disks:"
  local pct src mount
  while read -r pct src mount; do
    [[ -n "${pct}" ]] || continue
    echo "  ${mount} (${src}) ${pct}%"
  done <<<"${DISKS}"
  echo "top_memory_processes (pid user %mem rss_kb command):"
  local line
  while IFS= read -r line; do
    echo "  ${line}"
  done <<<"${TOP_PROCS}"
  local w
  for w in "${WARNINGS[@]}"; do
    echo "${w}"
  done
}

render_json() {
  local ts=$1 host=$2
  local disks_json="" procs_json="" warn_json="" sep=""
  local pct src mount

  while read -r pct src mount; do
    [[ -n "${pct}" ]] || continue
    disks_json+="${sep}{\"mount\":\"$(json_escape "${mount}")\",\"source\":\"$(json_escape "${src}")\",\"used_pct\":${pct}}"
    sep=","
  done <<<"${DISKS}"

  sep=""
  local pid user pmem rss comm
  while read -r pid user pmem rss comm; do
    [[ -n "${pid}" ]] || continue
    procs_json+="${sep}{\"pid\":${pid},\"user\":\"$(json_escape "${user}")\",\"mem_pct\":${pmem},\"rss_kb\":${rss},\"command\":\"$(json_escape "${comm}")\"}"
    sep=","
  done <<<"${TOP_PROCS}"

  sep=""
  local w
  for w in "${WARNINGS[@]}"; do
    warn_json+="${sep}\"$(json_escape "${w}")\""
    sep=","
  done

  printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,' \
    "${ts}" "$(json_escape "${host}")" "$(status_label "${STATUS_CODE}")" "${STATUS_CODE}"
  printf '"cpu_used_pct":%s,"memory":{"used_pct":%s,"used_mb":%s,"total_mb":%s},' \
    "${CPU_PCT}" "${MEM_PCT}" "${MEM_USED_MB}" "${MEM_TOTAL_MB}"
  printf '"load_avg":{"1m":%s,"5m":%s,"15m":%s,"cores":%s},' \
    "${LOAD_1}" "${LOAD_5}" "${LOAD_15}" "${CORES}"
  printf '"thresholds":{"disk":%s,"cpu":%s,"mem":%s,"critical_offset":%s},' \
    "${DISK_THRESHOLD}" "${CPU_THRESHOLD}" "${MEM_THRESHOLD}" "${CRITICAL_OFFSET}"
  printf '"disks":[%s],"top_memory_processes":[%s],"warnings":[%s]}\n' \
    "${disks_json}" "${procs_json}" "${warn_json}"
}

file_size() {
  wc -c <"$1" 2>/dev/null | tr -d ' ' || echo 0
}

rotate_log() {
  [[ -f "${LOG_FILE}" ]] || return 0
  (($(file_size "${LOG_FILE}") >= MAX_LOG_BYTES)) || return 0
  if ((KEEP_LOGS == 0)); then
    : >"${LOG_FILE}"
    return 0
  fi
  local i
  for ((i = KEEP_LOGS - 1; i >= 1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f "${LOG_FILE}" "${LOG_FILE}.1"
}

# Serialise rotate+append with flock when available so overlapping runs
# (a slow run still going when the next timer fires) cannot interleave.
append_to_log() {
  local entry=$1
  mkdir -p "$(dirname "${LOG_FILE}")"
  if command -v flock >/dev/null 2>&1; then
    {
      flock -w 10 9 || die "could not lock ${LOG_FILE}.lock"
      rotate_log
      printf '%s\n' "${entry}" >>"${LOG_FILE}"
    } 9>"${LOG_FILE}.lock"
  else
    rotate_log
    printf '%s\n' "${entry}" >>"${LOG_FILE}"
  fi
}

main() {
  parse_args "$@"

  local ts host
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  host=$(hostname)

  CPU_PCT=$(collect_cpu)
  read -r MEM_PCT MEM_USED_MB MEM_TOTAL_MB < <(collect_memory)
  read -r LOAD_1 LOAD_5 LOAD_15 CORES < <(collect_load)
  DISKS=$(collect_disks)
  TOP_PROCS=$(collect_top_processes)

  check "cpu" "${CPU_PCT}" "${CPU_THRESHOLD}"
  check "memory" "${MEM_PCT}" "${MEM_THRESHOLD}"
  local pct src mount
  while read -r pct src mount; do
    [[ -n "${pct}" ]] || continue
    check "disk ${mount}" "${pct}" "${DISK_THRESHOLD}"
  done <<<"${DISKS}"

  local entry
  if [[ "${JSON_OUTPUT}" == true ]]; then
    entry=$(render_json "${ts}" "${host}")
    printf '%s\n' "${entry}"
    local w
    for w in "${WARNINGS[@]}"; do
      echo "${w}" >&2
    done
  else
    entry=$(render_text "${ts}" "${host}")
    printf '%s\n' "${entry}"
  fi

  if [[ "${WRITE_LOG}" == true ]]; then
    append_to_log "${entry}" || echo "${PROGRAM}: warning: could not write ${LOG_FILE}" >&2
  fi

  exit "${STATUS_CODE}"
}

main "$@"
