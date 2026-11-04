#!/usr/bin/env bash

set -eu

CLUSTER=ceph
MON_NAME=a
CONF="/etc/ceph/${CLUSTER}.conf"
ADMIN_KEYRING="/etc/ceph/${CLUSTER}.client.admin.keyring"
MON_KEYRING="/var/lib/ceph/tmp/${CLUSTER}.mon.keyring"
FSID_FILE="/var/lib/ceph/fsid"
MONMAP="/var/lib/ceph/tmp/monmap"

: "${OSD_SIZE:=40G}"
: "${POOL_SIZE:=1}"
: "${RGW_PORT:=8000}"

log () {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')  ceph-$ROLE: $*" >&2
}

my_ip () {
  local found
  found=$(hostname -i 2>/dev/null | tr ' ' '\n' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  if [ -z "$found" ]; then
    found=$(python3 -c 'import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("192.0.2.1", 9))
    print(s.getsockname()[0])
finally:
    s.close()' 2>/dev/null)
  fi
  echo "$found"
}

require_ip () {
  local value
  value=$(my_ip)
  if [ -z "$value" ]; then
    log "could not determine this container's IPv4 address on thesis-net"
    log "tried 'hostname -i' and a python3 socket; neither returned one"
    exit 1
  fi
  echo "$value"
}

to_bytes () {
  case "$1" in
    *G|*g) echo $(( ${1%[Gg]} * 1024 * 1024 * 1024 )) ;;
    *M|*m) echo $(( ${1%[Mm]} * 1024 * 1024 )) ;;
    *)     echo "$1" ;;
  esac
}

wait_for_mon () {
  for _ in $(seq 1 60); do
    if ceph --connect-timeout 5 -s >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  log "monitor did not answer within 5 minutes"
  return 1
}

bootstrap_cluster () {
  local fsid ip
  ip=$(require_ip)
  if [ -s "$FSID_FILE" ]; then
    fsid=$(cat "$FSID_FILE")
    log "resuming an unfinished bootstrap of $fsid at $ip"
  else
    fsid=$(uuidgen)
    echo "$fsid" > "$FSID_FILE"
    log "bootstrapping cluster $fsid at $ip"
  fi

  cat > "$CONF" <<ENDCONF
[global]
fsid = $fsid
mon initial members = ${MON_NAME}
mon host = v2:${ip}:3300/0,v1:${ip}:6789/0
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
auth_allow_insecure_global_id_reclaim = false
osd crush chooseleaf type = 0
osd pool default size = ${POOL_SIZE}
osd pool default min size = 1
osd objectstore = bluestore
bluestore block size = $(to_bytes "$OSD_SIZE")
mon allow pool delete = true
mon data avail warn = 5
log to file = false
log to stderr = true

[client.rgw.${MON_NAME}]
rgw frontends = beast port=${RGW_PORT}
rgw thread pool size = 128
ENDCONF

  if [ ! -f "$MON_KEYRING" ]; then
    ceph-authtool --create-keyring "$MON_KEYRING" \
      --gen-key -n mon. --cap mon 'allow *'
  fi
  if [ ! -f "$ADMIN_KEYRING" ]; then
    ceph-authtool --create-keyring "$ADMIN_KEYRING" \
      --gen-key -n client.admin \
      --cap mon 'allow *' --cap osd 'allow *' \
      --cap mds 'allow *' --cap mgr 'allow *'
  fi
  ceph-authtool "$MON_KEYRING" --import-keyring "$ADMIN_KEYRING"

  monmaptool --create --clobber \
    --addv "$MON_NAME" "[v2:${ip}:3300,v1:${ip}:6789]" \
    --fsid "$fsid" "$MONMAP"

  mkdir -p "/var/lib/ceph/mon/${CLUSTER}-${MON_NAME}"
  chown -R ceph:ceph /var/lib/ceph /etc/ceph
  sudo -u ceph ceph-mon --mkfs -i "$MON_NAME" \
    --monmap "$MONMAP" --keyring "$MON_KEYRING"
  log "monitor store created"
}

refresh_mon_address () {
  local ip fsid
  ip=$(require_ip)
  fsid=$(cat "$FSID_FILE")
  if grep -q "v2:${ip}:3300" "$CONF"; then
    log "monitor address unchanged at $ip"
    return 0
  fi
  log "monitor address changed to $ip, rewriting monmap"
  sed -i "s|^mon host = .*|mon host = v2:${ip}:3300/0,v1:${ip}:6789/0|" "$CONF"
  monmaptool --create --clobber \
    --addv "$MON_NAME" "[v2:${ip}:3300,v1:${ip}:6789]" \
    --fsid "$fsid" "$MONMAP"
  chown ceph:ceph "$MONMAP"
  sudo -u ceph ceph-mon -i "$MON_NAME" --inject-monmap "$MONMAP"
}

run_mon () {
  mkdir -p /var/lib/ceph/tmp
  if [ -f "/var/lib/ceph/mon/${CLUSTER}-${MON_NAME}/keyring" ]; then
    refresh_mon_address
  else
    bootstrap_cluster
  fi
  chown -R ceph:ceph /var/lib/ceph /etc/ceph
  log "starting ceph-mon"
  exec ceph-mon -f -i "$MON_NAME" --setuser ceph --setgroup ceph
}

run_mgr () {
  wait_for_mon
  local dir="/var/lib/ceph/mgr/${CLUSTER}-${MON_NAME}"
  if [ ! -f "$dir/keyring" ]; then
    log "registering mgr.${MON_NAME}"
    mkdir -p "$dir"
    ceph auth get-or-create "mgr.${MON_NAME}" \
      mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
      -o "$dir/keyring"
  fi
  chown -R ceph:ceph "$dir"
  log "starting ceph-mgr"
  exec ceph-mgr -f -i "$MON_NAME" --setuser ceph --setgroup ceph
}

run_osd () {
  wait_for_mon
  local dir="/var/lib/ceph/osd/${CLUSTER}-0"
  if [ ! -f "$dir/keyring" ]; then
    local uuid id
    uuid=$(uuidgen)
    id=$(ceph osd new "$uuid")
    log "created osd.$id ($uuid), BlueStore on a ${OSD_SIZE} file"
    mkdir -p "$dir"
    ceph auth get-or-create "osd.$id" \
      mon 'allow profile osd' mgr 'allow profile osd' osd 'allow *' \
      -o "$dir/keyring"
    chown -R ceph:ceph "$dir"
    sudo -u ceph ceph-osd -i "$id" --mkfs --osd-uuid "$uuid"
    ceph config set global osd_pool_default_size "$POOL_SIZE" || true
  fi
  chown -R ceph:ceph "$dir"
  log "starting ceph-osd"
  exec ceph-osd -f -i 0 --setuser ceph --setgroup ceph
}

run_rgw () {
  wait_for_mon
  local dir="/var/lib/ceph/radosgw/${CLUSTER}-rgw.${MON_NAME}"
  if [ ! -f "$dir/keyring" ]; then
    log "registering client.rgw.${MON_NAME}"
    mkdir -p "$dir"
    ceph auth get-or-create "client.rgw.${MON_NAME}" \
      mon 'allow rw' osd 'allow rwx' mgr 'allow rw' \
      -o "$dir/keyring"
  fi
  chown -R ceph:ceph "$dir"
  for _ in $(seq 1 60); do
    if ceph --connect-timeout 5 osd stat 2>/dev/null | grep -qE '[1-9][0-9]* up'; then
      break
    fi
    sleep 5
  done
  log "starting radosgw on port ${RGW_PORT}"
  exec radosgw -f -n "client.rgw.${MON_NAME}" --setuser ceph --setgroup ceph
}

ROLE=${1:?usage: entrypoint.sh mon|mgr|osd|rgw}
case "$ROLE" in
  mon) run_mon ;;
  mgr) run_mgr ;;
  osd) run_osd ;;
  rgw) run_rgw ;;
  *)   echo "unknown role: $ROLE" >&2; exit 1 ;;
esac
