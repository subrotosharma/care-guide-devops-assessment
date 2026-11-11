# Kubernetes deployment

Plain manifests glued together with Kustomize. Targets a local kind cluster; nothing here is kind-specific except `kind-config.yaml`.

| File | Purpose |
|---|---|
| `namespace.yaml`, `serviceaccount.yaml` | Namespace `devops-task`; a dedicated ServiceAccount with token automount off (the app never calls the API) |
| `configmap.yaml` | `APP_PORT`, `LOG_LEVEL`, `APP_ENV` |
| `deployment.yaml` | 2 replicas, rolling update, probes, resources, security context |
| `service.yaml`, `ingress.yaml` | ClusterIP on port 80; nginx Ingress for `devops-task.localtest.me` |
| `hpa.yaml` | CPU target 70% of request, 2 to 5 replicas, slow scale-down |
| `pdb.yaml` | `minAvailable: 1` during voluntary disruptions such as node drains |
| `examples/secret.example.yaml` | Shape of the optional Secret. Not part of the kustomization. |
| `kind-config.yaml` | One control plane, two workers, host port 8081 mapped to the ingress |

## Prerequisites

Docker, `kind`, `kubectl`. The demo script builds the image locally and loads it into the cluster, so no registry is involved. It also uses `curlimages/curl` for the in-cluster probe, which kind pulls from Docker Hub.

## Quick start

```bash
kind create cluster --config k8s/kind-config.yaml
docker build -t devops-task:1.0.0 --build-arg APP_VERSION=1.0.0 .
kind load docker-image devops-task:1.0.0 --name devops-task
kubectl apply -k k8s
kubectl -n devops-task rollout status deploy/devops-task
kubectl -n devops-task port-forward svc/devops-task 8080:80     # then curl localhost:8080/
```

### Optional add-ons

The HPA needs metrics-server (kind does not ship it, and it needs `--kubelet-insecure-tls` on kind's self-signed kubelets):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

For the Ingress, install ingress-nginx for kind, then `curl http://devops-task.localtest.me:8081/`:

```bash
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
```

Without an ingress controller, use the `port-forward` command above. That is the supported fallback.

## Demonstration

`scripts/k8s_demo.sh` runs all four required scenarios and writes the transcript to `docs/evidence/k8s-demo.txt`:

1. Initial deployment and rollout status.
2. Zero-downtime rolling update from 1.0.0 to 1.1.0 while an in-cluster pod polls `/health` every 200 ms; it prints `requests_ok` and `requests_failed` at the end.
3. A broken rollout (`LOG_LEVEL=LOUD` makes the app exit at start-up, so new pods never become ready). With `maxUnavailable: 0` the old pods keep serving.
4. `kubectl rollout undo`, then the revision history and the running image.

The transcript from a real run is in `docs/evidence/k8s-demo.txt`.

## Why the settings are what they are

- `maxUnavailable: 0, maxSurge: 1`: capacity never drops during a rollout. Costs one extra pod briefly.
- Readiness and liveness both hit `/health`. Readiness is quick (5s period) so a bad pod leaves the Service fast; liveness is slower (10s, three failures) so a slow pod is not killed prematurely. The app has no dependencies, so one endpoint is honest for both.
- `preStop: sleep 5`: endpoint removal and SIGTERM are not ordered. The pause lets the Service and ingress stop sending traffic before uvicorn begins draining. `terminationGracePeriodSeconds` (30) comfortably covers it.
- Requests 50m / 64Mi and limits 250m / 128Mi are sized from the app's idle footprint with headroom; the HPA's 70% target is relative to the 50m request, so scale-out starts at roughly 35m per pod. Tune from real load.
- `readOnlyRootFilesystem` with a 16Mi `emptyDir` on `/tmp` for anything that needs scratch space. Non-root UID 10001, capabilities dropped, `RuntimeDefault` seccomp.
- `revisionHistoryLimit: 5` bounds how far `rollout undo --to-revision` can reach.

## Secrets

No Secret is committed. The Deployment mounts `devops-task-secrets` through `envFrom` with `optional: true`, so the pod starts without it. The service has no secret inputs today; the wiring shows the pattern. To create one by hand:

```bash
kubectl -n devops-task create secret generic devops-task-secrets --from-literal=API_TOKEN="$(openssl rand -hex 16)"
```

For anything real, store the value in AWS Secrets Manager and sync it with the External Secrets Operator (see the EKS section of the main README), or commit only encrypted manifests with Sealed Secrets or SOPS.
