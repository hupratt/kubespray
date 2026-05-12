ansible -i inventory/homelab-prod/inventory.ini all -m ping
ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root cluster.yml
ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root cluster.yml --tags containerd
ansible-playbook -i inventory/homelab-prod/inventory.ini reset.yml
ansible-playbook -i inventory/homelab-prod/inventory.ini --tags "cilium" cluster.yml
export KUBECONFIG=/etc/kubernetes/admin.conf

ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root playbooks/facts.yml
ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root scale.yml --limit=coreos-wk-4

ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root scale.yml --limit=coreos-wk-4 --start-at-task "Create kubeadm client config" -vvv
ansible-playbook -i inventory/homelab-prod/inventory.ini --become --become-user=root scale.yml --limit coreos-cp-1,coreos-cp-2,coreos-cp-3,coreos-wk-4

<!-- kubectl label node coreos-wk-4 node-role=slow-services
kubectl taint node coreos-wk-4 dedicated=slow-services:NoSchedule -->