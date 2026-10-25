
# when re-install the helm chart it would complain for a missing policy
kubectl apply -f cilium-CRD.yml
or
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.14/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumlocalredirectpolicies.yaml

helm repo add cilium https://helm.cilium.io/
helm repo update

helm -n kube-system upgrade cilium cilium/cilium --values cilium/cilium-values.yaml 

# Restart all Cilium components in case the helm upgrade doesn't trigger
kubectl rollout restart daemonset/cilium -n kube-system
kubectl rollout restart deployment/cilium-operator -n kube-system

# Or reinstall Cilium
helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values

# clean install
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values=cilium/cilium-values.yaml 

# Coredns wouldn't find the kubeapi server. Set the environment variables to bypass the service
kubectl set env deployment/coredns -n kube-system KUBERNETES_SERVICE_HOST=192.168.7.101 KUBERNETES_SERVICE_PORT=6443
kubectl set env deployment/rook-ceph-operator -n rook-ceph KUBERNETES_SERVICE_HOST=192.168.7.101 KUBERNETES_SERVICE_PORT=6443


# this is important to run during the kubespray install otherwise the cilium-agents won't start
sudo chmod 775 -R /etc/cni/net.d
sudo chmod 775 -R /opt/cni/bin

ls -lha /etc/cni/net.d
ls -lha /opt/cni/bin

ssh kube-node2 chmod 775 -R /etc/cni/net.d
ssh kube-node2 chmod 775 -R /opt/cni/bin

ssh kube-node3 chmod 775 -R /etc/cni/net.d
ssh kube-node3 chmod 775 -R /opt/cni/bin


ansible-playbook -i inventory/hetzner-fcos/inventory.ini --tags "cilium" cluster.yml


sudo rm -rf /etc/cni/net.d/*
sudo mkdir -p /etc/cni/net.d
sudo chown root:root /etc/cni/net.d
sudo chmod 755 /etc/cni/net.d
sudo chown root:root /etc/cni
sudo chmod 755 /etc/cni

sudo rm -rf /opt/cni/bin/*
sudo mkdir -p /opt/cni/bin
sudo chown root:root /opt/cni/bin
sudo chmod 755 /opt/cni/bin
sudo chown root:root /etc/cni
sudo chmod 755 /etc/cni


----------------------------------------------------------------------------------------------------------------------------------------------------


helm upgrade cilium cilium/cilium --namespace kube-system \
  -f cilium-current-values.yaml


kubectl edit configmap coredns -n kube-system

change 10.10.85.105 to 1.1.1.1


kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"ipv4-native-routing-cidr":"10.233.0.0/16"}}'

# Restart Cilium
kubectl rollout restart daemonset cilium -n kube-system

# Wait for rollout
kubectl rollout status daemonset cilium -n kube-system


# Update Cilium to use the correct interface
kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"devices":"enp1s0"}}'
kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"devices":"enp7s0,enp1s0"}}'
# Restart Cilium
kubectl rollout restart daemonset cilium -n kube-system

# Wait for it
kubectl rollout status daemonset cilium -n kube-system

# Scale down nodelocaldns if it exists
kubectl scale deployment nodelocaldns -n kube-system --replicas=0 2>/dev/null || \
kubectl scale daemonset nodelocaldns -n kube-system --replicas=0 2>/dev/null || \
kubectl delete -n kube-system ds/nodelocaldns 2>/dev/null || echo "nodelocaldns not found as expected resource"

# Restart CoreDNS
kubectl rollout restart deployment coredns -n kube-system


# Use the first control plane node IP
kubectl set env deployment/coredns -n kube-system KUBERNETES_SERVICE_HOST=10.0.1.10 KUBERNETES_SERVICE_PORT=6443

# Wait for CoreDNS to restart
kubectl rollout status deployment/coredns -n kube-system

# Check the logs
kubectl logs -n kube-system deployment/coredns --tail=20


kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"enable-host-reachable-services":"true","bpf-lb-sock":"true"}}'

kubectl rollout restart daemonset cilium -n kube-system
kubectl rollout status daemonset cilium -n kube-system
kubectl run test-node --image=curlimages/curl --restart=Never -it --rm -- curl -k --max-time 5 https://10.0.1.10:6443
kubectl run test-dns --image=busybox --restart=Never -it --rm -- nslookup google.com
kubectl run test-dns2 --image=busybox --restart=Never -it --rm -- nslookup kubernetes

kubectl run test-dns-check --image=busybox --restart=Never -it --rm -- cat /etc/resolv.conf


sudo chmod 644 /etc/kubernetes/admin.conf
ansible-playbook -i inventory/hetzner-fcos/inventory.ini cluster.yml --tags nodelocaldns            

# Set the environment variables for nodelocaldns
kubectl set env daemonset/nodelocaldns -n kube-system KUBERNETES_SERVICE_HOST=10.0.1.10 KUBERNETES_SERVICE_PORT=6443

# Wait for it to restart
kubectl rollout status daemonset/nodelocaldns -n kube-system

# Check the logs
kubectl logs -n kube-system daemonset/nodelocaldns --tail=50


kubectl edit configmap nodelocaldns -n kube-system

kubectl set env daemonset/nodelocaldns -n kube-system KUBERNETES_SERVICE_HOST=10.0.1.10 KUBERNETES_SERVICE_PORT=6443

kubectl rollout status daemonset/nodelocaldns -n kube-system




----------------------



# Create a clean config
cat > cilium-values-fixed.yaml <<EOF
routingMode: native
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: "10.233.0.0/16"
devices: "enp1s0"
ipv4NonMasqueradeCIDRs:
  - 10.0.1.0/24
  - 10.233.0.0/16

enableIPv4Masquerade: true
kubeProxyReplacement: true
k8sServiceHost: "10.0.1.10"
k8sServicePort: "6443"

hostServices:
  enabled: true
  protocols: tcp,udp

bpf:
  masquerade: true

enable-host-reachable-services: true
enable-local-redirect-policy: true
host-reachable-services-cidrs: "10.233.0.0/18"
EOF

# Merge with your existing values
helm upgrade cilium cilium/cilium -n kube-system \
  -f cilium-values-backup.yaml \
  -f cilium-values-fixed.yaml

kubectl rollout status daemonset cilium -n kube-system


-------------------------------------------------------------------------------------------------------------


manual changes: set the upstream dns for localdns and coredns to 1.1.1.1


kubectl -n kube-system edit configmap cilium-config
egress-masquerade-interfaces: "enp7s0"
enable-bpf-masquerade: "false"
kubectl rollout restart daemonset/cilium -n kube-system


# Test connectivity again
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- ping -c 3 1.1.1.1
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- dig @1.1.1.1 google.com


# Check if masquerading rules exist
sudo iptables -t nat -L CILIUM_POST_nat -n -v

# Or check BPF masquerading
sudo kubectl -n kube-system exec -it ds/cilium -- cilium bpf nat list | head -20

# Let's see what Cilium thinks about masquerading
sudo kubectl -n kube-system exec -it ds/cilium -- cilium status --verbose | grep -i masq

# On EACH node, add masquerade rule for the public interface
sudo iptables -t nat -I CILIUM_POST_nat 1 -s 10.233.0.0/16 -o enp1s0 -j MASQUERADE

# Test immediately
sudo kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- ping -c 3 8.8.8.8
sudo kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- dig @1.1.1.1 google.com

kubectl -n kube-system edit configmap cilium-config


# Check Cilium status
sudo cilium status --all-namespaces

# Enable Hubble with UI and Relay
sudo cilium hubble enable


hubble-relay-enabled: "true"
hubble-ui-enabled: "true"

kubectl rollout restart daemonset/cilium -n kube-system

kubectl run -it --rm dns-test --image=busybox --restart=Never -- sh


enable-endpoint-routes: "true"

kubectl -n kube-system rollout restart ds cilium


nameserver 10.233.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5


sudo cilium policy get
sudo cilium policy get --all-namespaces


nslookup kubernetes 10.233.0.3  # Use the actual kube-dns service IP
ping 10.233.0.3
telnet 10.233.0.3 53


-------------------------------


 helm upgrade cilium cilium/cilium -n kube-system \                                                                                      
  -f cilium-values-backup4.yaml 

sudo tee -a /etc/containerd/config.toml << 'EOF'

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = '/opt/cni/bin'
  conf_dir = '/etc/cni/net.d'
EOF

sudo systemctl restart containerd
kubectl -n kube-system delete pod -l k8s-app=kube-dns

-------------------------------------------------------------

sudo kubectl -n kube-system rollout restart daemonset/cilium
sudo kubectl -n kube-system rollout status daemonset/cilium

sudo kubectl -n kube-system delete pod -l k8s-app=kube-dns
sudo kubectl -n kube-system logs -l k8s-app=kube-dns -f