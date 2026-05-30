install fedora, git, nano, /etc/hosts do git config with name and email

    dnf install -y python3-libdnf5 git nano python3 python3-pip vi vim helm
    git config --global user.name "Hugo Pratt" && git config --global user.email "hpratt@thekor.eu"
    ssh-keygen
    send pub key to other nodes 

add another partition for ceph with parted

    parted /dev/sda mkpart primary ext4 24.3GB 100%
    add my pub key to .ssh/authorized_keys on all nodes

setup the cluster with kubespray, make sure each machine has at least 4Gb of ram otherwise it won't install ceph. Youll also want a cpu that is compatible with virtualization. You can also configure the hostnames in the inventory/mycluster/inventory.ini

    nano .ssh/config
    copy over ssh priv key or add existing one to gitlab's admin as the project is private
    git clone git@gitlab.thekor.eu:kube/kubespray.git
    git checkout -b homelab
    git push -u origin homelab
    systemctl disable firewalld && systemctl stop firewalld
    cd kubespray/
    python3 -m venv env
    source env/bin/activate
    pip install -r requirements.txt
    python -c "import sys; print(sys.version)" > release.txt
    nano inventory/mycluster/inventory.ini
    nano inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml
    ansible -i inventory/mycluster/inventory.ini all -m ping
    ansible-playbook -i inventory/mycluster/inventory.ini --become --become-user=root cluster.yml -vv
    if cilium fails to install make sure to look at cilium-debug.sh

retrieve kubeconfig

    scp proxmox06-node1:/etc/kubernetes/pki/ca.crt ca_homelab.crt
    sudo mv ca_homelab.crt /etc/pki/ca-trust/source/anchors/ca_homelab.crt
    sudo update-ca-trust extract

run 00-ns.yaml 00-prometheus.yaml and 01-storage.yaml with ansible

    cd homelab_playbooks
    python3 -m venv env
    source env/bin/activate
    pip install -r requirements.txt && ansible-galaxy collection install -r requirements.yml
    mv group_vars/all/vault.yml group_vars/all/vault.yml.disabled
    ansible-playbook -i inventory.ini 00-ns.yaml
    ansible-playbook -i inventory.ini 00-prometheus.yaml
    ansible-playbook -i inventory.ini 01-storage.yaml
    mv group_vars/all/vault.yml.disabled group_vars/all/vault.yml

run 02-mongo.yaml with ansible

    ansible-playbook -i inventory.ini 02-mongo.yaml --ask-vault-pass

run 03-cert-manager with ansible

    ansible-playbook -i inventory.ini 03-cert-manager --ask-vault-pass

setup a centralized mongo db namespace for the db: trello, amazon, spotify and mongo-express

    the script is not ready so do it manually
    ansible-playbook -i inventory.ini restore-mongo.yaml --ask-vault-pass

add the hetzner load balancer or a local haproxy in load balancer mode
setup a service account for gitlab and corresponding kubeconfig
setup gitlab to push images: deploy ssh pub key and ci/cd variables
create an access token for the registry pull and secret
add the deployments: chirpy

    ansible-playbook -i inventory.ini 4-chirpy.yaml --ask-vault-pass

add the deployments: trello, spotify and amazon

    ansible-playbook -i inventory.ini 5-spotify.yaml --ask-vault-pass
    ansible-playbook -i inventory.ini 6-trello.yaml --ask-vault-pass
    ansible-playbook -i inventory.ini 7-amazon.yaml --ask-vault-pass

setup centralized postgres

    ansible-playbook -i inventory.ini 8-postgres.yaml --ask-vault-pass

setup centralized mariadb

    ansible-playbook -i inventory.ini 9-maria-operator.yaml --ask-vault-pass

deploy  grafana, prometheus update, pushgateway

    create grafana user on postgres
    ansible-galaxy collection install community.postgresql && pip install psycopg2-binary
    ansible-playbook -i inventory.ini 10-monitoring.yaml --ask-vault-pass

deploy uptime

    ansible-playbook -i inventory.ini 11-uptimekuma.yaml --ask-vault-pass

deploy influx

    ansible-playbook -i inventory.ini 12-influx.yaml --ask-vault-pass

import dashboards in grafana
verify all alerts are good

    patch the configmap for kube-proxy metricsBindAddress: 127.0.0.1:10249 --> metricsBindAddress: 0.0.0.0:10249
    kubectl rollout restart daemonset kube-proxy -n kube-system
    patch the flannel daemon set and remove the cpu and memory limits

setup pull backups, backup operator role and permissions

    careful, not everything is automated here
    run deploy-backup.sh to get the kubeconfig and copy it over to the backup machine
    ansible-playbook -i inventory.ini 13-backupuser.yaml --ask-vault-pass

setup mongo and postgres backups cronjobs

     ansible-playbook -i inventory.ini 15-backup-postgres.yaml --ask-vault-pass
     ansible-playbook -i inventory.ini 16-backup-mongo.yaml --ask-vault-pass

encrypt block backups

    migrating to cn-postgres

    pg_dump -Upostgres authentik > authentik_20260530.bak
    pg_dump -Upostgres booking > booking_20260530.bak
    pg_dump -Upostgres craftstudios > craftstudios_20260530.bak
    pg_dump -Upostgres grafana > grafana_20260530.bak
    pg_dump -Upostgres harbor_core > harbor_core_20260530.bak
    pg_dump -Upostgres harbor_notary_server > harbor_notserver_20260530.bak
    pg_dump -Upostgres harbor_notary_signer > harbor_notsign_20260530.bak
    pg_dump -Upostgres harbor_trivy > harbor_triv_20260530.bak
    pg_dump -Upostgres linkwarden > linkwarden_20260530.bak
    pg_dump -Upostgres makita > makita_20260530.bak
    pg_dump -Upostgres netbox > netbox_20260530.bak
    pg_dump -Upostgres paperless > paperless_20260530.bak
    pg_dump -Upostgres patchmon > patchmon_20260530.bak


    k cp backup.tgz shared-pg-1:/var/lib/postgresql/data/ -n cn-postgres --container postgres
    cd /var/lib/postgresql/data/
    tar -xvzf backup.tgz

    psql -Upostgres authentik < authentik_20260530.bak
    psql -Upostgres booking < booking_20260530.bak
    psql -Upostgres craftstudios < craftstudios_20260530.bak
    psql -Upostgres grafana < grafana_20260530.bak
    psql -Upostgres harbor_core < harbor_core_20260530.bak
    psql -Upostgres harbor_notary_server < harbor_notserver_20260530.bak
    psql -Upostgres harbor_notary_signer < harbor_notsign_20260530.bak
    psql -Upostgres harbor_trivy < harbor_triv_20260530.bak
    psql -Upostgres linkwarden < linkwarden_20260530.bak
    psql -Upostgres makita < makita_20260530.bak
    psql -Upostgres netbox < netbox_20260530.bak
    psql -Upostgres paperless < paperless_20260530.bak
    psql -Upostgres patchmon < patchmon_20260530.bak