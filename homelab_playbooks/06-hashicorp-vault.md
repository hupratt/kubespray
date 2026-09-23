upgrade path:

```sh
helm search repo hashicorp/vault --versions | grep -E "1\.(18|19|20|21)"

helm upgrade vault hashicorp/vault -n vault --version 0.29.1 --reuse-values --set server.image.tag=1.18.1
helm upgrade vault hashicorp/vault -n vault --version 0.30.0 --reuse-values --set server.image.tag=1.19.0
helm upgrade vault hashicorp/vault -n vault --version 0.31.0 --reuse-values --set server.image.tag=1.20.4
helm upgrade vault hashicorp/vault -n vault --version 0.32.0 --reuse-values --set server.image.tag=1.21.2

kubectl get statefulset vault -n vault -o jsonpath='{.spec.updateStrategy.type}'
OnDelete
```

so you'll have to manually delete the pods to maintain quorum and unseal

```sh
kubectl delete pod vault-0 -n vault && kubectl get pods -n vault -l app.kubernetes.io/name=vault -w
kubectl delete pod vault-1 -n vault && kubectl get pods -n vault -l app.kubernetes.io/name=vault -w
kubectl delete pod vault-2 -n vault && kubectl get pods -n vault -l app.kubernetes.io/name=vault -w

helm upgrade vault hashicorp/vault -n vault \
  --version 0.34.1 --reuse-values \
  --set server.image.tag=1.19.5 \
  --set injector.image.tag=1.7.5 \
  --set server.ha.raft.redundancyZones.enabled=false \
  --set server.httproute.enabled=false

```