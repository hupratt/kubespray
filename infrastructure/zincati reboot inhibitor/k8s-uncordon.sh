#!/usr/bin/env bash
#
# Remove the shutdown taint and uncordon this node after boot.
set -euo pipefail

NODE_NAME="${NODE_NAME:-$(hostname)}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/drain-kubeconfig}"
TAINT_KEY="${TAINT_KEY:-homelab.io/shutting-down}"
WAIT_RETRIES="${WAIT_RETRIES:-24}"   # 24 * 5s = 2 minutes
LOG_TAG="k8s-uncordon"

log() { logger -t "$LOG_TAG" "$1"; echo "[$LOG_TAG] $1"; }

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not found on PATH, skipping uncordon"
  exit 0
fi

if [ ! -r "$KUBECONFIG" ]; then
  log "kubeconfig ${KUBECONFIG} not readable, skipping uncordon"
  exit 0
fi

# Wait for the API server (and this node's kubelet registration) to be reachable.
i=0
until kubectl get node "${NODE_NAME}" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge "$WAIT_RETRIES" ]; then
    log "API server / node still unreachable after $((WAIT_RETRIES * 5))s, giving up"
    exit 0
  fi
  sleep 5
done

log "Removing taint ${TAINT_KEY} from ${NODE_NAME} (if present)"
kubectl taint nodes "${NODE_NAME}" "${TAINT_KEY}:NoSchedule-" || \
  log "taint removal reported an issue (may simply not have existed)"

log "Uncordoning ${NODE_NAME}"
kubectl uncordon "${NODE_NAME}" || log "uncordon failed"
