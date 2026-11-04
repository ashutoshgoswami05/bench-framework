#!/usr/bin/env bash

set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"

DEST="$REPO/latex/redacted"  #redacting the compose file for seaweed-fs can be worked on any file reduces chances of manual error for the credentials


#uses sed line replacer to replace the credentails removes matcher wherever it is mentioned anything related to access /secret_key

mkdir -p "$DEST"
rm -f "$DEST"/*

redact () {
  sed -E \
    -e 's/((access|secret)_key:)[[:space:]]*.*/\1 "<REDACTED>"/I' \
    -e 's/("(access|secret)Key":)[[:space:]]*"[^"]*"(,?)/\1 "<REDACTED>"\3/' \
    -e 's/(bearer_token:)[[:space:]]*.*/\1 "<REDACTED>"/' \
    -e 's/((rpc_secret|admin_token|metrics_token)[[:space:]]*=).*/\1 "<REDACTED>"/' \
    -e 's/((PASSWORD|SECRET_KEY|ACCESS_KEY|ROOT_USER)=).*/\1<REDACTED>/' \
    "$1"
}


copy () {
  redact "$REPO/$1" > "$DEST/$2"
}

extract () {
  local source="$1" dest="$2"

  cp "$REPO/$source" "$DEST/$dest"
  redact "$DEST/$dest" > "$DEST/${dest}.tmp"
  mv "$DEST/${dest}.tmp" "$DEST/$dest"


copy infra/seaweedfs/docker-compose.yml compose-seaweedfs.yml
copy infra/seaweedfs/s3.json seaweedfs-s3.json

