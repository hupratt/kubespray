## during the drain/purge
journalctl -t k8s-shutdown-watcher 
journalctl -t k8s-drain
journalctl -u k8s-node-drain.service

journalctl -t k8s-shutdown-watcher --no-pager -f
journalctl -t k8s-drain --no-pager -f
journalctl -u k8s-node-drain.service --no-pager -f

## after a reboot
journalctl -t k8s-shutdown-watcher -b -1 --no-pager
journalctl -t k8s-drain -b -1 --no-pager
journalctl -u k8s-node-drain.service -b -1 --no-pager
kubectl describe node coreos-cp-1 | grep -A2 Taints

## verify install
systemctl status k8s-node-uncordon
systemctl status k8s-node-drain.service