#!/usr/bin/env bash

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "usage: bash bench/run_warp.sh <backend>" >&2
  exit 1
fi

BACKEND=$1
OUTDIR="$REPO/bench/results/warp"
mkdir -p "$OUTDIR"

case "$BACKEND" in
  rustfs)    HOST="rustfs:9000";            AK="thesisaccesskey";     SK="thesissecretkey1234";   REGION="us-east-1" ;;
  garage)    HOST="garage:3900";            AK="GKea1446f9810cbd0b8633f9a64361357d"; SK="4c1c9e2085c276979148580c92c4bd14a3fa554efc2ba7f72937d14ccbb4ed7c"; REGION="garage" ;;
  seaweedfs) HOST="seaweedfs-s3:8333";      AK="thesisseaweedaccess"; SK="thesisseaweedsecret123"; REGION="us-east-1" ;;
  juicefs)   HOST="juicefs-gateway:9090";   AK="thesisjuiceaccess";   SK="thesisjuicesecret123";  REGION="us-east-1" ;;
  minio)     HOST="minio:9000";             AK="thesisminioaccess";   SK="thesisminiosecret123";  REGION="us-east-1" ;;
  ceph)      HOST="ceph-rgw:8000";          AK="thesiscephaccess";    SK="thesiscephsecret123";   REGION="us-east-1" ;;
  *) echo "unknown backend: $BACKEND" >&2; exit 1 ;;
esac

EXTRA=""

if [ "$BACKEND" = "ceph" ]; then
  CEPH_IP=$(docker inspect ceph-rgw \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
  if [ -n "$CEPH_IP" ]; then
    HOST="$CEPH_IP:8000"
    echo "resolved ceph-rgw to $HOST (IP literal required by RGW)"
  fi
fi

echo "=== warp mixed: $BACKEND ($HOST) ==="
docker run --rm --network thesis-net minio/warp:latest mixed \
  --host="$HOST" \
  --access-key="$AK" \
  --secret-key="$SK" \
  --region="$REGION" \
  --objects=20 \
  --obj.size=16MiB \
  --concurrent=4 \
  --duration=30s \
  $EXTRA 2>&1 | tee "$OUTDIR/$BACKEND.txt"

echo "written to $OUTDIR/$BACKEND.txt"
