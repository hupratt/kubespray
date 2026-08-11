#!/usr/bin/env bash
set -Eeuo pipefail

NODE="$(hostname -s)"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-10m}"

log() {
    echo "[$(date --iso-8601=seconds)] $*"
}

log "Starting Kubernetes drain for ${NODE}"

kubectl get node "${NODE}" >/dev/null

log "Cordoning ${NODE}"
kubectl cordon "${NODE}"

log "Draining ${NODE}"

kubectl drain "${NODE}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=60 \
    --timeout="${DRAIN_TIMEOUT}"

log "Successfully drained ${NODE}"