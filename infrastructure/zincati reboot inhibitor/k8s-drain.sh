#!/usr/bin/env bash
#
# Cordon + taint + drain this node. Meant to be called from
# k8s-node-drain.service's ExecStop as the system is going down.
set -euo pipefail

NODE_NAME="${NODE_NAME:-$(hostname)}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/drain-kubeconfig}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120s}"
TAINT_KEY="${TAINT_KEY:-homelab.io/shutting-down}"
TAINT="${TAINT_KEY}=true:NoSchedule"
LOG_TAG="k8s-drain"

log() { logger -t "$LOG_TAG" "$1"; echo "[$LOG_TAG] $1"; }

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found on PATH, skipping drain"
  exit 0
fi

if [ ! -r "$KUBECONFIG" ]; then
  log "kubeconfig ${KUBECONFIG} not readable, skipping drain"
  exit 0
fi

# If the API server is already unreachable (e.g. this IS the last node,
# or network is already down), don't hang the shutdown forever.
if ! timeout 10s kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
  log "API server unreachable, skipping drain"
  exit 0
fi

log "Tainting ${NODE_NAME} (${TAINT}) before shutdown"
kubectl taint nodes "${NODE_NAME}" "${TAINT}" --overwrite || \
  log "taint apply failed, continuing anyway"

log "Draining ${NODE_NAME} (timeout ${DRAIN_TIMEOUT})"
if kubectl drain "${NODE_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=30 \
    --timeout="${DRAIN_TIMEOUT}"; then
  log "Drain completed successfully"
else
  log "Drain failed or timed out — continuing shutdown anyway"
fi
