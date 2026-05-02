
# Upgrading can't be done from v1.32.8 to the latest 1.35.2 on one go. 

# rebase adata and homelab onto the master branch

# Rebase adata branch onto master
git checkout adata
git rebase -X theirs master

# Rebase homelab branch onto master
git checkout homelab
git rebase -X theirs master

git checkout -b broken_update
git reset --hard 9991412b4597d6eaf37f86e5f20f9f903a731c08 
git cherry-pick 6a22787461ba503548d69cdb5c0e6a971fa0c229 -X theirs
pip install -r requirements.txt


# Step 1: Drain the node (do this once, before all upgrades)
kubectl drain coreos-cp-1 --ignore-daemonsets --delete-emptydir-data

ansible-playbook -i inventory/homelab/inventory.ini --become cluster.yml -t gather-facts

fix containerd config
containerd_runc_runtime:
  name: runc
  type: "io.containerd.runc.v2"
  engine: ""                        # <-- missing key, causes the error
  base_runtime_spec: cri-base.json
  root: ""                          # <-- belongs here, not as Root: under options
  options:
    SystemdCgroup: "true"
    BinaryName: "{{ bin_dir }}/runc"

# roles/kubernetes-apps/helm/tasks/main.yml
remove all

# Step 2: 1.32.x → latest 1.32 patch (you're on 1.32.8, get latest 1.32)
ansible-playbook upgrade-cluster.yml -b -i inventory/homelab/inventory.ini \
  -e kube_version=1.32.9 --limit "coreos-cp-1"

git checkout homelab
pip install -r requirements.txt

# Step 3: → 1.33.x (latest patch)
ansible-playbook upgrade-cluster.yml -b -i inventory/homelab/inventory.ini \
  -e kube_version=1.33.8 --limit "coreos-cp-1"


# Step 4: → 1.34.x (latest patch)
ansible-playbook upgrade-cluster.yml -b -i inventory/homelab/inventory.ini \
  -e kube_version=1.34.4 --limit "coreos-cp-1"

# Step 5: → 1.35.x
ansible-playbook upgrade-cluster.yml -b -i inventory/homelab/inventory.ini \
  -e kube_version=1.35.1 --limit "coreos-cp-1"

# Step 6: Uncordon after all upgrades done
kubectl uncordon coreos-cp-1


sed -i '/runtime_engine/d' /etc/containerd/config.toml
sed -i '/runtime_root/d' /etc/containerd/config.tom

grep -n "runtime_engine\|runtime_root" /etc/containerd/config.toml

chown root:root /opt/cni/bin
chmod 755 /opt/cni/bin
kubectl edit configmap cilium-config -n kube-system
remove http from search

kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
NAME          TAINTS
coreos-cp-1   <none>
coreos-cp-2   <none>
coreos-cp-3   <none>

# Step 7: Verify
kubectl get nodes
kubectl get pods -A
kubectl get nodes coreos-cp-1 -o yaml | grep kubeletVersion


# 2026/01/02


ansible-playbook -i inventory/homelab-prod/inventory.ini --become cluster.yml -t gather-facts

kubectl drain coreos-cp-2 --ignore-daemonsets --delete-emptydir-data

ansible-playbook upgrade-cluster.yml -b -i inventory/homelab-prod/inventory.ini -e kube_version=1.36.0 --limit "coreos-cp-2"

kubectl drain coreos-cp-3 --ignore-daemonsets --delete-emptydir-data

ansible-playbook upgrade-cluster.yml -b -i inventory/homelab-prod/inventory.ini -e kube_version=1.36.0 --limit "coreos-cp-3"

kubectl drain coreos-cp-1 --ignore-daemonsets --delete-emptydir-data

ansible-playbook upgrade-cluster.yml -b -i inventory/homelab-prod/inventory.ini -e kube_version=1.36.0 --limit "coreos-cp-1"