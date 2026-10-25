# download & install terraform

wget -O- https://rpm.releases.hashicorp.com/fedora/hashicorp.repo | sudo tee /etc/yum.repos.d/hashicorp.repo
sudo yum list available | grep hashicorp
sudo dnf -y install terraform

# load env variable
export TF_VAR_hcloud_token=2...............................
export HCLOUD_TOKEN=2...............................

# download talos & upload it to hetzner
<!-- curl -LO https://github.com/siderolabs/talos/releases/download/v1.6.7/metal-amd64.raw.xz -->
curl -LO https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.12.4/metal-amd64.raw.zst

dnf install -y zstd
unzstd metal-amd64.raw.zst -o metal-amd64.raw
xz metal-amd64.raw
rm -f metal-amd64.raw.zst

IMAGE_NAME="metal-amd64.raw.xz"
ARCH="x86_64"    # or "aarch64"
STREAM="stable"  # or "testing", "next"
VERSION="v1.12.4"

hcloud-upload-image upload \
  --architecture "x86" \
  --compression xz \
  --image-path "$IMAGE_NAME" \
  --location hel1 \
  --labels os=talos,channel="$STREAM" \
  --description "Talos ($VERSION, $ARCH)"

# install hcloud and hcloud-upload-image
wget https://github.com/hetznercloud/cli/releases/download/v1.61.0/hcloud-linux-amd64.tar.gz
wget https://github.com/apricote/hcloud-upload-image/releases/download/v1.3.0/hcloud-upload-image_Linux_x86_64.tar.gz

tar -xvzf hcloud-linux-amd64.tar.gz
tar -xvzf hcloud-upload-image_Linux_x86_64.tar.gz

sudo mv hcloud-linux-amd64/hcloud /usr/local/bin
sudo mv hcloud-upload-image /usr/local/bin
hcloud context create default

terraform init
terraform plan
terraform apply

# once the cluster is up and running

terraform output -raw kubeconfig > ~/.kube/talos.config

# Add Cilium helm repo
helm repo add cilium https://helm.cilium.io/
helm repo update
export LB_IP=$(terraform output -raw load_balancer_ip)
echo $LB_IP


# Install Cilium with kube-proxy replacement
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=${LB_IP} \
  --set k8sServicePort=6443

# Install cilium CLI and run connectivity test
cilium status
cilium connectivity test
