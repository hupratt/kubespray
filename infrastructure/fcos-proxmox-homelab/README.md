# Fedora CoreOS on Proxmox — Terraform

Deploy 3 Fedora CoreOS VMs on Proxmox VE using Terraform.

## Prerequisites

- Proxmox VE node up and running
- Terraform >= 1.3 installed locally
- `butane` CLI installed ([install guide](https://coreos.github.io/butane/))

## Setup Steps

### 1. Create the FCOS template on Proxmox

Run these commands **on your Proxmox host**:

```bash
# Download latest stable FCOS QCOW2
FCOS_URL=$(curl -s https://builds.coreos.fedoraproject.org/streams/stable.json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); \
  print(d['architectures']['x86_64']['artifacts']['qemu']['formats']['qcow2.xz']['disk']['location'])")

wget "$FCOS_URL"
xz -d fedora-coreos-*.qcow2.xz

# Create template VM (ID 9000) with no graphical console
qm create 9000 --name fcos-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 fedora-coreos-*.qcow2 local-lvm
qm set 9000 --scsihw virtio-scsi-single --virtio0 local-lvm:vm-9000-disk-0,iothread=1,cache=writeback,discard=on
qm set 9000 --boot c --bootdisk virtio0
qm set 9000 --serial0 socket --vga serial0
qm template 9000
# to revert to std output through the proxmox graphical console
qm set 9000 --vga std
qm set 9000 --delete serial0
```

### 2. Enable snippets on Proxmox local storage so that you can upload files

```bash
pvesm set local --content vztmpl,iso,backup,snippets
```

### 3. Generate your Ignition config

Edit the script and run it
```bash
./generate-butane-and-ign.sh
```

### 4. Configure Terraform variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Proxmox details
```

Or use environment variables (recommended for secrets):

```bash
export TF_VAR_proxmox_password="your-password"
```

### 5. Allow passing args for windows machines

echo "options kvm ignore_msrs=Y" >> /etc/modprobe.d/kvm.conf  # if needed


### 6. Deploy

```bash
terraform init
terraform plan
terraform apply
```

## Cleanup

```bash
terraform destroy
```
