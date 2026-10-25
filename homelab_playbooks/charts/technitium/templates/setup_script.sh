# you'll need to disable resolved otherwise technitium can't listen on the port 53

kubectl -n kube-system patch ds node-local-dns \
  --type='json' \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/affinity",
      "value": {
        "nodeAffinity": {
          "requiredDuringSchedulingIgnoredDuringExecution": {
            "nodeSelectorTerms": [
              {
                "matchExpressions": [
                  {
                    "key": "kubernetes.io/hostname",
                    "operator": "NotIn",
                    "values": ["coreos-wk-4"]
                  }
                ]
              }
            ]
          }
        }
      }
    }
  ]'

/etc/systemd/resolved.conf                                                                      
[Resolve]
DNSStubListener=no


systemctl restart systemd-resolved

nmcli con edit private
set ipv4.dns
set ipv4.dns 10.10.85.24 
save

editing /etc/resolv.conf won't persist accross reboots