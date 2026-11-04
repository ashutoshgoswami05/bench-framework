#!/usr/bin/env bash

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

echo
echo "=== ceph s3 user  $(date -u +%H:%M:%S)"
cd "$REPO/infra/ceph" || exit 1
docker compose up -d >/dev/null 2>&1
for _ in $(seq 1 48); do
  [ "$(docker inspect --format '{{.State.Health.Status}}' ceph-rgw 2>&1)" = "healthy" ] && break  #checking health status for ceph
  sleep 10
done

if docker exec ceph-rgw radosgw-admin user info --uid=thesisuser >/dev/null 2>&1; then
  echo "thesisuser already exists"
else
  docker exec ceph-rgw radosgw-admin user create --uid=thesisuser \
    --display-name="Thesis Test User" \
    --access-key=thesiscephaccess --secret-key=thesiscephsecret123 >/dev/null 2>&1 &&
    echo "thesisuser created"
fi
docker exec ceph-rgw ceph health 2>&1 | tail -1
docker exec ceph-rgw radosgw-admin gc process --include-all >/dev/null 2>&1
docker compose down >/dev/null 2>&1
cd "$REPO" || exit 1

echo
echo "=== fidelity suite  $(date -u +%H:%M:%S)"
bash tests/run_fidelity_all.sh

echo
echo "=== plain campaign  $(date -u +%H:%M:%S)"
bash bench/run_all_backends.sh linux_campaign.csv

echo
echo "=== monitoring stack  $(date -u +%H:%M:%S)"
cd "$REPO/monitoring" || exit 1
docker compose up -d 2>&1 | tail -2
cd "$REPO" || exit 1
sleep 30 # wait to start the monitoring stack and then ping on the localhost to check if it is ready

echo -n "prometheus ready: "
curl -s http://localhost:9090/-/ready || echo "NOT READY"
echo

echo "=== instrumented pass  $(date -u +%H:%M:%S)"
bash bench/run_monitored.sh 5

echo
echo "=== pull metrics  $(date -u +%H:%M:%S)"
.venv/bin/python analysis/pull_metrics.py 2>&1 | tail -12

echo
echo "=== row counts"
for f in bench/results/linux_campaign.csv \
         bench/results/monitoring_benchmark_results.csv \
         bench/results/resource_usage.csv \
         tests/results/compatibility_matrix1.csv; do
  [ -f "$f" ] && echo "$(tail -n +2 "$f" | wc -l) rows  $f"
done

echo
echo
echo "=== done at $(date -u +%H:%M:%S)"
