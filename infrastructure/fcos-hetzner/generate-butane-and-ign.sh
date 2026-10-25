#!/bin/bash
set -euo pipefail

# Default configuration
NUM_NODES=3
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJK53GJVzC7//eCqmQeAE4RiWS1zkLsMpnA/PPFBWgUK nb-hpratt@srv-ipa01.ipa.adata-software.de"
BASE_IP="10.0.1"
STARTING_IP=10
INTERFACE_NAME="ens10"
HOSTNAME_PREFIX="fedora-coreos-node"
CONTAINER_RUNTIME="containerd"  # containerd or crio
SELINUX_MODE="permissive"       # enforcing, permissive, or disabled

# opkssh configuration
OPKSSH_ENABLED=true
OPKSSH_VERSION="latest"         # or pin to e.g. "v0.4.0"
OPKSSH_USERS=""                 # e.g. "alice@gmail.com https://accounts.google.com core"

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
    -k, --ssh-key KEY       SSH public key to use
    -i, --interface NAME    Network interface name (default: ens10)
    -b, --base-ip IP        Base IP address (default: 10.0.1)
    -s, --start-ip NUM      Starting IP suffix (default: 10)
    -p, --prefix PREFIX     Hostname prefix (default: fedora-coreos-node)
    -r, --runtime RUNTIME   Container runtime: containerd or crio (default: containerd)
    -e, --selinux MODE      SELinux mode: enforcing, permissive, disabled (default: permissive)
        --opkssh            Enable opkssh (OpenPubkey SSH via OIDC)
        --opkssh-version    opkssh binary version tag (default: latest)
        --opkssh-user       Add an OIDC->principal mapping: "email issuer principal"
                            Can be repeated. Example:
                            --opkssh-user "alice@gmail.com https://accounts.google.com core"
    -c, --clean             Clean existing files before generating
    -h, --help              Show this help message

Examples:
    $0                                      # Generate 3 nodes with defaults
    $0 -n 5                                 # Generate 5 nodes
    $0 -n 3 -i eth1 -b 192.168.1 -s 100   # Custom network settings
    $0 --clean -n 3                         # Clean and regenerate
    $0 -r crio -e enforcing                # Use CRI-O with SELinux enforcing
    $0 --opkssh \\
       --opkssh-user "alice@gmail.com https://accounts.google.com core" \\
       --opkssh-user "bob@company.com https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/v2.0 core"

Configuration file:
    Create ${CONFIG_FILE} with variables to override defaults:

    NUM_NODES=3
    SSH_KEY="ssh-ed25519 AAAA..."
    BASE_IP="10.0.1"
    STARTING_IP=10
    INTERFACE_NAME="ens10"
    HOSTNAME_PREFIX="fedora-coreos-node"
    CONTAINER_RUNTIME="containerd"
    SELINUX_MODE="permissive"
    OPKSSH_ENABLED=true
    OPKSSH_VERSION="latest"
    # One entry per line: email issuer principal
    OPKSSH_USERS="alice@gmail.com https://accounts.google.com core"

Features:
    - Kubernetes-ready configuration with required kernel modules
    - Cilium CNI support with eBPF optimization
    - Kubespray-compatible setup
    - Automatic Python3 installation for Ansible
    - Network configuration with static IPs
    - Swap disabled (Kubernetes requirement)
    - Required sysctl parameters configured
    - Container runtime support (containerd/CRI-O)
    - Optional opkssh: SSH via OpenID Connect identity (no static keys needed)

EOF
}

# Parse command line arguments
CLEAN=false
OPKSSH_USER_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--nodes)
            NUM_NODES="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY="$2"
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
        --opkssh)
            OPKSSH_ENABLED=true
            shift
            ;;
        --opkssh-version)
            OPKSSH_VERSION="$2"
            shift 2
            ;;
        --opkssh-user)
            OPKSSH_USER_ARGS+=("$2")
            shift 2
            ;;
        -c|--clean)
            CLEAN=true
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

# Append any --opkssh-user args to OPKSSH_USERS
for entry in "${OPKSSH_USER_ARGS[@]+"${OPKSSH_USER_ARGS[@]}"}"; do
    if [ -z "$OPKSSH_USERS" ]; then
        OPKSSH_USERS="$entry"
    else
        OPKSSH_USERS="${OPKSSH_USERS}"$'\n'"$entry"
    fi
done

# Validate opkssh config
if [ "$OPKSSH_ENABLED" = true ] && [ -z "$OPKSSH_USERS" ]; then
    echo -e "${YELLOW}Warning: --opkssh enabled but no --opkssh-user entries defined.${NC}"
    echo -e "${YELLOW}         /etc/opk/auth_id will be empty - no OIDC logins will be permitted.${NC}"
fi

# Clean existing files if requested
if [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}Cleaning existing Butane and Ignition files...${NC}"
    rm -f node-*.bu ignition-node-*.json
    echo -e "${GREEN}Cleaned${NC}"
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

# ---------------------------------------------------------------------------
# Helper: emit opkssh storage directories block
# /etc/opk must be declared here so Ignition creates it at provisioning time,
# before the opkssh-setup.service runs. Without this, the service fails
# trying to chown a directory that doesn't exist.
# ---------------------------------------------------------------------------
opkssh_storage_dirs() {
    if [ "$OPKSSH_ENABLED" != true ]; then
        return
    fi
    cat <<'OPKSSH_DIRS'
    # opkssh - declared explicitly so the dir exists before opkssh-setup.service runs
    - path: /etc/opk
      mode: 0755
      user:
        name: root
OPKSSH_DIRS
}

# ---------------------------------------------------------------------------
# Helper: emit opkssh storage/files block
# Note: the binary is NOT downloaded here via source: because Ignition runs
# before networking is ready and downloads silently fail. The binary is
# fetched by opkssh-setup.service instead (after network-online.target).
# ---------------------------------------------------------------------------
opkssh_storage_files() {
    if [ "$OPKSSH_ENABLED" != true ]; then
        return
    fi

    # Build auth_id lines - format per line: "email issuer principal"
    local indent="          "
    local auth_id_lines="${indent}# principal  email  issuer"
    if [ -n "$OPKSSH_USERS" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            read -r email issuer principal <<< "$line"
            auth_id_lines+=$'\n'"${indent}${principal}  ${email}  ${issuer}"
        done <<< "$OPKSSH_USERS"
    fi

    cat <<OPKSSH_FILES

    # -----------------------------------------------------------------------
    # opkssh: OpenPubkey SSH (OIDC-based authentication)
    # -----------------------------------------------------------------------

    # Trusted OIDC providers - issuer must match token claim exactly (incl. trailing slash)
    - path: /etc/opk/providers
      mode: 0640
      user:
        name: root
      group:
        name: opksshuser
      contents:
        inline: |
          # issuer                                            client-id                                          expiry
          https://auth.adata.de/application/o/opkssh/        CntbfjHKJR6B3dA9CN0gtJ2f2d3RGeyyqRaE8bv4          24h

    # OIDC identity -> Linux principal mapping
    - path: /etc/opk/auth_id
      mode: 0640
      user:
        name: root
      group:
        name: opksshuser
      contents:
        inline: |
${auth_id_lines}

    # sshd drop-in: delegate key verification to opkssh
    - path: /etc/ssh/sshd_config.d/10-opkssh.conf
      mode: 0600
      user:
        name: root
      contents:
        inline: |
          AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
          AuthorizedKeysCommandUser opksshuser
OPKSSH_FILES
}

# ---------------------------------------------------------------------------
# Helper: emit the opkssh passwd block entry
# ---------------------------------------------------------------------------
opkssh_passwd_user() {
    if [ "$OPKSSH_ENABLED" != true ]; then
        return
    fi
    cat <<'OPKSSH_USER'

    # Unprivileged system user required by AuthorizedKeysCommandUser
    - name: opksshuser
      system: true
      no_create_home: true
      shell: /sbin/nologin
OPKSSH_USER
}

# ---------------------------------------------------------------------------
# Helper: emit the opkssh systemd units
#
# The binary is downloaded via systemd rather than Ignition source: because
# Ignition executes before network-online.target and downloads silently fail,
# leaving /usr/local/bin/opkssh missing with no error in the journal.
# ---------------------------------------------------------------------------
opkssh_systemd_unit() {
    if [ "$OPKSSH_ENABLED" != true ]; then
        return
    fi

    local bin_url
    if [ "$OPKSSH_VERSION" = "latest" ]; then
        bin_url="https://github.com/openpubkey/opkssh/releases/latest/download/opkssh-linux-amd64"
    else
        bin_url="https://github.com/openpubkey/opkssh/releases/download/${OPKSSH_VERSION}/opkssh-linux-amd64"
    fi

    cat <<OPKSSH_UNIT

    # Download opkssh binary after network is up, then configure sshd
    - name: opkssh-setup.service
      enabled: true
      contents: |
        [Unit]
        Description=opkssh first-boot setup
        After=network-online.target
        Wants=network-online.target
        Before=sshd.service
        ConditionPathExists=!/var/lib/opkssh-setup-done

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/curl -fsSL ${bin_url} -o /usr/local/bin/opkssh
        ExecStart=/usr/bin/chmod 0755 /usr/local/bin/opkssh
        ExecStart=/usr/bin/chown root:opksshuser /etc/opk
        ExecStart=/usr/bin/chmod 0750 /etc/opk
        ExecStart=/usr/bin/chown root:opksshuser /etc/opk/providers
        ExecStart=/usr/bin/chown root:opksshuser /etc/opk/auth_id
        ExecStart=/usr/sbin/sshd -t
        ExecStart=/usr/bin/touch /var/lib/opkssh-setup-done

        [Install]
        WantedBy=multi-user.target

    # Ensure sshd starts after opkssh-setup completes
    - name: sshd.service
      dropins:
        - name: 10-opkssh-after.conf
          contents: |
            [Unit]
            After=opkssh-setup.service
            Wants=opkssh-setup.service
OPKSSH_UNIT
}

# Function to generate Butane config for a node
generate_butane_config() {
    local node_num=$1
    local hostname="${HOSTNAME_PREFIX}-${node_num}"
    local ip_suffix=$((STARTING_IP + node_num - 1))
    local private_ip="${BASE_IP}.${ip_suffix}"
    local output_file="node-${node_num}.bu"

    cat > "${output_file}" <<EOF
variant: fcos
version: 1.5.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ${SSH_KEY}
      groups:
        - wheel
        - sudo
$(opkssh_passwd_user)

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
    # Cilium CNI
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
$(opkssh_storage_dirs)

  files:
    # Hostname configuration
    - path: /etc/hostname
      mode: 0644
      overwrite: true
      contents:
        inline: ${hostname}

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
$(opkssh_storage_files)

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
          rsync
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
$(opkssh_systemd_unit)
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
if [ "$OPKSSH_ENABLED" = true ]; then
    echo "  opkssh:             enabled (version: ${OPKSSH_VERSION})"
    if [ -n "$OPKSSH_USERS" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            read -r email issuer principal <<< "$line"
            echo "    -> ${email} (${issuer}) -> ${principal}"
        done <<< "$OPKSSH_USERS"
    fi
else
    echo "  opkssh:             disabled (use --opkssh to enable)"
fi
echo ""

# Generate Butane configs
echo "Generating Butane configurations..."
echo "========================================================================"
for i in $(seq 1 $NUM_NODES); do
    generate_butane_config $i
done

echo ""
echo "Converting Butane configs to Ignition JSON..."
echo "========================================================================"

# Convert to Ignition
FAILED=0
for i in $(seq 1 $NUM_NODES); do
    if ! convert_to_ignition $i; then
        FAILED=$((FAILED + 1))
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
    echo -e "${GREEN}All files generated successfully${NC}"
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
    if [ "$OPKSSH_ENABLED" = true ]; then
        echo "  ✓ opkssh: OIDC-based SSH authentication"
        echo "    - Binary downloaded at first boot via opkssh-setup.service"
        echo "    - Providers: /etc/opk/providers"
        echo "    - Auth mappings: /etc/opk/auth_id"
        echo "    - sshd drop-in: /etc/ssh/sshd_config.d/10-opkssh.conf"
        echo ""
        echo "  opkssh client usage (on your workstation):"
        echo "    opkssh login --provider https://auth.adata.de/application/o/opkssh/,<client_id>"
        echo "    ssh core@<node-ip>"
    fi
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