#!/bin/bash

set -e

docker run --rm \
  -e LOG_LEVEL=debug \
  -v "/home/hugo/Documents/Dev/kubespray/homelab_playbooks:/repo" \
  -w /repo \
  renovate/renovate:latest \
  --platform=local \
  --dry-run=full 2>&1 | tee renovate-debug.log

# docker run --rm \
#   -v "/home/hugo/Documents/Dev/kubespray/homelab_playbooks:/repo" \
#   -w /repo \
#   alpine \
#   sh -c 'find . -maxdepth 3 -type f | sort | head -200'


# docker run --rm \
#   -v "/home/hugo/Documents/Dev/kubespray/homelab_playbooks:/repo" \
#   -w /repo \
#   renovate/renovate:latest \
#   ls -la