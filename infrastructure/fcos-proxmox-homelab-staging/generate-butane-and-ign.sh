#!/bin/bash
set -euo pipefail

# Default configuration
# NUM_NODES=3
NUM_NODES=3
# SSH keys array - can be populated from config file or command line
# Legacy single key support (for backwards compatibility with config file)
SSH_KEY=""
# Multi-key array (preferred)
SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7l4hUqsANrYqvXaFGgn331V//squfGP1PFbP6+EBkl ubuntu@ubuntu"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJK53GJVzC7//eCqmQeAE4RiWS1zkLsMpnA/PPFBWgUK nb-hpratt"
  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAICM0ELAeKb33WeWdHyRlOiqpnxjAuGiaqB3WMBbHc781AAAABHNzaDo= lianli-31-08-2024-yubikey1-1"
  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFZSLMAdPrKnYkG2Ic9wqZkniZJxn0m73f9gXN+PH8yzAAAABHNzaDo= ubuntu-22-01-2024-yubikey2"
)

SSH_KEY_FBAK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0Xp/z7zql1V6cuIraTyZwCCM48+8QQ0BeM20cXsGiw fedora-backup@hetzner-ecom"
BASE_IP="192.168.7"
GATEWAY=192.168.7.1
DNS=10.10.85.24
# STARTING_IP=21
STARTING_IP=24
INTERFACE_NAME="ens18"
HOSTNAME_PREFIX="coreos-cp"
CONTAINER_RUNTIME="containerd"  # containerd or crio
SELINUX_MODE="permissive"       # enforcing, permissive, or disabled
INSTALL_DISK="/dev/vda"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load config file if exists
CONFIG_FILE="butane-config.env"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}Loading configuration from ${CONFIG_FILE}${NC}"
    source "$CONFIG_FILE"
fi

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate Butane configuration files and Ignition JSON for Fedora CoreOS nodes
optimized for Kubernetes with Cilium CNI and Kubespray deployment.

Options:
    -n, --nodes NUM         Number of nodes to generate (default: 3)
    -k, --ssh-key KEY       SSH public key to add (can be specified multiple times)
    -K, --ssh-keys-file FILE  File containing one SSH public key per line
    -i, --interface NAME    Network interface name (default: ens18)
    -b, --base-ip IP        Base IP address (default: 192.168.7)
    -s, --start-ip NUM      Starting IP suffix (default: 20)
    -p, --prefix PREFIX     Hostname prefix (default: coreos-cp)
    -r, --runtime RUNTIME   Container runtime: containerd or crio (default: containerd)
    -e, --selinux MODE      SELinux mode: enforcing, permissive, disabled (default: permissive)
    -c, --clean             Clean existing files before generating
    -w, --wipe              Clean existing files and including terraform state before generating
    -h, --help              Show this help message

SSH Key Examples:
    # Single key (same as before)
    $0 -k "ssh-ed25519 AAAA... user@host"

    # Multiple keys via repeated -k flags
    $0 -k "ssh-ed25519 AAAA... alice@host" -k "ssh-rsa AAAA... bob@host"

    # Keys from a file (one key per line, blank lines and # comments ignored)
    $0 -K ~/.ssh/authorized_keys

    # Mix of -k and -K
    $0 -k "ssh-ed25519 AAAA... alice@host" -K /path/to/extra-keys.txt

Other Examples:
    $0                                      # Generate 3 nodes with defaults
    $0 -n 5                                 # Generate 5 nodes
    $0 -n 3 -i eth1 -b 192.168.1 -s 100   # Custom network settings
    $0 --clean -n 3                         # Clean and regenerate
    $0 -r crio -e enforcing                # Use CRI-O with SELinux enforcing

Configuration file (butane-config.env):
    Supports both a single key or an array of keys:

    # Single key (legacy, still supported)
    SSH_KEY="ssh-ed25519 AAAA..."

    # Multiple keys (preferred)
    SSH_KEYS=(
        "ssh-ed25519 AAAA... alice@host"
        "ssh-rsa AAAA... bob@host"
        "ssh-ed25519 AAAA... ci-bot@host"
    )

    NUM_NODES=3
    SSH_KEY="ssh-ed25519 AAAA..."
    BASE_IP="10.0.1"
    STARTING_IP=10
    INTERFACE_NAME="ens18"
    HOSTNAME_PREFIX="fedora-coreos-node"
    CONTAINER_RUNTIME="containerd"
    SELINUX_MODE="permissive"

Features:
    - Kubernetes-ready configuration with required kernel modules
    - Cilium CNI support with eBPF optimization
    - Kubespray-compatible setup
    - Automatic Python3 installation for Ansible
    - Network configuration with static IPs
    - Swap disabled (Kubernetes requirement)
    - Required sysctl parameters configured
    - Container runtime support (containerd/CRI-O)
    - Multiple SSH authorized keys support

EOF
}

# Parse command line arguments
CLEAN=false
WIPE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--nodes)
            NUM_NODES="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEYS+=("$2")
            shift 2
            ;;
        -K|--ssh-keys-file)
            KEYS_FILE="$2"
            if [ ! -f "$KEYS_FILE" ]; then
                echo -e "${RED}Error: SSH keys file not found: ${KEYS_FILE}${NC}"
                exit 1
            fi
            # Read file: skip blank lines and comment lines starting with #
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line#"${line%%[![:space:]]*}"}"  # ltrim
                line="${line%"${line##*[![:space:]]}"}"  # rtrim
                [[ -z "$line" || "$line" == \#* ]] && continue
                SSH_KEYS+=("$line")
            done < "$KEYS_FILE"
            shift 2
            ;;
        -i|--interface)
            INTERFACE_NAME="$2"
            shift 2
            ;;
        -b|--base-ip)
            BASE_IP="$2"
            shift 2
            ;;
        -s|--start-ip)
            STARTING_IP="$2"
            shift 2
            ;;
        -p|--prefix)
            HOSTNAME_PREFIX="$2"
            shift 2
            ;;
        -r|--runtime)
            CONTAINER_RUNTIME="$2"
            if [[ ! "$CONTAINER_RUNTIME" =~ ^(containerd|crio)$ ]]; then
                echo -e "${RED}Error: Runtime must be 'containerd' or 'crio'${NC}"
                exit 1
            fi
            shift 2
            ;;
        -e|--selinux)
            SELINUX_MODE="$2"
            if [[ ! "$SELINUX_MODE" =~ ^(enforcing|permissive|disabled)$ ]]; then
                echo -e "${RED}Error: SELinux mode must be 'enforcing', 'permissive', or 'disabled'${NC}"
                exit 1
            fi
            shift 2
            ;;
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -w|--wipe)
            WIPE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Merge legacy SSH_KEY into SSH_KEYS array if set (from config file or env)
# Prepend so the primary key comes first; dedup happens below.
if [[ -n "$SSH_KEY" ]]; then
    SSH_KEYS=("$SSH_KEY" "${SSH_KEYS[@]+"${SSH_KEYS[@]}"}")
fi

# Deduplicate SSH_KEYS, preserving first-occurrence order.
# This handles any combination of SSH_KEY / SSH_KEYS from the config file
# plus keys added via -k / -K flags.
declare -A _seen_keys=()
_deduped_keys=()
for _k in "${SSH_KEYS[@]+"${SSH_KEYS[@]}"}"; do
    if [[ -z "${_seen_keys[$_k]+_}" ]]; then
        _seen_keys["$_k"]=1
        _deduped_keys+=("$_k")
    fi
done
SSH_KEYS=("${_deduped_keys[@]+"${_deduped_keys[@]}"}")
unset _seen_keys _deduped_keys _k

# Validate at least one key is present
if [ ${#SSH_KEYS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No SSH public keys provided.${NC}"
    echo "Use -k 'ssh-ed25519 AAAA...' or -K /path/to/keys-file, or set SSH_KEYS in ${CONFIG_FILE}"
    exit 1
fi

# Helper: emit Butane-formatted ssh_authorized_keys block entries
render_ssh_keys_yaml() {
    for key in "${SSH_KEYS[@]}"; do
        echo "        - ${key}"
    done
}

# Clean existing files if requested
if [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}Cleaning existing Butane, Ignition files...${NC}"
    rm -f node-*.bu ignition-node-*.json
    echo -e "${GREEN}✓ Cleaned${NC}"
    echo ""
fi

if [ "$WIPE" = true ]; then
    echo -e "${YELLOW}Cleaning existing Butane, Ignition files and terraform state...${NC}"
    rm -f node-*.bu ignition-node-*.json
    rm -f terraform.tfstate
    rm -f terraform.tfstate.backup
    echo -e "${GREEN}✓ Cleaned${NC}"
    echo ""
fi

# Check if butane is installed
if ! command -v butane &> /dev/null; then
    echo -e "${RED}Error: butane command not found${NC}"
    echo "Please install butane first:"
    echo "  Fedora/RHEL: sudo dnf install butane"
    echo "  Other: https://github.com/coreos/butane/releases"
    exit 1
fi

# Load environment variables from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Function to generate Butane config for a node
generate_butane_config() {
    local node_num=$1
    local hostname="${HOSTNAME_PREFIX}-${node_num}"
    local ip_suffix=$((STARTING_IP + node_num - 1))
    local private_ip="${BASE_IP}.${ip_suffix}"
    local output_file="node-${node_num}.bu"
    local password_hash=""
    if [[ -n "${NODE_PASSWORD:-}" ]]; then
        password_hash=$(openssl passwd -6 "$NODE_PASSWORD")
    fi
    # Build ssh_authorized_keys YAML lines
    local ssh_keys_yaml
    ssh_keys_yaml="$(render_ssh_keys_yaml)"

    cat > "${output_file}" <<EOF
variant: fcos
version: 1.5.0

passwd:
  users:
    - name: core
      password_hash: "${password_hash}"
      ssh_authorized_keys:
${ssh_keys_yaml}
      groups:
        - wheel
        - sudo
    - name: fedora-backup
      ssh_authorized_keys:
        - ${SSH_KEY_FBAK}

storage:
  directories:
    # Kubernetes directories
    - path: /etc/kubernetes
      mode: 0755
    - path: /var/lib/kubelet
      mode: 0755
    - path: /var/lib/etcd
      mode: 0700
    # Cilium directories
    - path: /etc/cilium
      mode: 0755
    - path: /var/lib/cilium
      mode: 0755
    # CNI directories (in /var since /opt is read-only)
    # Note: /run is a tmpfs, directories created at runtime by services
$(if [ "$CONTAINER_RUNTIME" = "containerd" ]; then
cat <<'CONTAINERD_DIRS'
    # Containerd directories
    - path: /etc/containerd
      mode: 0755
    - path: /etc/containerd/config.d
      mode: 0755
    - path: /var/lib/containerd
      mode: 0755
CONTAINERD_DIRS
else
cat <<'CRIO_DIRS'
    # CRI-O directories
    - path: /etc/crio
      mode: 0755
    - path: /etc/crio/crio.conf.d
      mode: 0755
    - path: /var/lib/crio
      mode: 0755
CRIO_DIRS
fi)
    # cilium
    - path: /etc/cni/net.d
      mode: 0755
      user:
        id: 0
      group:
        id: 0
    - path: /opt/cni/bin
      mode: 0755
      user:
        id: 0
      group:
        id: 0

  files:
    # Hostname configuration
    - path: /etc/hostname
      mode: 0644
      overwrite: true
      contents:
        inline: ${hostname}

    - path: /etc/zincati/config.d/50-updates.toml
      mode: 0600
      contents:
        inline: |
          [updates]
          strategy = "periodic"

          [[updates.periodic.window]]
          days = [ "Saturday" ]
          start_time = "18:29"
          length_minutes = 60

    # Network configuration
    - path: /etc/NetworkManager/system-connections/private.nmconnection
      mode: 0600
      contents:
        inline: |
          [connection]
          id=private
          type=ethernet
          interface-name=${INTERFACE_NAME}

          [ethernet]

          [ipv4]
          method=manual
          addresses=${private_ip}/24
          gateway=${GATEWAY}
          dns=${DNS}

          [ipv6]
          method=disabled
    
    # Kernel modules for Cilium and Kubernetes
    - path: /etc/modules-load.d/k8s-cilium.conf
      mode: 0644
      contents:
        inline: |
          # Required for Kubernetes
          overlay
          br_netfilter
          
          # Required for Cilium eBPF
          sch_ingress
          sch_cls
          
          # Required for kube-proxy (if using iptables mode)
          ip_vs
          ip_vs_rr
          ip_vs_wrr
          ip_vs_sh
          nf_conntrack
          
          # Additional networking modules
          xt_socket
          xt_u32
          vxlan
    
    # Sysctl parameters for Kubernetes and Cilium
    - path: /etc/sysctl.d/99-kubernetes-cilium.conf
      mode: 0644
      contents:
        inline: |
          # Kubernetes networking
          net.bridge.bridge-nf-call-iptables = 1
          net.bridge.bridge-nf-call-ip6tables = 1
          net.ipv4.ip_forward = 1
          net.ipv4.conf.all.forwarding = 1
          net.ipv6.conf.all.forwarding = 1
          
          # Allow Cilium to manage these - don't set strict values
          net.ipv4.conf.default.rp_filter = 0
          net.ipv4.conf.all.rp_filter = 0
          
          # Disable IPv6 router advertisements (optional, can be removed if using IPv6)
          net.ipv6.conf.all.accept_ra = 0
          net.ipv6.conf.default.accept_ra = 0
          
          # eBPF and performance tuning
          net.core.bpf_jit_enable = 1
          net.core.bpf_jit_harden = 0
          net.core.bpf_jit_limit = 1000000000
          
          # Increase connection tracking (important for Cilium)
          net.netfilter.nf_conntrack_max = 1000000
          net.netfilter.nf_conntrack_tcp_timeout_established = 86400
          net.netfilter.nf_conntrack_tcp_timeout_close_wait = 3600
          
          # ARP settings for Cilium
          net.ipv4.neigh.default.gc_thresh1 = 80000
          net.ipv4.neigh.default.gc_thresh2 = 90000
          net.ipv4.neigh.default.gc_thresh3 = 100000
          
          # File system tuning for Kubernetes
          fs.inotify.max_user_watches = 524288
          fs.inotify.max_user_instances = 512
          fs.file-max = 2097152
          
          # Kernel tuning
          kernel.pid_max = 4194304
          vm.max_map_count = 262144
          
          # Disable swap usage (important!)
          vm.swappiness = 0
          
          # Cilium-specific: allow unprivileged BPF
          kernel.unprivileged_bpf_disabled = 0
    
    # Silence audit logs (optional, reduces log spam)
    - path: /etc/sysctl.d/20-silence-audit.conf
      mode: 0644
      contents:
        inline: |
          # Disable audit system
          kernel.printk = 4 4 1 7
    
    # SELinux configuration
    - path: /etc/selinux/config
      mode: 0644
      overwrite: true
      contents:
        inline: |
          SELINUX=${SELINUX_MODE}
          SELINUXTYPE=targeted
    
    # Hosts file with all cluster nodes
    - path: /etc/hosts
      mode: 0644
      overwrite: true
      contents:
        inline: |
          127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
          ::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
          
          # Cluster nodes

$(for i in $(seq 1 $NUM_NODES); do
    node_ip="${BASE_IP}.$((STARTING_IP + i - 1))"
    node_name="${HOSTNAME_PREFIX}-${i}"
    echo "          ${node_ip}   ${node_name}"
done)
    
    # Containerd configuration drop-ins (if using containerd)
$(if [ "$CONTAINER_RUNTIME" = "containerd" ]; then
cat <<'CONTAINERD_CONFIG'
    - path: /etc/containerd/config.d/10-kubernetes.toml
      mode: 0644
      contents:
        inline: |
          version = 2
          
          [plugins."io.containerd.grpc.v1.cri"]
            sandbox_image = "registry.k8s.io/pause:3.9"
            
            [plugins."io.containerd.grpc.v1.cri".containerd]
              [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
                runtime_type = "io.containerd.runc.v2"
                [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
                  SystemdCgroup = true
            
            [plugins."io.containerd.grpc.v1.cri".cni]
              bin_dir = "/opt/cni/bin"
              conf_dir = "/etc/cni/net.d"
CONTAINERD_CONFIG
fi)
    
    # CRI-O configuration (if using crio)
$(if [ "$CONTAINER_RUNTIME" = "crio" ]; then
cat <<'CRIO_CONFIG'
    - path: /etc/crio/crio.conf.d/02-cgroup-manager.conf
      mode: 0644
      contents:
        inline: |
          [crio.runtime]
          conmon_cgroup = "pod"
          cgroup_manager = "systemd"
    
    - path: /etc/crio/crio.conf.d/03-cni.conf
      mode: 0644
      contents:
        inline: |
          [crio.network]
          network_dir = "/etc/cni/net.d/"
          plugin_dirs = ["/opt/cni/bin/"]
CRIO_CONFIG
fi)

systemd:
  units:
    # Network manager wait for online
    - name: NetworkManager-wait-online.service
      enabled: true
    
    # Disable swap (required for Kubernetes)
    - name: disable-swap.service
      enabled: true
      contents: |
        [Unit]
        Description=Disable Swap for Kubernetes
        DefaultDependencies=no
        Before=kubelet.service

        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/swapoff -a
        ExecStart=/usr/bin/sh -c 'sed -i.bak "/ swap / s/^/#/" /etc/fstab || true'
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    
    # Create runtime directories for Cilium
    - name: create-cilium-runtime-dirs.service
      enabled: true
      contents: |
        [Unit]
        Description=Create Cilium Runtime Directories
        DefaultDependencies=no
        Before=kubelet.service containerd.service crio.service

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/mkdir -p /run/cilium
        ExecStart=/usr/bin/chmod 0755 /run/cilium
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    
    # Mount BPF filesystem for Cilium
    - name: sys-fs-bpf.mount
      enabled: true
      contents: |
        [Unit]
        Description=BPF Filesystem for Cilium
        Documentation=https://docs.cilium.io/
        DefaultDependencies=no
        Before=kubelet.service
        ConditionPathIsMountPoint=!/sys/fs/bpf

        [Mount]
        What=bpffs
        Where=/sys/fs/bpf
        Type=bpf
        Options=rw,nosuid,nodev,noexec,relatime,mode=700

        [Install]
        WantedBy=multi-user.target
    
    # Load kernel modules
    - name: load-kernel-modules.service
      enabled: true
      contents: |
        [Unit]
        Description=Load Kernel Modules for Kubernetes and Cilium
        DefaultDependencies=no
        Before=kubelet.service
        After=systemd-modules-load.service

        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/modprobe overlay
        ExecStart=/usr/sbin/modprobe br_netfilter
        ExecStart=/usr/sbin/modprobe sch_ingress
        ExecStart=/usr/sbin/modprobe sch_cls
        ExecStart=/usr/sbin/modprobe ip_vs
        ExecStart=/usr/sbin/modprobe ip_vs_rr
        ExecStart=/usr/sbin/modprobe ip_vs_wrr
        ExecStart=/usr/sbin/modprobe ip_vs_sh
        ExecStart=/usr/sbin/modprobe nf_conntrack
        ExecStart=/usr/sbin/modprobe xt_socket
        ExecStart=/usr/sbin/modprobe xt_u32
        ExecStart=/usr/sbin/modprobe vxlan
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    
    # Apply sysctl settings
    - name: apply-sysctl.service
      enabled: true
      contents: |
        [Unit]
        Description=Apply Sysctl Settings
        After=network.target

        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/sysctl --system
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    
    - name: install-packages.service
      enabled: true
      contents: |
        [Unit]
        Description=Install Required Packages for Kubernetes and Ansible
        After=network-online.target
        Wants=network-online.target
        Before=node-setup.service
        ConditionPathExists=!/var/lib/kubernetes-packages-installed

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/rpm-ostree install --apply-live --allow-inactive \\
          python3 \\
          python3-libselinux \\
          python3-pip \\
          python3-pyyaml \\
          helm \\
          socat \\
          conntrack-tools \\
          ipset \\
          iptables \\
          ebtables \\
          ethtool \\
          ipvsadm \\
          bash-completion \\
          curl \\
          wget \\
          tar \\
          rsync \\
          qemu-guest-agent \\
          tmux \\
          ncdu
        ExecStart=/usr/bin/touch /var/lib/kubernetes-packages-installed
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        
    # Container runtime service
$(if [ "$CONTAINER_RUNTIME" = "containerd" ]; then
cat <<'CONTAINERD_SERVICE'
    - name: containerd.service
      enabled: true
CONTAINERD_SERVICE
else
cat <<'CRIO_SERVICE'
    - name: crio.service
      enabled: true
CRIO_SERVICE
fi)
    
    # Node setup service
    - name: node-setup.service
      enabled: true
      contents: |
        [Unit]
        Description=Initial Node Setup
        After=network-online.target install-packages.service load-kernel-modules.service
        Wants=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/hostnamectl set-hostname ${hostname}
        ExecStart=/usr/bin/nmcli connection up private
        ExecStart=/usr/sbin/sysctl --system
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target

    - name: qemu-guest-agent.service
      enabled: true
    
    - name: reboot-after-install.service
      enabled: true
      contents: |
        [Unit]
        Description=Reboot after initial package installation
        After=install-packages.service
        Requires=install-packages.service
        ConditionPathExists=!/var/lib/initial-reboot-done

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/touch /var/lib/initial-reboot-done
        ExecStart=/usr/sbin/reboot
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
  
    # Firewall configuration (optional - adjust ports as needed)
    - name: configure-firewall.service
      enabled: false
      contents: |
        [Unit]
        Description=Configure Firewall for Kubernetes
        After=firewalld.service
        Wants=firewalld.service

        [Service]
        Type=oneshot
        # Kubernetes API Server
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=6443/tcp
        # etcd
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=2379-2380/tcp
        # Kubelet API
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=10250/tcp
        # kube-scheduler
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=10259/tcp
        # kube-controller-manager
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=10257/tcp
        # NodePort Services
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=30000-32767/tcp
        # Cilium health checks
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=4240/tcp
        # Cilium VXLAN
        ExecStart=/usr/bin/firewall-cmd --permanent --add-port=8472/udp
        # Reload firewall
        ExecStart=/usr/bin/firewall-cmd --reload
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
EOF
    
    echo -e "${GREEN}✓${NC} Generated ${output_file}"
}

# Function to convert Butane to Ignition
convert_to_ignition() {
    local node_num=$1
    local butane_file="node-${node_num}.bu"
    local ignition_file="ignition-node-${node_num}.json"
    
    if butane --pretty --strict "${butane_file}" > "${ignition_file}" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Generated ${ignition_file}"
        
        # Validate JSON
        if command -v jq &> /dev/null; then
            if jq empty "${ignition_file}" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} Valid JSON"
            else
                echo -e "  ${RED}✗${NC} Invalid JSON"
                return 1
            fi
        fi
    else
        echo -e "${RED}✗${NC} Failed to generate ${ignition_file}"
        butane --strict "${butane_file}" 2>&1 || true
        return 1
    fi
}

generate_installer_ignition() {
    local node_num=$1
    local node_ignition_file="ignition-node-${node_num}.json"
    local installer_ignition_file="ignition-installer-${node_num}.json"

    local node_ign_b64
    node_ign_b64=$(base64 -w 0 "${node_ignition_file}")

    cat > "${installer_ignition_file}" <<EOF
{
  "ignition": { "version": "3.3.0" },
  "storage": {
    "files": [{
      "path": "/etc/coreos/node.ign",
      "mode": 420,
      "contents": {
        "source": "data:text/plain;base64,${node_ign_b64}"
      }
    }]
  },
  "systemd": {
    "units": [{
      "name": "coreos-installer-passthrough.service",
      "enabled": true,
      "contents": "[Unit]\\nDescription=Install CoreOS to passthrough disk\\nAfter=network-online.target\\nWants=network-online.target\\nConditionPathExists=!/var/lib/.coreos-installed\\n\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/bin/coreos-installer install ${INSTALL_DISK} --ignition-file /etc/coreos/node.ign --insecure-ignition\\nExecStartPost=/usr/bin/touch /var/lib/.coreos-installed\\nExecStartPost=/bin/systemctl --no-block reboot\\n\\n[Install]\\nWantedBy=multi-user.target"    }]
  }
}
EOF

    echo -e "${GREEN}✓${NC} Generated ${installer_ignition_file} (targets ${INSTALL_DISK})"
}

# Main execution
echo ""
echo "========================================================================"
echo "  Fedora CoreOS Butane Configuration Generator"
echo "  Optimized for Kubernetes with Cilium CNI"
echo "========================================================================"
echo ""
echo "Configuration:"
echo "  Nodes:              ${NUM_NODES}"
echo "  Hostname prefix:    ${HOSTNAME_PREFIX}"
echo "  Network:            ${BASE_IP}.${STARTING_IP}-$((STARTING_IP + NUM_NODES - 1))/24"
echo "  Interface:          ${INTERFACE_NAME}"
echo "  Container Runtime:  ${CONTAINER_RUNTIME}"
echo "  SELinux:            ${SELINUX_MODE}"
echo "  SSH Keys:           ${#SSH_KEYS[@]} key(s) configured"
for idx in "${!SSH_KEYS[@]}"; do
    # Print only the key type and comment (first and last fields) to avoid cluttering output
    key_summary=$(echo "${SSH_KEYS[$idx]}" | awk '{print $1, $NF}')
    echo "    [$((idx+1))] ${key_summary}"
done
echo ""

FAILED=0
echo "Generating Butane configurations..."
echo "========================================================================"
for i in $(seq 1 $NUM_NODES); do
    generate_butane_config $i
done

echo ""
echo "Converting Butane configs to Ignition JSON..."
echo "========================================================================"
for i in $(seq 1 $NUM_NODES); do
    if ! convert_to_ignition $i; then
        FAILED=$((FAILED + 1))
    else
        generate_installer_ignition $i
    fi
done

echo ""
echo "Summary:"
echo "========================================================================"
for i in $(seq 1 $NUM_NODES); do
    ip_suffix=$((STARTING_IP + i - 1))
    hostname="${HOSTNAME_PREFIX}-${i}"
    private_ip="${BASE_IP}.${ip_suffix}"
    echo "Node $i: ${hostname} (${private_ip})"
done

echo ""
echo "Files generated:"
if ls node-*.bu ignition-node-*.json &>/dev/null; then
    ls -lh node-*.bu ignition-node-*.json 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}'
fi

if [ $FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All files generated successfully${NC}"
    echo ""
    echo "Features enabled:"
    echo "  ✓ Kubernetes kernel modules (overlay, br_netfilter, etc.)"
    echo "  ✓ Cilium eBPF modules (sch_ingress, sch_cls, etc.)"
    echo "  ✓ Required sysctl parameters configured"
    echo "  ✓ Swap disabled"
    echo "  ✓ Container runtime: ${CONTAINER_RUNTIME}"
    echo "  ✓ Python3 + required packages for Ansible/Kubespray"
    echo "  ✓ Static network configuration"
    echo "  ✓ SELinux: ${SELINUX_MODE}"
    echo "  ✓ SSH keys: ${#SSH_KEYS[@]} authorized key(s)"
    echo ""
    echo "Next steps:"
    echo "  1. Review the generated Butane (.bu) files"
    echo "  2. Verify the Ignition JSON files"
    echo "  3. Deploy with: terraform apply"
    echo "  4. After deployment, run Kubespray with Cilium CNI:"
    echo "     ansible-playbook -i inventory/mycluster/hosts.yaml cluster.yml"
    echo ""
    echo "Kubespray Cilium configuration tips:"
    echo "  - Set: kube_network_plugin: cilium"
    echo "  - Set: cilium_kube_proxy_replacement: strict (for full eBPF mode)"
    echo "  - Set: cilium_enable_ipv4_masquerade: true"
    echo "  - Set: cilium_tunnel_mode: vxlan (or geneve)"
else
    echo ""
    echo -e "${RED}✗ $FAILED file(s) failed to generate${NC}"
    exit 1
fi