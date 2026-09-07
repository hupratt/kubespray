#!/usr/bin/env bash
set -uo pipefail

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