# Dashboard screenshots

No screenshots are committed yet. Grafana could not be run in the environment where this repository was prepared, and I do not include images I did not capture.

## Capture them

On a Linux machine with Docker:

```bash
cp .env.example .env     # set GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD, DOCKER_GID
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
# traffic, including some 404s and, with ENABLE_FAULT_INJECTION=true, 500s
for i in $(seq 1 300); do curl -s localhost:8080/ >/dev/null; curl -s localhost:8080/nope >/dev/null; done
for i in $(seq 1 60); do curl -s localhost:8080/fault >/dev/null; sleep 0.5; done
```

Then either run `make screenshots` (uses Playwright; see `scripts/capture_screenshots.py`) or take them by hand at http://localhost:3000, time range "Last 15 minutes":

| File | Dashboard | URL path |
|---|---|---|
| `application.png` | Application, with the logs panel visible during the error spike | `/d/app-overview` |
| `host.png` | Host | `/d/host-overview` |
| `containers.png` | Containers (cAdvisor data appears only on a Linux Docker host) | `/d/containers-overview` |

Wait at least two minutes after start-up so rate and percentile panels have data.
