#!/usr/bin/env bash
set -euo pipefail

# copy over /etc/kubernetes/drain-kubeconfig manually

KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

if [ -f "$KUBELET_CONFIG" ]; then
  # Remove existing entries if present to prevent duplicates
  sed -i '/^shutdownGracePeriod:/d' "$KUBELET_CONFIG"
  sed -i '/^shutdownGracePeriodCriticalPods:/d' "$KUBELET_CONFIG"

  # Append the configured settings
  cat << 'EOF' >> "$KUBELET_CONFIG"
shutdownGracePeriod: 180s
shutdownGracePeriodCriticalPods: 20s
EOF

  # Restart kubelet to load the updated configuration
  systemctl restart kubelet
  echo "Updated $KUBELET_CONFIG and restarted kubelet."
else
  echo "Warning: $KUBELET_CONFIG not found. Skipped updating kubelet config."
fi

# Ensure target directories exist
mkdir -p /opt/bin
mkdir -p /etc/systemd/system
mkdir -p /etc/kubernetes
mkdir -p /etc/systemd/logind.conf.d

# 1. /opt/bin/k8s-drain.sh
cat << 'EOF' > /opt/bin/k8s-drain.sh
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

log "Draining app workloads on ${NODE_NAME}..."
kubectl drain "${NODE_NAME}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=15 \
  --pod-selector='app.kubernetes.io/part-of!=rook-ceph,app!=rook-ceph-operator' \
  --timeout="${DRAIN_TIMEOUT}" || log "App drain completed with warnings"

log "Draining ${NODE_NAME} (timeout ${DRAIN_TIMEOUT})"
if kubectl drain "${NODE_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --disable-eviction=true \
    --grace-period=30 \
    --timeout="${DRAIN_TIMEOUT}"; then
  log "Drain completed successfully"
else
  log "Drain failed or timed out — continuing shutdown anyway"
fi
EOF
chmod 0755 /opt/bin/k8s-drain.sh
chown root:root /opt/bin/k8s-drain.sh


# 2. /opt/bin/k8s-uncordon.sh
cat << 'EOF' > /opt/bin/k8s-uncordon.sh
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
EOF
chmod 0755 /opt/bin/k8s-uncordon.sh
chown root:root /opt/bin/k8s-uncordon.sh


# 3. /opt/bin/k8s-shutdown-watcher.sh
cat << 'EOF' > /opt/bin/k8s-shutdown-watcher.sh
#!/usr/bin/env bash
set -uo pipefail

# Prevent systemd-inhibit from marking the service as failed (status 141) on SIGPIPE
trap '' PIPE

LOG_TAG="k8s-shutdown-watcher"
log() { logger -t "$LOG_TAG" "$1"; echo "[$LOG_TAG] $1"; }

log "Holding shutdown inhibitor, watching for PrepareForShutdown"

busctl monitor org.freedesktop.login1 2>/dev/null | \
while read -r line; do
  if [[ "$line" == *"Member=PrepareForShutdown"* ]]; then
    while read -r payload_line; do
      if [[ "$payload_line" == *"BOOLEAN true;"* ]]; then
        log "Shutdown requested, running drain before releasing inhibitor"
        /opt/bin/k8s-drain.sh
        log "Drain step done, releasing inhibitor"
        exit 0
      elif [[ "$payload_line" == *"BOOLEAN false;"* ]]; then
        break
      fi
    done
  fi
done
EOF
chmod 0755 /opt/bin/k8s-shutdown-watcher.sh
chown root:root /opt/bin/k8s-shutdown-watcher.sh


# 4. /etc/systemd/system/k8s-node-drain.service
cat << 'EOF' > /etc/systemd/system/k8s-node-drain.service
[Unit]
Description=Hold shutdown inhibitor and drain Kubernetes node before shutdown/reboot
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd-inhibit.html
After=network-online.target kubelet.service
Wants=network-online.target

[Service]
Type=simple
# systemd-inhibit takes the "delay" lock for the whole life of the wrapped
# process. As long as this is running, logind PAUSES the actual shutdown
# (before any container scopes start getting torn down) until either the
# watcher exits (drain done) or InhibitDelayMaxSec elapses.
ExecStart=/usr/bin/systemd-inhibit --what=shutdown --mode=delay \
  --who=k8s-drain --why="Drain node before shutdown" \
  /opt/bin/k8s-shutdown-watcher.sh
Restart=no
Environment=KUBECONFIG=/etc/kubernetes/drain-kubeconfig

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/k8s-node-drain.service
chown root:root /etc/systemd/system/k8s-node-drain.service


# 5. /etc/systemd/system/k8s-node-uncordon.service
cat << 'EOF' > /etc/systemd/system/k8s-node-uncordon.service
[Unit]
Description=Remove shutdown taint and uncordon Kubernetes node after boot
After=network-online.target kubelet.service
Wants=network-online.target
Requires=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/bin/k8s-uncordon.sh
Environment=KUBECONFIG=/etc/kubernetes/drain-kubeconfig

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/k8s-node-uncordon.service
chown root:root /etc/systemd/system/k8s-node-uncordon.service


# 6. /etc/systemd/logind.conf.d/zz-k8s-drain-logind.conf
cat << 'EOF' > /etc/systemd/logind.conf.d/zz-k8s-drain-logind.conf
[Login]
# Filename starts with 'z' specifically so it sorts and loads after any
# numerically-prefixed drop-in (e.g. Kubespray's 99-kubelet.conf), which
# would otherwise silently win regardless of what we set here.
#
# Must stay >= kubelet's own shutdownGracePeriod (currently 180s in
# /var/lib/kubelet/config.yaml) or logind will force shutdown through
# before kubelet's own critical-pod window even finishes.
InhibitDelayMaxSec=200
EOF
chmod 0644 /etc/systemd/logind.conf.d/zz-k8s-drain-logind.conf
chown root:root /etc/systemd/logind.conf.d/zz-k8s-drain-logind.conf


# Note: You must ensure /etc/kubernetes/drain-kubeconfig exists on the node
# and set permissions manually via:
# chmod 0600 /etc/kubernetes/drain-kubeconfig && chown root:root /etc/kubernetes/drain-kubeconfig

# Apply systemd configurations
systemctl restart systemd-logind
systemctl daemon-reload
systemctl enable --now k8s-node-drain.service
systemctl enable --now k8s-node-uncordon.service

systemctl status k8s-node-uncordon
systemctl status k8s-node-drain.service