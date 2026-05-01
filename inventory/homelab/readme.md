ansible -i inventory/homelab/inventory.ini all -m ping
ansible-playbook -i inventory/homelab/inventory.ini --become --become-user=root cluster.yml
ansible-playbook -i inventory/homelab/inventory.ini reset.yml
ansible-playbook -i inventory/homelab/inventory.ini --tags "cilium" cluster.yml
export KUBECONFIG=/etc/kubernetes/admin.conf