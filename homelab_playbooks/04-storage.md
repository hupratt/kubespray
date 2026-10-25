## sync with upstream project
git remote add upstream https://github.com/rook/rook.git
git fetch upstream
git checkout -b master upstream/master
git push origin --tags

## set the default remote for the homelab branch
git branch --set-upstream-to=origin/homelab homelab

## rebase the upstream changes in master branch into my homelab branch
git fetch upstream
git switch homelab
git rebase -X theirs upstream/master

## updating ceph from v18.2.4 to v20.2.4

#### my cluster is on v18.2.4 so the upgrade path would be bump the operator from v1.15.3 to v1.15.9 then to v1.16.9 then 1.17.9 then v1.18.11

git checkout v1.15.9

#### 1. Update common.yaml + CRDs for the target release first
kubectl apply -f deploy/examples/common.yaml -f deploy/examples/crds.yaml

#### 2. Bump the operator image
kubectl -n rook-ceph set image deploy/rook-ceph-operator \
  rook-ceph-operator=rook/ceph:v1.15.9

git checkout v1.16.9

#### 1. Update common.yaml + CRDs for the target release first
kubectl apply -f deploy/examples/common.yaml -f deploy/examples/crds.yaml

#### 2. Bump the operator image
kubectl -n rook-ceph set image deploy/rook-ceph-operator \
  rook-ceph-operator=rook/ceph:v1.16.9

git checkout v1.17.9

#### 1. Update common.yaml + CRDs for the target release first
kubectl apply -f deploy/examples/common.yaml -f deploy/examples/crds.yaml

#### 2. Bump the operator image
kubectl -n rook-ceph set image deploy/rook-ceph-operator \
  rook-ceph-operator=rook/ceph:v1.17.9

git checkout v1.18.11

#### 1. Update common.yaml + CRDs for the target release first
kubectl apply -f deploy/examples/common.yaml -f deploy/examples/crds.yaml

#### 2. Bump the operator image
kubectl -n rook-ceph set image deploy/rook-ceph-operator \
  rook-ceph-operator=rook/ceph:v1.18.11

#### then upgrade the cluster v19.2.3

kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.spec.cephVersion.image}' 
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"cephVersion":{"image":"quay.io/ceph/ceph:v19.2.3"}}}'

#### bump the operator from v1.18.11 then v1.19.11 then 1.20.7

git checkout v1.19.11

#### 1. Update common.yaml + CRDs for the target release first
kubectl apply -f deploy/examples/common.yaml -f deploy/examples/crds.yaml

#### 2. Bump the operator image
kubectl -n rook-ceph set image deploy/rook-ceph-operator \
  rook-ceph-operator=rook/ceph:v1.19.11


git checkout v1.20.7

#### 1. Update common.yaml + CRDs for the target release first
kubectl apply -f deploy/examples/common.yaml -f deploy/examples/crds.yaml -f deploy/examples/csi-operator.yaml -f deploy/examples/operator.yaml

#### 2. Bump the operator image
kubectl -n rook-ceph set image deploy/rook-ceph-operator \
  rook-ceph-operator=rook/ceph:v1.20.7

#### then upgrade the cluster v20.2.4

kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.spec.cephVersion.image}' 
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"cephVersion":{"image":"quay.io/ceph/ceph:v20.2.4"}}}'

#### fix "Monitors are configured to allow auth using insecure key types" in ceph -s

kubectl -n rook-ceph set image deployment/rook-ceph-tools \
  rook-ceph-tools=quay.io/ceph/ceph:v20.2.4

kubectl -n rook-ceph rollout restart deployment/ceph-csi-controller-manager

kubectl -n rook-ceph patch configmap rook-ceph-operator-config \
  --type merge \
  -p '{"data":{"ROOK_USE_CSI_OPERATOR":"true"}}'

kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p '
spec:
  security:
    cephx:
      daemon:
        keyRotationPolicy: KeyGeneration
        keyGeneration: 2
'

###### delete the stale CSI drivers

kubectl delete csidriver \
  rook-ceph.rbd.csi.ceph.com \
  rook-ceph.cephfs.csi.ceph.com

###### trigger reconciliation

kubectl -n rook-ceph annotate driver rook-ceph.rbd.csi.ceph.com \
  csi.ceph.com/force-reconcile="$(date +%s)" --overwrite

kubectl -n rook-ceph annotate driver rook-ceph.cephfs.csi.ceph.com \
  csi.ceph.com/force-reconcile="$(date +%s)" --overwrite

###### rollout a new operator

kubectl rollout restart deploy -n rook-ceph rook-ceph-operator


###### verify keys are aes256k

echo '===== ALL CEPHX KEY TYPES ====='

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph auth dump-keys --format=json |
  jq -r '
    .data.secrets[] |
    [
      (.entity.type_str + (if .entity.id != "" then "." + .entity.id else "" end)),
      .auth.key.type_str,
      .auth.key.created
    ] | @tsv
  ' | column -t

echo
echo '===== CSI KEY TYPES ====='

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph auth dump-keys --format=json |
  jq -r '
    .data.secrets[] |
    select(.entity.type_str == "client" and (.entity.id | startswith("csi-"))) |
    [
      "client." + .entity.id,
      .auth.key.type_str,
      .auth.key.created
    ] | @tsv
  ' | column -t
===== ALL CEPHX KEY TYPES =====
mon                              aes256k  2026-09-22T12:33:01.943927+0000
mds.myfs-a                       aes256k  2026-09-22T12:31:21.173923+0000
mds.myfs-b                       aes256k  2026-09-22T12:31:36.826813+0000
osd.0                            aes256k  2026-09-22T12:36:40.114846+0000
osd.1                            aes256k  2026-09-22T12:37:50.215367+0000
osd.2                            aes256k  2026-09-22T12:38:51.666143+0000
client.admin                     aes256k  2026-09-22T12:30:48.363270+0000
client.ceph-exporter             aes256k  2026-09-22T12:35:14.149382+0000
client.crash                     aes256k  2026-09-22T12:35:11.553033+0000
client.csi-cephfs-node           aes      2026-09-06T14:02:07.483024+0000
client.csi-cephfs-node.2         aes256k  2026-09-22T13:31:43.190850+0000
client.csi-cephfs-provisioner    aes      2026-09-06T14:02:06.907290+0000
client.csi-cephfs-provisioner.2  aes256k  2026-09-22T13:31:39.996168+0000
client.csi-rbd-node              aes      2026-09-06T14:02:06.360068+0000
client.csi-rbd-node.2            aes256k  2026-09-22T13:31:37.063359+0000
client.csi-rbd-provisioner       aes      2026-09-06T14:02:05.797046+0000
client.csi-rbd-provisioner.2     aes256k  2026-09-22T13:31:33.967670+0000
client.rbd-mirror-peer           aes      2026-09-06T14:02:19.290352+0000
mgr.a                            aes256k  2026-09-22T12:35:27.696028+0000
mgr.b                            aes256k  2026-09-22T12:35:55.321008+0000

===== CSI KEY TYPES =====
client.csi-cephfs-node           aes      2026-09-06T14:02:07.483024+0000
client.csi-cephfs-node.2         aes256k  2026-09-22T13:31:43.190850+0000
client.csi-cephfs-provisioner    aes      2026-09-06T14:02:06.907290+0000
client.csi-cephfs-provisioner.2  aes256k  2026-09-22T13:31:39.996168+0000
client.csi-rbd-node              aes      2026-09-06T14:02:06.360068+0000
client.csi-rbd-node.2            aes256k  2026-09-22T13:31:37.063359+0000
client.csi-rbd-provisioner       aes      2026-09-06T14:02:05.797046+0000
client.csi-rbd-provisioner.2     aes256k  2026-09-22T13:31:33.967670+0000


echo '===== CEPH TOOLBOX ====='
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s

echo
echo '===== CSI CEPHX KEY TYPES ====='
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph auth dump-keys --format=json |
jq -r '
  .data.secrets[] |
  select(.entity.type_str == "client" and (.entity.id | startswith("csi-"))) |
  [
    "client." + .entity.id,
    .auth.key.type_str,
    .auth.key.created
  ] | @tsv
' | column -t
===== CEPH TOOLBOX =====
  cluster:
    id:     876327be-c95c-448e-a08b-b2fb4c8ecb7e
    health: HEALTH_WARN
            5 auth client entities with insecure key types
            Monitors are configured to allow auth using insecure key types
            Monitors are configured to allow creation of insecure key types
            4 rotating auth service keys using insecure key types
 
  services:
    mon: 3 daemons, quorum t,s,v (age 14m) [leader: t]
    mgr: b(active, since 62m), standbys: a
    mds: 1/1 daemons up, 1 hot standby
    osd: 3 osds: 3 up (since 59m), 3 in (since 3d)
 
  data:
    volumes: 1/1 healthy
    pools:   4 pools, 81 pgs
    objects: 41.89k objects, 130 GiB
    usage:   392 GiB used, 5.1 TiB / 5.5 TiB avail
    pgs:     81 active+clean
 
  io:
    client:   1.1 KiB/s rd, 790 KiB/s wr, 1 op/s rd, 12 op/s wr
 

===== CSI CEPHX KEY TYPES =====
client.csi-cephfs-node           aes      2026-09-06T14:02:07.483024+0000
client.csi-cephfs-node.2         aes256k  2026-09-22T13:31:43.190850+0000
client.csi-cephfs-provisioner    aes      2026-09-06T14:02:06.907290+0000
client.csi-cephfs-provisioner.2  aes256k  2026-09-22T13:31:39.996168+0000
client.csi-rbd-node              aes      2026-09-06T14:02:06.360068+0000
client.csi-rbd-node.2            aes256k  2026-09-22T13:31:37.063359+0000
client.csi-rbd-provisioner       aes      2026-09-06T14:02:05.797046+0000
client.csi-rbd-provisioner.2     aes256k  2026-09-22T13:31:33.967670+0000


###### if everything looks good:

kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p '
spec:
  security:
    cephx:
      csi:
        keepPriorKeyCountMax: 0
'

###### prevent any aes key generation

ceph auth del client.rbd-mirror-peer
ceph mon set auth_service_cipher aes256k
ceph config set mon mon_auth_allow_insecure_key false

###### and finally

echo "===== CURRENT MON AUTH CIPHERS ====="
ceph mon dump | grep -E 'auth_(allowed|preferred|service)_cipher'

echo
echo "===== DISABLE AES FOR CEPHX AUTHENTICATION ====="
ceph mon set auth_allowed_ciphers aes256k

echo
echo "===== VERIFY MON AUTH CIPHERS ====="
ceph mon dump | grep -E 'auth_(allowed|preferred|service)_cipher'

echo
echo "===== HEALTH ====="
ceph health detail

echo
echo "===== STATUS ====="
ceph -s