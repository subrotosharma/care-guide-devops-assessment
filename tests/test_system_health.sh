#!/usr/bin/env bash
# Behavioural tests for scripts/system_health.sh. Plain bash so CI needs nothing extra
# beyond jq (preinstalled on GitHub runners).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/scripts/system_health.sh"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

pass() { echo "ok   - $1"; passed=$((passed + 1)); }
fail() { echo "FAIL - $1"; failed=$((failed + 1)); }

# expect_exit <expected> <description> <args...>
expect_exit() {
  local expected=$1 desc=$2
  shift 2
  local rc=0
  "${SCRIPT}" --no-log --interval 1 "$@" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq "${expected}" ]]; then pass "${desc} (exit ${rc})"; else fail "${desc}: expected ${expected}, got ${rc}"; fi
}

# --- exit codes ---------------------------------------------------------------
# thresholds at 100 can never be crossed except by a completely full disk
expect_exit 0 "healthy when thresholds are unreachable" --disk 100 --cpu 100 --mem 100
# memory is always >= 1%, and a huge critical offset keeps it below critical
expect_exit 1 "warning when memory threshold is crossed" --disk 100 --cpu 100 --mem 1 --critical-offset 99
expect_exit 2 "critical when value passes threshold + offset" --disk 100 --cpu 100 --mem 1 --critical-offset 0
expect_exit 3 "usage error: unknown flag" --bogus
expect_exit 3 "usage error: non-numeric threshold" --disk abc
expect_exit 3 "usage error: threshold out of range" --mem 0
expect_exit 3 "usage error: missing value" --cpu
expect_exit 3 "usage error: zero-length CPU window" --interval 0

# --- help ---------------------------------------------------------------------
if "${SCRIPT}" --help | grep -q "Exit codes"; then pass "--help documents exit codes"; else fail "--help output"; fi

# --- warning text -------------------------------------------------------------
out=$("${SCRIPT}" --no-log --interval 1 --disk 100 --cpu 100 --mem 1 --critical-offset 99 || true)
if grep -q '^\[WARNING\] memory' <<<"${out}"; then pass "prints [WARNING] line"; else fail "[WARNING] line missing"; fi

# --- JSON ---------------------------------------------------------------------
json=$("${SCRIPT}" --json --no-log --interval 1 --disk 100 --cpu 100 --mem 100 2>/dev/null)
if jq -e . >/dev/null <<<"${json}"; then pass "--json emits valid JSON"; else fail "--json invalid"; fi
for field in timestamp host status cpu_used_pct memory load_avg disks top_memory_processes warnings; do
  if jq -e "has(\"${field}\")" >/dev/null <<<"${json}"; then pass "json has ${field}"; else fail "json missing ${field}"; fi
done
procs=$(jq '.top_memory_processes | length' <<<"${json}")
if [[ "${procs}" -le 5 && "${procs}" -ge 1 ]]; then pass "at most 5 processes reported (${procs})"; else fail "process count ${procs}"; fi

# warnings must not pollute stdout in JSON mode
json_warn=$("${SCRIPT}" --json --no-log --interval 1 --disk 100 --cpu 100 --mem 1 --critical-offset 99 2>/dev/null || true)
if jq -e '.status == "warning" and (.warnings | length) >= 1' >/dev/null <<<"${json_warn}"; then
  pass "json status and warnings array reflect threshold breach"
else
  fail "json warning content"
fi

# --- logging and rotation -------------------------------------------------------
log="${WORK}/logs/health_log.txt"
"${SCRIPT}" --interval 1 --disk 100 --cpu 100 --mem 100 --log-file "${log}" >/dev/null || true
if [[ -s "${log}" ]] && grep -q '^=== 20' "${log}"; then pass "text entry appended with timestamp"; else fail "log entry"; fi

"${SCRIPT}" --json --interval 1 --disk 100 --cpu 100 --mem 100 --log-file "${log}.json" >/dev/null || true
if jq -e . "${log}.json" >/dev/null; then pass "json log line is valid"; else fail "json log"; fi

rot="${WORK}/rot/health_log.txt"
for _ in 1 2 3 4 5 6 7 8; do
  "${SCRIPT}" --interval 1 --disk 100 --cpu 100 --mem 100 --log-file "${rot}" --max-log-bytes 500 --keep 3 >/dev/null || true
done
if [[ -f "${rot}.1" && -f "${rot}.2" && -f "${rot}.3" && ! -f "${rot}.4" ]]; then
  pass "rotation keeps exactly 3 old files"
else
  fail "rotation file set: $(ls "${WORK}/rot")"
fi
size=$(wc -c <"${rot}")
if [[ "${size}" -lt 2000 ]]; then pass "active log stays small after rotation (${size} bytes)"; else fail "active log size ${size}"; fi

# --- script is idempotent on read-only log dir: still reports, does not crash ----
ro="${WORK}/ro"
mkdir -p "${ro}"
chmod 555 "${ro}"
rc=0
if [[ "$(id -u)" -ne 0 ]]; then
  "${SCRIPT}" --interval 1 --disk 100 --cpu 100 --mem 100 --log-file "${ro}/x/health_log.txt" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq 0 ]]; then pass "unwritable log path degrades to a warning, status code unchanged"; else fail "unwritable log exit ${rc}"; fi
fi
chmod 755 "${ro}"

echo
echo "${passed} passed, ${failed} failed"
[[ "${failed}" -eq 0 ]]
