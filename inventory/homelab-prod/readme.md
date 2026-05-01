ansible -i inventory/homelab-prod/inventory.ini all -m ping
ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root cluster.yml
ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root cluster.yml --tags containerd
ansible-playbook -i inventory/homelab-prod/inventory.ini reset.yml
ansible-playbook -i inventory/homelab-prod/inventory.ini --tags "cilium" cluster.yml
export KUBECONFIG=/etc/kubernetes/admin.conf
