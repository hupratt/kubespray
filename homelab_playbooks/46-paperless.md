
## backup restore
tar -czvf documents.tgz -C /home/hugo/test/hosts/paperless-media/2026-09-05T19:14:47Z/data/ documents
k cp documents.tgz paperless-paperless-ngx-847fbb844-ptd2c:/tmp -n paperless -c paperless
tar -xvzf /tmp/documents.tgz -C /usr/src/paperless/media
tar -xvzf paperless.tgz --exclude='paperless/src' --exclude='paperless/static'


## redis won't start: Fatal error loading the DB, check server logs. 

kubectl get pvc -n paperless | grep broker

kubectl run redis-fix -n paperless --restart=Never --image=busybox --overrides='
{
  "spec": {
    "containers": [{
      "name": "redis-fix",
      "image": "busybox",
      "command": ["sleep", "3600"],
      "volumeMounts": [{"mountPath": "/data", "name": "data"}]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {"claimName": "data-paperless-paperless-ngx-broker-0"} 
    }]
  }
}'

rm -f /data/dump.rdb
rm -rf /data/appendonlydir /data/appendonly.aof
exit

