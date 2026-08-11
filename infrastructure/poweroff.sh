#!/usr/bin/env bash
set -Eeuo pipefail

NODE="$(hostname -s)"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-10m}"

log() {
    echo "[$(date --iso-8601=seconds)] $*"
}

log "Starting graceful Kubernetes shutdown for node: ${NODE}"

# Make sure kubectl can reach the cluster
if ! kubectl get node "${NODE}" >/dev/null 2>&1; then
    log "ERROR: Cannot access Kubernetes node ${NODE}"
    exit 1
fi

log "Cordon node ${NODE}"
kubectl cordon "${NODE}"

log "Draining node ${NODE}..."
kubectl drain "${NODE}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=60 \
    --timeout="${DRAIN_TIMEOUT}"

log "Node ${NODE} successfully drained."

log "Waiting for non-DaemonSet pods to disappear..."

kubectl wait \
    --for=delete \
    --all \
    --all-namespaces \
    --timeout=120s \
    2>/dev/null || true

log "Kubernetes workloads drained successfully."
log "Shutting down ${NODE}..."

systemctl poweroff