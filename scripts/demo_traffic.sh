#!/usr/bin/env bash
# Generate steady traffic against the local app so every Grafana panel has data,
# including 404s and (with ENABLE_FAULT_INJECTION=true) 500s from /fault.
#
# Runs for DURATION seconds (default 420). The AppHighErrorRate alert needs the
# 5xx ratio above 5% for 5 minutes, so keep the default if you want the
# "Firing alerts" panel to show it. Take the screenshots while this is running
# or within a minute of it finishing (the dashboards use "Last 15 minutes").
#
#   ENABLE_FAULT_INJECTION=true in .env, then restart the app, before running.
set -euo pipefail

BASE="${BASE_URL:-http://localhost:8080}"
DURATION="${DURATION:-420}"

if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/fault")" != "500" ]; then
  echo "error: $BASE/fault did not return 500. Set ENABLE_FAULT_INJECTION=true in .env and run:" >&2
  echo "  docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --force-recreate app" >&2
  exit 1
fi

echo "sending traffic to $BASE for ${DURATION}s (Ctrl-C to stop)"
end=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$end" ]; do
  curl -s -o /dev/null "$BASE/"
  curl -s -o /dev/null "$BASE/"
  curl -s -o /dev/null "$BASE/nope"
  curl -s -o /dev/null "$BASE/fault"
  sleep 0.5
done
echo "done"
