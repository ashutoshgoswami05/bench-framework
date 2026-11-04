#!/usr/bin/env bash

set -u
REPEATS=${1:-15}
RESET_EVERY=${2:-5}
LAST=$REPEATS
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
PY="$REPO/.venv/bin/python"

ceph_up () {
  cd "$REPO/infra/ceph" || return 1
  docker compose up -d >/dev/null 2>&1
  for _ in $(seq 1 48); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' ceph-rgw 2>&1)" = "healthy" ] && return 0
    sleep 10
  done
  return 1
}

echo
echo "=== ceph s3 user"
if ceph_up; then
  if docker exec ceph-rgw radosgw-admin user info --uid=thesisuser >/dev/null 2>&1; then
    echo "thesisuser already exists"
  else
    docker exec ceph-rgw radosgw-admin user create --uid=thesisuser \
      --display-name="Thesis Test User" \
      --access-key=thesiscephaccess --secret-key=thesiscephsecret123 >/dev/null 2>&1 &&
      echo "thesisuser created"
  fi
  docker exec ceph-rgw ceph health 2>&1 | tail -1
else
  echo "WARNING: ceph did not become healthy; its runs will fail"
fi
cd "$REPO/infra/ceph" && docker compose down >/dev/null 2>&1
cd "$REPO" || exit 1

echo
echo "=== fidelity suite (once)"
bash tests/run_fidelity_all.sh 2>&1 

for i in $(seq 1 "$REPEATS"); do
  n=$(printf '%02d' "$i")
  echo
  echo "=== campaign $n of $REPEATS   $(date -u +%H:%M:%S)"
  bash bench/run_all_backends.sh "campaign_$n.csv" 2>&1

  rows=$(tail -n +2 "bench/results/campaign_$n.csv" 2>/dev/null | wc -l)

  if ceph_up; then
    docker exec ceph-rgw radosgw-admin gc process --include-all >/dev/null 2>&1
    used=$(docker exec ceph-rgw ceph df 2>/dev/null)
    echo "ceph osd after gc: ${used:-?}% used"
    cd "$REPO/infra/ceph" && docker compose down >/dev/null 2>&1
    cd "$REPO" || exit 1
    case "$used" in
      ''|*[!0-9.]*) : ;;
      *) if [ "${used%%.*}" -ge 85 ]; then  #more than 85per space used it might crash
           echo "ABORTING: ceph osd at ${used}% -- later runs would be invalid"
           break
         fi ;;
    esac
  fi
  echo "disk: $(df -h "$REPO" | awk 'NR==2{print $4" free"}')"  #/dev/sda1  printing the space left after the run

  if [ "$RESET_EVERY" -gt 0 ] && [ $((i % RESET_EVERY)) -eq 0 ] && [ "$i" -lt "$LAST" ]; then
    bash "$REPO/linux/reset_volumes.sh" "after campaign $n" || exit 1
  fi
done

echo
echo "=== monitoring stack"
cd "$REPO/monitoring" || exit 1
docker compose up -d 2>&1 | tail -2
cd "$REPO" || exit 1
sleep 30
echo -n "prometheus ready: "
curl -s http://localhost:9090/-/ready || echo "NOT READY"
echo

echo "=== instrumented pass (once)"
bash bench/run_monitored.sh 5 2>&1 | grep -E "^===|Results written" | tail -12
"$PY" analysis/pull_metrics.py 2>&1 | tail -3

echo
echo "=== row counts"
for f in bench/results/campaign_*.csv; do
  [ -f "$f" ] && echo "$(tail -n +2 "$f" | wc -l) rows  $(basename "$f")"
done
echo "$(tail -n +2 bench/results/monitoring_benchmark_results.csv 2>/dev/null | wc -l) rows  monitoring_benchmark_results.csv"

echo
echo "=== done at $(date -u +%H:%M:%S)"
