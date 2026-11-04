#!/usr/bin/env bash

set -u
PASSES=${1:-10}
REPEATS=${2:-15}
START=${3:-1}
RESET_EVERY=${4:-5}
LAST=$((START + PASSES - 1))
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
PY="$REPO/.venv/bin/python"

echo "=== $PASSES instrumented passes ($START to $((START + PASSES - 1))), $REPEATS repeats each  $(date -u +%H:%M:%S)"

echo "=== monitoring stack"
cd "$REPO/monitoring" || exit 1
docker compose up -d 2>&1 | tail -3
cd "$REPO" || exit 1

sleep 30 #same in run_repeats but here only monitoring stack is up to get the metrics
echo -n "prometheus ready: "
curl -s http://localhost:9090/-/ready || echo "NOT READY"
echo
echo -n "targets up: "
curl -s 'http://localhost:9090/api/v1/targets?state=active' |
  grep -o '"health":"up"' | wc -l

for i in $(seq "$START" $((START + PASSES - 1))); do
  n=$(printf '%02d' "$i")
  echo
  echo "=== resource pass $n of $PASSES   $(date -u +%H:%M:%S)"
  bash bench/run_monitored.sh "$REPEATS" 2>&1
  #for every run it genratates resource_usage.csv copying it number wise for particular run
  "$PY" analysis/pull_metrics.py 2>&1 | tail -2
  cp bench/results/resource_usage.csv     "bench/results/resource_usage_$n.csv"
  cp bench/results/monitoring_windows.csv "bench/results/monitoring_windows_$n.csv"


  cd "$REPO/infra/ceph" || exit 1
  docker compose up -d >/dev/null 2>&1
  for _ in $(seq 1 48); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' ceph-rgw 2>&1)" = "healthy" ] && break
    sleep 10
  done
  docker exec ceph-rgw radosgw-admin gc process --include-all >/dev/null 2>&1
  used=$(docker exec ceph-rgw ceph df 2>/dev/null)
  
  echo "ceph osd after gc: ${used:-?}% used"
  docker compose down >/dev/null 2>&1
  cd "$REPO" || exit 1
  case "$used" in
    ''|*[!0-9.]*) : ;;
    *) if [ "${used%%.*}" -ge 85 ]; then
         echo "ABORTING: ceph osd at ${used}% -- later passes would be invalid"
         break
       fi ;;
  esac

  if [ "$RESET_EVERY" -gt 0 ] && [ $((i % RESET_EVERY)) -eq 0 ] && [ "$i" -lt "$LAST" ]; then
    bash "$REPO/linux/reset_volumes.sh" "after pass $n" || exit 1
  fi
done

echo "=== done at $(date -u +%H:%M:%S)"
