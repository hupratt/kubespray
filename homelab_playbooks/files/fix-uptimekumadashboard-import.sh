# Fix preload
sed -i 's/"preload": false/"preload": true/' Uptime\ Kuma\ -\ SLA_Latency_Certs-1772365531442.json

# Fix instant/range queries
sed -i 's/"instant": true/"instant": false/g; s/"range": false/"range": true/g' Uptime\ Kuma\ -\ SLA_Latency_Certs-1772365531442.json

# Fix datasource UIDs (replace both with your actual UID)
sed -i 's/PBFA97CFB590B2093/YOUR_UID_HERE/g; s/ef4dbp74n22gwe/YOUR_UID_HERE/g' Uptime\ Kuma\ -\ SLA_Latency_Certs-1772365531442.json


sed -i 's/YOUR_UID_HERE/prometheus/g' Uptime\ Kuma\ -\ SLA_Latency_Certs-1772365531442.json