vaultwarden requires a hashed version password, not a plain one
so you'll need to make sure adminToken goes through the hashing algo
docker run --rm -it vaultwarden/server:1.37.2-alpine /vaultwarden hash


fix stuck orphaned pod after uninstall

(env) kubespray/homelab_playbooks  kubectl get deploy,pod,svc,ingress -n vaultwarden -l app.kubernetes.io/managed-by=Helm                                                          
No resources found in vaultwarden namespace.
(env) kubespray/homelab_playbooks  kubectl get deploy,pod,svc,ingress -n vaultwarden                                                                                               
NAME                             READY   STATUS   RESTARTS   AGE
pod/vaultwarden-b5747d5f-w45pm   0/1     Error    0          16h
(env) kubespray/homelab_playbooks  kubectl delete pod vaultwarden-b5747d5f-w45pm -n vaultwarden --grace-period=0 --force                                                           
Warning: Immediate deletion does not wait for confirmation that the running resource has been terminated. The resource may continue to run on the cluster indefinitely.
pod "vaultwarden-b5747d5f-w45pm" force deleted from vaultwarden namespace
(env) kubespray/homelab_playbooks       


GRANT ALL PRIVILEGES ON vaultwarden.* TO 'vaultwardenadmin'@'%';
FLUSH PRIVILEGES;

SELECT User, Host FROM mysql.user;