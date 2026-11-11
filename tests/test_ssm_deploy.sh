#!/usr/bin/env bash
# Exercises scripts/ci/ssm_deploy.sh against a stub `aws` so every exit path is covered
# without AWS access. Usage: tests/test_ssm_deploy.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=${root}/scripts/ci/ssm_deploy.sh
stubdir=$(mktemp -d)
trap 'rm -rf "${stubdir}"' EXIT

cat >"${stubdir}/aws" <<'STUB'
#!/usr/bin/env bash
# Behaviour is driven by STUB_STATUS / STUB_CODE.
if [[ $2 == send-command || $3 == send-command ]]; then echo "cmd-123"; exit 0; fi
if [[ "$*" == *"--query Status"* ]]; then echo "${STUB_STATUS}"; exit 0; fi
echo "[${STUB_CODE}, \"deploy output\", \"\"]"
STUB
chmod +x "${stubdir}/aws"

failures=0
check() { # name expected-exit status code
  local name=$1 expected=$2 status=$3 code=$4 actual=0
  PATH="${stubdir}:${PATH}" STUB_STATUS=${status} STUB_CODE=${code} POLL_SECONDS=0 TIMEOUT_SECONDS=5 \
    "${script}" i-0abc us-east-1 ghcr.io/acme/app:1.0.7 >/dev/null 2>&1 || actual=$?
  if [[ ${actual} -eq ${expected} ]]; then echo "ok   ${name}"; else echo "FAIL ${name}: expected ${expected}, got ${actual}"; failures=$((failures + 1)); fi
}

check "success" 0 Success 0
check "rolled back" 1 Failed 1
check "no previous image" 2 Failed 2
check "rollback failed" 4 Failed 4
check "ssm failure" 5 Failed 127
check "ssm timeout" 5 InProgress -1

actual=0
"${script}" i-0abc us-east-1 'ghcr.io/x/app:1; rm -rf /' >/dev/null 2>&1 || actual=$?
if [[ ${actual} -eq 64 ]]; then echo "ok   rejects injected image ref"; else echo "FAIL injection guard (exit ${actual})"; failures=$((failures + 1)); fi

exit "${failures}"
