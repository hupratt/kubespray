#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# k3s HA on Hetzner + Flux bootstrap (FIXED CNI + NETWORKING)
# =============================================================================

# --------------------------- CONFIG ------------------------------------------

HCLOUD_LOCATION="hel1"
SERVER_TYPE="cx23"
AGENT_TYPE="cx23"
OS_IMAGE="debian-12"

SSH_KEY_NAME="hpratt"

NETWORK_NAME="k3s-net"
NETWORK_CIDR="10.10.0.0/16"
SUBNET_CIDR="10.10.1.0/24"

PLACEMENT_GROUP="k3s-spread"

SERVER_COUNT=3
AGENT_COUNT=3

CLUSTER_NAME="k3s-ha"

K3S_VERSION="v1.36.0+k3s1"
K3S_TOKEN=""

# IMPORTANT: stable CNI config for Hetzner
K3S_EXTRA_ARGS="--flannel-backend=wireguard-native"

# Local
KUBECONFIG_PATH="${HOME}/.kube/${CLUSTER_NAME}.yaml"
SSH_KEY="${HOME}/.ssh/id_ed25519_adata"

# --------------------------- STATE ------------------------------------------

declare -a SERVER_IPS SERVER_PRIVS AGENT_IPS AGENT_PRIVS

LB_IP=""

# --------------------------- LOGGING ----------------------------------------

log()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

ssh_cmd() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no root@"$1" "$2"
}

wait_ssh() {
  local ip="$1"
  for _ in {1..30}; do
    ssh_cmd "$ip" "true" &>/dev/null && return 0
    sleep 5
  done
  die "SSH timeout: $ip"
}

# --------------------------- NETWORK DETECTION ------------------------------

detect_private_iface() {
  # usually eth1 on Hetzner
  ssh_cmd "$1" "ip route get 1.1.1.1 | awk '{print \$5; exit}'"
}

get_private_ip() {
  ssh_cmd "$1" "ip -4 addr show | awk '/inet 10\\./ {print \$2}' | cut -d/ -f1 | head -n1"
}

# --------------------------- PROVISION --------------------------------------

provision() {
  log "Provisioning infrastructure..."

  if [[ -z "$K3S_TOKEN" ]]; then
    K3S_TOKEN="$(openssl rand -hex 32)"
    log "Generated K3S_TOKEN $K3S_TOKEN"
  fi

  # network
  hcloud network describe "$NETWORK_NAME" &>/dev/null || {
    hcloud network create --name "$NETWORK_NAME" --ip-range "$NETWORK_CIDR"
    hcloud network add-subnet "$NETWORK_NAME" --type cloud --network-zone eu-central --ip-range "$SUBNET_CIDR"
  }

  # firewall
  FW="${CLUSTER_NAME}-fw"
  hcloud firewall describe "$FW" &>/dev/null || {
    hcloud firewall create --name "$FW"
    hcloud firewall add-rule "$FW" --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0
    hcloud firewall add-rule "$FW" --direction in --protocol tcp --port 6443 --source-ips 0.0.0.0/0
  }

  # LB
  LB="${CLUSTER_NAME}-lb"
  hcloud load-balancer describe "$LB" &>/dev/null || {
    hcloud load-balancer create --name "$LB" --type lb11 --location "$HCLOUD_LOCATION" --network "$NETWORK_NAME"
    hcloud load-balancer add-service "$LB" --protocol tcp --listen-port 6443 --destination-port 6443
  }

  LB_IP=$(hcloud load-balancer describe "$LB" -o json | jq -r '.public_net.ipv4.ip')

  # servers
  for i in $(seq 1 "$SERVER_COUNT"); do
    name="${CLUSTER_NAME}-server-$i"
    hcloud server create \
      --name "$name" \
      --type "$SERVER_TYPE" \
      --image "$OS_IMAGE" \
      --ssh-key "$SSH_KEY_NAME" \
      --network "$NETWORK_NAME" \
      --firewall "$FW" \
      --label "role=server" \
      --label "cluster=$CLUSTER_NAME" || true
  done

  # agents
  for i in $(seq 1 "$AGENT_COUNT"); do
    name="${CLUSTER_NAME}-agent-$i"
    hcloud server create \
      --name "$name" \
      --type "$AGENT_TYPE" \
      --image "$OS_IMAGE" \
      --ssh-key "$SSH_KEY_NAME" \
      --network "$NETWORK_NAME" \
      --firewall "$FW" \
      --label "role=agent" \
      --label "cluster=$CLUSTER_NAME" || true
  done

  # collect IPs
  for i in $(seq 1 "$SERVER_COUNT"); do
    name="${CLUSTER_NAME}-server-$i"
    SERVER_IPS+=($(hcloud server ip "$name"))
  done

  for i in $(seq 1 "$SERVER_COUNT"); do
    name="${CLUSTER_NAME}-server-$i"
    SERVER_PRIVS+=($(hcloud server describe "$name" -o json | jq -r '.private_net[0].ip'))
  done

  for i in $(seq 1 "$AGENT_COUNT"); do
    name="${CLUSTER_NAME}-agent-$i"
    AGENT_IPS+=($(hcloud server ip "$name"))
    AGENT_PRIVS+=($(hcloud server describe "$name" -o json | jq -r '.private_net[0].ip'))
  done
  log "Attaching server nodes to Load Balancer..."
  for i in $(seq 1 "$SERVER_COUNT"); do
    name="${CLUSTER_NAME}-server-$i"
    
    # Check if the server is already a target to avoid duplicate errors
    if ! hcloud load-balancer describe "$LB" -o json | jq -e ".targets[].server.name | select(. == \"$name\")" &>/dev/null; then
      log "Adding $name to $LB..."
      hcloud load-balancer add-target "$LB" --server "$name" --use-private-ip
    else
      ok "$name is already a target of $LB"
    fi
  done
}

# --------------------------- K3S INSTALL ------------------------------------
install_k3s() {
  log "Installing k3s..."

  s0="${SERVER_IPS[0]}"
  s0p="${SERVER_PRIVS[0]}"

  wait_ssh "$s0"

  ok "CONFIGURING SERVER 0: $s0"
  # --- FIRST SERVER ---
  ssh_cmd "$s0" "bash -s" <<EOF
export INSTALL_K3S_VERSION=${K3S_VERSION}
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --token ${K3S_TOKEN} \
  --node-ip ${s0p} \
  --advertise-address ${s0p} \
  --tls-san ${LB_IP} \
  --flannel-iface \$(ip route get 1.1.1.1 | awk '{print \$5; exit}') \
  ${K3S_EXTRA_ARGS}
EOF

  # --- ADDITIONAL SERVERS ---
  for i in $(seq 1 "$((SERVER_COUNT-1))"); do
    ip="${SERVER_IPS[$i]}"
    pip="${SERVER_PRIVS[$i]}"
    wait_ssh "$ip"
    ok "CONFIGURING SERVER $i: $ip"

    ssh_cmd "$ip" "bash -s" <<EOF
export INSTALL_K3S_VERSION=${K3S_VERSION}
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://${s0p}:6443 \
  --token ${K3S_TOKEN} \
  --node-ip ${pip} \
  --advertise-address ${pip} \
  --tls-san ${LB_IP} \
  --flannel-iface \$(ip route get 1.1.1.1 | awk '{print \$5; exit}') \
  ${K3S_EXTRA_ARGS}
EOF
  done

  for i in $(seq 0 $((AGENT_COUNT-1))); do
    ok "CONFIGURING AGENT $i: $ip"
    ip="${AGENT_IPS[$i]}"
    pip="${AGENT_PRIVS[$i]}"
    wait_ssh "$ip"

    ssh_cmd "$ip" "bash -s" <<EOF
export INSTALL_K3S_VERSION=${K3S_VERSION}
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://${LB_IP}:6443 \
  --token ${K3S_TOKEN} \
  --node-ip ${pip} \
  --flannel-iface \$(ip route get 1.1.1.1 | awk '{print \$5; exit}')
EOF
  done
}

# --------------------------- KUBECONFIG -------------------------------------

kubeconfig() {
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"

  ssh_cmd "${SERVER_IPS[0]}" "cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${LB_IP}/" \
    > "$KUBECONFIG_PATH"

  export KUBECONFIG="$KUBECONFIG_PATH"
}

# --------------------------- FLUX -------------------------------------------

bootstrap_flux() {
  export KUBECONFIG="$KUBECONFIG_PATH"

  flux bootstrap git flux-system \                                               
  --url="ssh://git@gitlab.thekor.eu:2022/flux/fleet-infra.git" \
  --branch="main" \
  --path="clusters/k3s-ha" \
  --private-key-file="${HOME}/.ssh/id_ed25519"
}

# --------------------------- MAIN -------------------------------------------

case "${1:-up}" in
  up)
    provision
    install_k3s
    kubeconfig
    bootstrap_flux
    ;;
  *)
    echo "Usage: $0 {up}"
    exit 1
    ;;
esac