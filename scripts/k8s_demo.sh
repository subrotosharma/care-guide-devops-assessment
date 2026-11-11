#!/usr/bin/env bash
#
# k8s_demo.sh - end-to-end Kubernetes demo on a local kind cluster:
# initial deploy, zero-downtime rolling update under load, failed rollout, rollback.
# Requires docker, kind and kubectl. Output is also written to docs/evidence/k8s-demo.txt.
#
#   scripts/k8s_demo.sh            run the demo (creates a cluster named devops-task)
#   scripts/k8s_demo.sh cleanup    delete the cluster

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cluster=devops-task
ns=devops-task
evidence="${root}/docs/evidence/k8s-demo.txt"

if [[ ${1:-} == cleanup ]]; then
  kind delete cluster --name "${cluster}"
  exit 0
fi

for tool in docker kind kubectl; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 1; }
done

mkdir -p "$(dirname "${evidence}")"
exec > >(tee "${evidence}") 2>&1

step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }

# The namespace enforces the "restricted" Pod Security Standard, so helper pods
# get the same hardening as the app. curlimages/curl runs as uid 100.
# Usage: helper_pod <name> '<shell command>'
helper_pod() {
  kubectl -n "${ns}" delete pod "$1" --ignore-not-found >/dev/null
  kubectl -n "${ns}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: $1
      image: curlimages/curl:8.10.1
      command: ["sh", "-c"]
      args:
        - |
          $2
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
}

build_and_load() {
  local version=$1
  docker build -q --build-arg APP_VERSION="${version}" -t "devops-task:${version}" "${root}" >/dev/null
  kind load docker-image "devops-task:${version}" --name "${cluster}" >/dev/null
}

step "Create cluster"
kind get clusters | grep -qx "${cluster}" || kind create cluster --config "${root}/k8s/kind-config.yaml" --wait 120s

step "Build and load images 1.0.0 and 1.1.0 (APP_VERSION is baked in at build time)"
build_and_load 1.0.0
build_and_load 1.1.0

step "1. Initial deployment"
run kubectl apply -k "${root}/k8s"
run kubectl -n "${ns}" rollout status deploy/devops-task --timeout=120s
run kubectl -n "${ns}" get deploy,pods,svc,hpa,pdb -o wide

step "2. Zero-downtime rolling update 1.0.0 -> 1.1.0 (in-cluster client polls /health every 0.2s)"
# shellcheck disable=SC2016 # the loop must expand inside the pod, not here
probe_loop='ok=0; fail=0; i=0; while [ $i -lt 400 ]; do if curl -sf -m 2 http://devops-task/health >/dev/null; then ok=$((ok+1)); else fail=$((fail+1)); fi; i=$((i+1)); sleep 0.2; done; echo "requests_ok=$ok requests_failed=$fail"'
echo "$ helper pod 'probe' (restricted securityContext) polling http://devops-task/health every 0.2s"
helper_pod probe "${probe_loop}"
kubectl -n "${ns}" wait --for=condition=Ready pod/probe --timeout=60s >/dev/null
run kubectl -n "${ns}" set image deploy/devops-task app=devops-task:1.1.0
run kubectl -n "${ns}" rollout status deploy/devops-task --timeout=180s
run kubectl -n "${ns}" rollout history deploy/devops-task
echo "Waiting for the probe to finish..."
kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=120s >/dev/null
run kubectl -n "${ns}" logs pod/probe

step "3. Failed rollout: bad configuration, readiness never passes, old pods keep serving"
run kubectl -n "${ns}" set env deploy/devops-task LOG_LEVEL=LOUD
kubectl -n "${ns}" rollout status deploy/devops-task --timeout=40s || echo "(rollout did not complete, as intended)"
run kubectl -n "${ns}" get pods
echo "Service still answering from the healthy old pods:"
helper_pod curl-check 'curl -s http://devops-task/'
kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/curl-check --timeout=60s >/dev/null
run kubectl -n "${ns}" logs pod/curl-check
kubectl -n "${ns}" delete pod curl-check --ignore-not-found >/dev/null

step "4. Rollback with kubectl rollout undo"
run kubectl -n "${ns}" rollout undo deploy/devops-task
run kubectl -n "${ns}" rollout status deploy/devops-task --timeout=120s
run kubectl -n "${ns}" get pods
run kubectl -n "${ns}" rollout history deploy/devops-task
run kubectl -n "${ns}" get deploy devops-task -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

step "Done. Remove the cluster with: scripts/k8s_demo.sh cleanup"
