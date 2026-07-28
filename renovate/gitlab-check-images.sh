#!/bin/bash

set -e

docker run --rm \
  -e LOG_LEVEL=debug \
  -v "/home/hpratt/Documents/kubespray/homelab_playbooks:/repo" \
  -w /repo \
  renovate/renovate:latest \
  --platform=local \
  --dry-run=full 2>&1 | tee renovate-debug.log