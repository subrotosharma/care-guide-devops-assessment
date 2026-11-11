# Technical guide (for explaining this in an interview)

This is the "why" behind each part, in the order you are likely to be asked. For commands, see the README. Anything marked **not run** was never executed in the authoring sandbox; say so if asked rather than implying otherwise.

## 1. The 60-second summary

A tiny FastAPI service with three endpoints. Around it: a hardened Alpine image, a GitHub Actions pipeline that gates PRs (lint, tests, Hadolint, ShellCheck, Trivy) and on merge publishes a multi-arch image to GHCR and deploys it to EC2 over SSM with automatic rollback; Terraform for the AWS side with S3 state; Kubernetes manifests with probes, limits, HPA; a Compose overlay with Prometheus, Loki, Alloy, Node Exporter, cAdvisor and Grafana, all provisioned from files; and a host health script with proper exit codes.

## 2. Why each technology

| Choice | Reason | What you'd say if challenged |
|---|---|---|
| FastAPI + prometheus-client | Small, fast to write, standard metrics library | A Go service would give a smaller image; I picked Python for speed of delivery and readable tests. |
| Alpine | Small, has a shell for debugging | Distroless is tighter but couples you to Debian's Python and removes the shell; I'd move if I needed native wheels. |
| GHCR | Needs only the built-in token | ECR is better in an AWS-only shop (instance-role pulls, no public package). |
| SSM, not SSH | No inbound port 22, no key management, audited, IAM-controlled | The trade-off is that the instance needs the SSM agent and outbound internet. |
| OIDC | No stored AWS keys | Short-lived credentials per job, trust pinned to repo + environment. |
| Terraform with S3 `use_lockfile` | No DynamoDB table needed (Terraform 1.10+) | The older approach was S3 + DynamoDB; still valid on older versions. |
| Kustomize | Plain YAML, built into kubectl | Helm is better once you need many environments or to publish a chart. |
| Prometheus rules over Grafana alerts | Files that `promtool` can unit-test | No routing until Alertmanager is added. |
| Alloy | Grafana's current collector; Promtail is EOL | It does Docker discovery natively. |

## 3. How the system fits together

- Code is pushed. `pr.yml` blocks merge on any failed gate. On merge, `release.yml` builds once and tags `1.0.N` and `sha-<commit>`.
- The deploy jobs assume an AWS role by OIDC and ask SSM to run `deploy-app.sh deploy <image>` on the instance.
- The instance runs one container (`--read-only`, caps dropped, memory and CPU limited) whose logs go to CloudWatch through the `awslogs` driver.
- Locally, Compose runs the same image next to the monitoring stack. In Kubernetes the same image runs as two or more pods behind a Service.

## 4. CI/CD in detail

PR workflow, parallel jobs: Python (ruff + pytest with a coverage floor of 90%), Hadolint, ShellCheck + script tests, config validation (terraform fmt/validate, kubeconform, promtool, compose config), and an image job (build, size, Trivy). The Trivy gate uses `--ignore-unfixed` and fails on CRITICAL only: it blocks what you can actually fix by upgrading, and HIGH is reported but not blocking so the pipeline is not permanently red.

Release workflow: re-verify, `docker buildx` for amd64 and arm64 with the GitHub Actions cache (`type=gha,mode=max`), push, SBOM and provenance on. Version = `VERSION` (MAJOR.MINOR) + run number. Deploy staging, then production behind an environment approval. `concurrency: release` with no cancellation means two merges never deploy simultaneously and a deploy is never killed halfway.

Why deploy jobs are guarded by `AWS_DEPLOY_ENABLED`: the pipeline should be usable (build, scan, publish) before any cloud account exists. Be ready to say that it is a convenience for this assessment.

## 5. How deployment rollback works

On the host, `deploy-app.sh deploy <image>`:

1. Reads the current image from `/var/lib/app/current_image`.
2. Pulls the new image, replaces the container, polls `http://localhost:<port>/health` for 60 seconds.
3. If healthy: records old as `previous`, new as `current`, exits 0.
4. If not: restarts the previous image. Exit 1 if that worked (release did not go out), 2 if there was nothing to roll back to, 4 if the rollback failed too.

`ssm_deploy.sh` sends the command, polls SSM for completion, passes the exit code through (5 if SSM itself failed or timed out), and validates the image string against a strict regex before it goes into a remote shell command. The test `tests/test_ssm_deploy.sh` covers each exit path with a fake `aws` binary: that is a logic test, not an AWS test.

Honest limit: one instance means the container is replaced, so there is a few-seconds gap. Kubernetes (`maxUnavailable: 0`) or ECS/ALB removes it.

## 6. Terraform

- `bootstrap/`: S3 state bucket (versioned, encrypted, public access blocked) and the account-wide GitHub OIDC provider. Local state, because a bucket cannot hold the state that creates it.
- `modules/app_host`: EC2 (IMDSv2 required, encrypted gp3), security group with one ingress rule per allowed CIDR and no SSH, IAM role with `logs:CreateLogStream/PutLogEvents` on one log group plus the managed SSM policy, instance profile, log group with retention, cloud-init that installs Docker and drops `deploy-app.sh` and env files.
- `modules/github_deploy_role`: role assumable only by `repo:<owner>/<repo>:environment:<env>`, allowed only `ssm:SendCommand` on one instance and the `AWS-RunShellScript` document, plus `GetCommandInvocation` (which does not support resource scoping).
- `environments/*`: thin roots; different instance size, retention and state key. Separate directories rather than workspaces so state and variables can not be mixed up.
- Status: `fmt` checked; `validate`, `plan`, `apply` **not run** (provider download blocked, no credentials).

## 7. Kubernetes availability

- Two replicas minimum, spread by the scheduler; PDB keeps one up during node drains.
- Rolling update with `maxUnavailable: 0`: new pod must be Ready before an old one goes. Readiness gates traffic; liveness restarts a wedged process.
- `preStop` sleep handles the endpoint-removal/SIGTERM race; uvicorn then drains in-flight requests.
- HPA scales on CPU (70% of the 50m request, 2 to 5), with a 120s scale-down stabilisation so it does not flap.
- A bad release (e.g. invalid config) leaves old pods serving because new ones never become Ready; `rollout undo` restores the previous ReplicaSet.
- Status: manifests pass kubeconform. Cluster demo **not run**; `scripts/k8s_demo.sh` does it.

## 8. How metrics and logs reach Grafana

Metrics: the app exposes `/metrics`; Prometheus scrapes it, Node Exporter and cAdvisor every 15s over the internal network; Grafana queries Prometheus with PromQL. Retention is 15 days or 4 GB.

Logs: the app writes JSON to stdout; Docker's json-file driver stores it; Alloy discovers containers through the Docker socket, streams the logs, parses the app's JSON, promotes `level` to a label, keeps `route`, `path`, `method`, `status`, `duration_ms` as structured metadata, and pushes to Loki. Grafana queries Loki with LogQL. Loki deletes data after 7 days (the compactor must have retention enabled, which is easy to forget).

Cardinality answer: index only bounded values (container, service, level). Unbounded ones such as raw path or duration would create one stream per distinct value and hurt Loki; structured metadata keeps them filterable without indexing.

## 9. How alerting works

Prometheus evaluates the rules every 15s. A rule whose expression is true enters `pending`; after `for` it becomes `firing`. The `for` durations prevent single-scrape noise. Rules are unit-tested with `promtool test rules`. There is no Alertmanager, so firing alerts are visible in Prometheus and the dashboard table but not delivered; that is a stated gap.

Thresholds (the reasoning is in the README table): down for 1m; 5xx over 5% for 5m with a minimum traffic floor; disk over 80% for 10m, computed like `df`; container memory working set over 90% of its limit for 5m.

## 10. The health script

`system_health.sh` reads `/proc/stat` twice (CPU over a window), `/proc/meminfo` (used = total minus available, so cache does not count), `df` for real filesystems, `/proc/loadavg`, and `ps` sorted by memory. Thresholds are flags; critical is threshold + offset (default 10). It appends to a log, rotating by size, and returns 0/1/2 (3 for usage errors) so cron or a monitor can act on it. `--json` gives one object per run and sends warnings to stderr so stdout stays parseable. A systemd timer (or cron entry with `flock`) runs it every 5 minutes. Tested by `tests/test_system_health.sh`.

## 11. Important security decisions

- No secrets in git; Grafana password required from `.env`; OIDC and instance roles instead of keys.
- No SSH; SSM only. IMDSv2 required. The app port is open only to CIDRs you choose.
- Non-root, read-only containers with capabilities dropped, in Compose, on EC2 and in Kubernetes.
- Trivy gate, pinned images and SHA-pinned actions, Dependabot.
- The Docker socket mount for Alloy is the biggest privilege in the repo. Be ready to explain: even `:ro` does not limit the API, it is root-equivalent, mitigated by non-root user, internal network, and that production should use a log driver or socket proxy instead.
- cAdvisor is not `privileged`; it gets read-only mounts only.

## 12. Likely questions and short answers

- *Why not `latest`?* It is mutable; rollback and audits become guesses.
- *Why SSM over SSH?* No open port, no keys, IAM-audited.
- *How do you do zero downtime on EC2?* You don't with one instance; two behind an ALB with rolling replace, or ECS. Say it plainly.
- *What breaks if Prometheus restarts?* The volume keeps data; a gap in scrapes of a few seconds.
- *Why 5xx only in the error counter?* 4xx are client mistakes; counting them would turn a scanner into an outage.
- *What would you do first with more time?* Run everything end to end on real infrastructure and add Alertmanager.
- *What did you not run?* Image build, kind demo, `terraform validate/plan/apply`, Grafana rendering. All listed in the README's verification table.
