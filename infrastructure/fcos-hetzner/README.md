# Hetzner Cloud - 3 Fedora CoreOS VMs

This Terraform configuration spins up **3 Fedora CoreOS VMs** on Hetzner Cloud with private networking.

## Architecture

- **3 Fedora CoreOS VMs** (cx23: 2 vCPU, 4GB RAM each)
- **Private Network**: 10.0.1.0/24 for inter-node communication
  - Node 1: 10.0.1.10
  - Node 2: 10.0.1.11
  - Node 3: 10.0.1.12
- **Public IPs**: Each node has a public IPv4/IPv6 address
- **Configuration**: Ignition (generated from Butane)

## What You Get

- 3 minimal, container-optimized Fedora CoreOS servers
- Automatic security updates (CoreOS auto-updates)
- Private network for secure inter-node communication
- SSH access via your public key
- Immutable OS with atomic updates

## Prerequisites

1. **Hetzner Cloud Account** + API Token
2. **Terraform** (>= 1.0)

```
wget -O- https://rpm.releases.hashicorp.com/fedora/hashicorp.repo | sudo tee /etc/yum.repos.d/hashicorp.repo
sudo yum list available | grep hashicorp
sudo dnf -y install terraform
```

1. **Docker** (for running Butane to convert configs to Ignition)
2. **hcloud CLI** (optional, for uploading Fedora CoreOS)
```
hcloud ssh-key create --name my-key --public-key "$(cat ~/.ssh/id_ed25519.pub)"
hcloud ssh-key list
hcloud context list                                                             
ACTIVE   NAME         
*        adata-context
```
1. **SSH Key Pair**


## Step 1: Upload Fedora CoreOS to Hetzner

Hetzner doesn't provide Fedora CoreOS by default. You need to upload it as a snapshot.

### Automated Upload (Recommended)

```bash
# Make executable
chmod +x upload-fcos-to-hetzner.sh

# Set your API token
export HCLOUD_TOKEN='your-token-here'

# Run the upload script
./upload-fcos-to-hetzner.sh
```

This will download Fedora CoreOS, upload it to Hetzner, and give you a snapshot ID.

### Manual Upload

1. Download from https://fedoraproject.org/coreos/download (QCOW2 format)
2. Upload via Hetzner Cloud Console → Snapshots
3. Note the snapshot ID or name

## Step 2: Configure Terraform

```bash
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

Fill in:

```hcl
hcloud_token = "your-api-token"
ssh_public_key = "ssh-rsa AAAAB3... your-key"
fcos_image_id = "12345678"  # From upload script
```

## Step 3: Generate Ignition Configs

Before running Terraform, you need to generate the Ignition configs from Butane:

```bash
# Make the script executable
chmod +x generate-ignition.sh

# Generate Ignition configs
./generate-ignition.sh
```

This will create `ignition-node-1.json`, `ignition-node-2.json`, and `ignition-node-3.json`.

## Step 4: Deploy

```bash
# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Deploy
terraform apply
```

## Accessing Your VMs

```bash
# View SSH commands
terraform output ssh_commands

# Connect to node 1 (user is 'core', not 'root')
ssh core@<node-1-public-ip>

# Check the private network
ip addr show eth1
ping 10.0.1.10
ping 10.0.1.11
ping 10.0.1.12
```

## Testing Connectivity

From any node:

```bash
# Check hostname
hostnamectl

# Verify private IPs
ip addr

# Ping other nodes via private network
ping -c 3 10.0.1.10
ping -c 3 10.0.1.11
ping -c 3 10.0.1.12

# Check Fedora CoreOS version
rpm-ostree status

# View system info
systemctl status
```

## How It Works

### Butane → Ignition

1. **Butane config** (`butane-config.yaml`) - Human-readable YAML
2. **Terraform** converts it to **Ignition JSON** using Docker
3. **Ignition** provisions the VM on first boot (immutable, runs once)

### What Ignition Does

- Creates the `core` user with your SSH key
- Sets the hostname
- Configures network settings
- Enables IP forwarding

### Private Network

- All 3 nodes are on `10.0.1.0/24`
- Nodes can communicate privately (faster, no internet charges)
- Useful for clustering, databases, or distributed apps

## Common Use Cases

### Container Cluster
```bash
# Install k3s, Docker, or Podman
# Use private IPs for cluster communication
```

### Database Cluster
```bash
# Run PostgreSQL, Redis, etc. in containers
# Replicate over private network
```

### Development Environment
```bash
# 3 identical nodes for testing distributed apps
```

## Customization

### Different VM Size

Edit `main.tf`:
```hcl
server_type = "cx32"  # 4 vCPU, 8GB RAM
server_type = "cx42"  # 8 vCPU, 16GB RAM
```

### Different Location

```hcl
location = "fsn1"  # Falkenstein, Germany
location = "hel1"  # Helsinki, Finland
location = "ash"   # Ashburn, USA
```

### More/Fewer Nodes

Change `count = 3` in:
- `hcloud_server.node`
- `null_resource.generate_ignition`
- `hcloud_server_network.node_network`

### Custom Butane Config

Edit `butane-config.yaml` to add:
- Additional users
- Systemd units
- Files
- Container services

## Files Overview

- `main.tf` - Terraform configuration
- `butane-config.yaml` - Butane config template
- `upload-fcos-to-hetzner.sh` - Helper script to upload Fedora CoreOS
- `terraform.tfvars.example` - Example variables
- `ignition-node-*.json` - Generated Ignition configs (auto-created)

## Troubleshooting

### Can't SSH into nodes

- User is `core`, not `root`
- Check your SSH public key in `terraform.tfvars`
- Verify firewall allows SSH (port 22)

### Ignition not applying

Check logs on the VM:
```bash
ssh core@<ip>
journalctl -u ignition-firstboot
```

### Docker not running

Make sure Docker is running for Butane conversion:
```bash
docker ps
```

Manually convert Butane to Ignition:
```bash
cat butane-config.yaml | docker run --rm -i quay.io/coreos/butane:release
```

### Nodes can't communicate privately

Check private network interface:
```bash
ip addr show eth1
```

Verify private IPs are correct:
```bash
terraform output private_network
```

## Costs

Approximate monthly costs:
- CX22 × 3: €17.49/month
- Private network: Free
- Snapshot storage: ~€0.60/month (for ~5GB Fedora CoreOS image)

**Total: ~€18/month**

## Cleanup

```bash
# Destroy all infrastructure
terraform destroy

# Also delete the Fedora CoreOS snapshot
hcloud image list
hcloud image delete <snapshot-id>
```

## Why Fedora CoreOS?

- **Immutable**: Updates are atomic, no package drift
- **Auto-updates**: Automatic security patches
- **Container-optimized**: Designed for containerized workloads
- **Minimal**: Small attack surface, fast boot times
- **Declarative**: Ignition-based provisioning (no cloud-init)

## Next Steps

Ideas for what to do with your 3 nodes:

1. **Install Kubernetes** (k3s or k0s)
2. **Set up Docker Swarm**
3. **Deploy containerized apps**
4. **Create a distributed database** (etcd, Consul)
5. **Build a monitoring cluster** (Prometheus + Grafana)
6. **Run CI/CD pipelines**

## Resources

- [Fedora CoreOS Docs](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [Butane Config Spec](https://coreos.github.io/butane/)
- [Ignition Docs](https://coreos.github.io/ignition/)
- [Hetzner Cloud API](https://docs.hetzner.com/cloud/)
- [Terraform Hetzner Provider](https://registry.terraform.io/providers/hetznercloud/hcloud/)

