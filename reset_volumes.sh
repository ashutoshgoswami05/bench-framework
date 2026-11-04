#!/usr/bin/env bash

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL=${1:-}
cd "$REPO" || exit 1

echo "--- resetting volumes ${LABEL:+($LABEL) }$(date -u +%H:%M:%S)"

for name in rustfs garage seaweedfs juicefs minio ceph; do
  cd "$REPO/infra/$name" || continue
  docker compose down -v >/dev/null 2>&1 && echo "    wiped $name"
done
cd "$REPO" || exit 1
docker volume prune -f >/dev/null 2>&1
df -h "$REPO" | awk 'NR==2{print "    disk: "$4" free"}'

cd "$REPO/infra/ceph" || exit 1
docker compose up -d >/dev/null 2>&1
healthy=no
for _ in $(seq 1 48); do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' ceph-rgw 2>&1)" = "healthy" ]; then
    healthy=yes
    break
  fi
  sleep 10
done

if [ "$healthy" != "yes" ]; then
  echo "    WARNING: ceph did not become healthy; its runs will fail"
  cd "$REPO" || exit 1
  exit 1
fi

if docker exec ceph-rgw radosgw-admin user info --uid=thesisuser >/dev/null 2>&1; then
  echo "    thesisuser already present"
else
  docker exec ceph-rgw radosgw-admin user create --uid=thesisuser \
    --display-name="Thesis Test User" \
    --access-key=thesiscephaccess --secret-key=thesiscephsecret123 >/dev/null 2>&1 &&
    echo "    thesisuser created"
fi
docker exec ceph-rgw ceph health 2>&1 | sed 's/^/    /'
docker compose down >/dev/null 2>&1
cd "$REPO" || exit 1

mkdir -p bench/results
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  volumes reset  ${LABEL:-manual}"
} >> bench/results/NOTE_volume_resets.txt

echo "--- reset done $(date -u +%H:%M:%S)"
