NAMESPACE='backup'
SERVICE_ACCOUNT_NAME='backup'
CERTIFICATE_PATH='/etc/pki/ca-trust/source/anchors/ca_homelab.crt'

kubectl create namespace $NAMESPACE
kubectl create sa $SERVICE_ACCOUNT_NAME -n $NAMESPACE

cat <<EOF > $SERVICE_ACCOUNT_NAME-token.yaml
apiVersion: v1
kind: Secret
metadata:
  name: $SERVICE_ACCOUNT_NAME-token
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $SERVICE_ACCOUNT_NAME
type: kubernetes.io/service-account-token
EOF

kubectl apply -f $SERVICE_ACCOUNT_NAME-token.yaml

CLUSTER=$(kubectl config view -o jsonpath='{.clusters[0].name}')
TOKEN=$(kubectl get secret $SERVICE_ACCOUNT_NAME-token -n $NAMESPACE -o jsonpath='{.data.token}' | base64 -d)
echo $CLUSTER
echo $TOKEN

kubectl config set-cluster $CLUSTER \
  --server=https://127.0.0.1:6443 \
  --certificate-authority=$CERTIFICATE_PATH \
  --embed-certs=true \
  --kubeconfig=sa.backup.kubeconfig

kubectl config set-credentials $SERVICE_ACCOUNT_NAME \
  --token=$TOKEN \
  --kubeconfig=sa.backup.kubeconfig

kubectl config set-context sa-$NAMESPACE-context \
  --cluster=$CLUSTER \
  --namespace=$NAMESPACE \
  --user=$SERVICE_ACCOUNT_NAME \
  --kubeconfig=sa.backup.kubeconfig

kubectl config use-context sa-$NAMESPACE-context \
  --kubeconfig=sa.backup.kubeconfig

kubectl config set-context --current \
  --namespace=$NAMESPACE \
  --kubeconfig=sa.backup.kubeconfig

# move it to its default place on your system
# mv sa.backup.kubeconfig ~/.kube

# test it out
# k get pods --kubeconfig=/home/hugo/.kube/sa.kubeconfig
# Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:gitlab:runner" cannot list resource "pods" in API group "" in the namespace "gitlab"
# careful, you'll have to set the default context manually