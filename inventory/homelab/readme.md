ansible -i inventory/homelab/inventory.ini all -m ping
ansible-playbook -i inventory/homelab/inventory.ini --become --become-user=root cluster.yml
ansible-playbook -i inventory/homelab/inventory.ini reset.yml
ansible-playbook -i inventory/homelab/inventory.ini --tags "cilium" cluster.yml
export KUBECONFIG=/etc/kubernetes/admin.conf

## time it took to bootstrap

so terraform provisioning took almost an hour, kubespray 35 minutes and ceph takes a while to install as well

## gotchas

- forgetting to delete the temp vault keys when the recovery is over
- scale immich deployment to 0 so that the recovery succeeds
- forgetting to install cnpg or immich before running the restore
- 02d can't run without routing + tls cert