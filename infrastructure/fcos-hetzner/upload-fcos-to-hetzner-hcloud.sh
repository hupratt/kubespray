https://docs.fedoraproject.org/en-US/fedora-coreos/provisioning-hetzner/
https://fedoraproject.org/coreos/download/?stream=stable#arches

download the cloud image of coreos

IMAGE_NAME="fedora-coreos-43.20260301.3.1-hetzner.x86_64.raw.xz"
ARCH="x86_64"    # or "aarch64"
STREAM="stable"  # or "testing", "next"
export HCLOUD_TOKEN="<your token>"

hcloud-upload-image upload \
  --architecture "x86" \
  --compression xz \
  --image-path "$IMAGE_NAME" \
  --location fsn1 \
  --labels os=fedora-coreos,channel="$STREAM" \
  --description "Fedora CoreOS ($STREAM, $ARCH)"

hcloud image list --type=snapshot --selector=os=fedora-coreos