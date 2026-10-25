#!/bin/bash
set -euo pipefail

# Script to upload Fedora CoreOS to Hetzner Cloud as a snapshot

# Usage: ./upload-fcos-to-hetzner.sh [ssh-private-key-path]
SSH_KEY_PATH="${1:-$HOME/.ssh/id_ed25519_adata}"

echo "=== Fedora CoreOS Hetzner Upload Script ==="
echo "Using SSH key: $SSH_KEY_PATH"
echo ""

# Verify SSH key exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH key not found at $SSH_KEY_PATH"
    echo "Usage: $0 [ssh-private-key-path]"
    echo "Example: $0 ~/.ssh/id_ed25519_adata"
    exit 1
fi

# Check for required tools
if ! command -v hcloud &> /dev/null; then
    echo "Error: hcloud CLI not found. Install it:"
    echo "  brew install hcloud (macOS)"
    echo "  wget -O /usr/local/bin/hcloud https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq not found. Install it:"
    echo "  apt-get install jq (Ubuntu/Debian)"
    echo "  brew install jq (macOS)"
    exit 1
fi

# Check for API token
if [ -z "${HCLOUD_TOKEN:-}" ]; then
    echo "Error: HCLOUD_TOKEN environment variable not set"
    echo "Export your Hetzner Cloud API token:"
    echo "  export HCLOUD_TOKEN='your-token-here'"
    exit 1
fi

echo "Step 1: Downloading latest Fedora CoreOS qcow2 image..."
STREAM="stable"
ARCH="x86_64"

# Get the latest version info
FCOS_INFO=$(curl -s "https://builds.coreos.fedoraproject.org/streams/${STREAM}.json")
VERSION=$(echo "$FCOS_INFO" | jq -r '.architectures.x86_64.artifacts.qemu.release')
QCOW_URL=$(echo "$FCOS_INFO" | jq -r '.architectures.x86_64.artifacts.openstack.formats."qcow2.xz".disk.location')

echo "Latest version: $VERSION"
echo "Download URL: $QCOW_URL"

FILENAME="fedora-coreos-${VERSION}-qemu.x86_64.qcow2.xz"

if [ ! -f "$FILENAME" ]; then
    echo "Downloading $FILENAME..."
    curl -L -o "$FILENAME" "$QCOW_URL"
else
    echo "File already exists: $FILENAME"
fi

echo ""
echo "Step 2: Decompressing image..."
QCOW_FILE="${FILENAME%.xz}"
if [ ! -f "$QCOW_FILE" ]; then
    xz -d -k "$FILENAME"
else
    echo "Decompressed file already exists: $QCOW_FILE"
fi

echo ""
echo "Step 3: Creating temporary server for snapshot upload..."

# Get first SSH key ID
SSH_KEY_ID=100614144

if [ -z "$SSH_KEY_ID" ]; then
    echo "Error: No SSH keys found in your Hetzner account"
    echo "Add one with: hcloud ssh-key create --name mykey --public-key \"$(cat ${SSH_KEY_PATH}.pub)\""
    exit 1
fi

echo "Using SSH key ID: $SSH_KEY_ID"

# Create a temporary server
SERVER_NAME="fcos-upload-temp-$$"
echo "Creating server: $SERVER_NAME"

hcloud server create \
    --name "$SERVER_NAME" \
    --type cx23 \
    --image ubuntu-22.04 \
    --ssh-key "$SSH_KEY_ID" \
    --location nbg1

# Wait for it to be fully created
echo "Waiting for server to be created..."
sleep 10

# Get server ID and IP using columns output
SERVER_ID=$(hcloud server list -o columns=id,name -o noheader | grep "$SERVER_NAME" | awk '{print $1}')
SERVER_IP=$(hcloud server list -o columns=name,ipv4 -o noheader | grep "$SERVER_NAME" | awk '{print $2}')

if [ -z "$SERVER_ID" ]; then
    echo "Error: Could not find server ID"
    exit 1
fi

if [ -z "$SERVER_IP" ]; then
    echo "Error: Could not find server IP"
    exit 1
fi

echo "Server created with ID: $SERVER_ID"
echo "Server IP: $SERVER_IP"

echo "Waiting for server to boot and SSH to be ready (60 seconds)..."
sleep 60

echo ""
echo "Step 4: Uploading and converting image..."
echo "This may take several minutes..."

# Add SSH key to known_hosts
ssh-keyscan -H "$SERVER_IP" >> ~/.ssh/known_hosts 2>/dev/null || true

# Upload the image
echo "Uploading image to server (this will take a while)..."
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$QCOW_FILE" "root@${SERVER_IP}:/tmp/" || {
    echo "Error: Failed to upload image"
    echo "Trying to connect with SSH to debug..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "root@${SERVER_IP}" echo "SSH connection successful" || {
        echo "SSH connection failed. Server might not be ready yet."
        echo "You can try manually:"
        echo "  ssh -i $SSH_KEY_PATH root@$SERVER_IP"
        echo "Then run these commands:"
        echo "  apt-get update && apt-get install -y qemu-utils"
        echo "  # Upload the file manually and convert it"
        echo ""
        echo "Don't forget to delete the server when done:"
        echo "  hcloud server delete $SERVER_ID"
        exit 1
    }
    exit 1
}

# Convert and write to disk
echo "Converting and writing image to disk..."
# you can overwrite the current rootfs because the OS is loaded into RAM
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "root@${SERVER_IP}" << 'EOF'
    echo "Installing qemu-utils..."
    apt-get update -qq && apt-get install -y -qq qemu-utils
    
    echo "Converting image to raw format and writing to disk..."
    qemu-img convert -f qcow2 -O raw /tmp/*.qcow2 /dev/sda
    
    echo "Syncing filesystem..."
    sync
    
    echo "Done!"
EOF

echo ""
echo "Step 5: Creating snapshot..."
echo "Shutting down server..."
hcloud server shutdown "$SERVER_ID"

# Wait for shutdown
echo "Waiting for shutdown to complete..."
sleep 20

echo "Creating snapshot..."
SNAPSHOT_DESC="Fedora CoreOS $VERSION"
hcloud server create-image \
    --description "$SNAPSHOT_DESC" \
    --type snapshot \
    "$SERVER_ID"

# Wait for snapshot creation
sleep 10

# Get snapshot ID
SNAPSHOT_ID=$(hcloud image list -o columns=id,description -o noheader | grep "Fedora CoreOS" | tail -1 | awk '{print $1}')

echo ""
echo "Step 6: Cleaning up..."
hcloud server delete "$SERVER_ID"

echo ""
echo "=== Done! ==="
echo ""

if [ -n "$SNAPSHOT_ID" ]; then
    echo "Snapshot created successfully!"
    echo "Snapshot ID: $SNAPSHOT_ID"
    echo ""
    echo "Add this to your terraform.tfvars:"
    echo "fcos_image_id = \"$SNAPSHOT_ID\""
else
    echo "Snapshot created but ID could not be determined automatically."
    echo "Run: hcloud image list"
    echo "Look for: $SNAPSHOT_DESC"
    echo "Then add the ID to terraform.tfvars"
fi

echo ""
echo "To verify: hcloud image list"
hcloud image list --type snapshot