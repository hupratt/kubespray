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
psql -Upostgres harbor-core < harbor_core_20260530.bak
psql -Upostgres harbor-notary-server < harbor_notserver_20260530.bak
psql -Upostgres harbor-notary-signer < harbor_notsign_20260530.bak
psql -Upostgres harbor-trivy < harbor_triv_20260530.bak
psql -Upostgres linkwarden < linkwarden_20260530.bak
psql -Upostgres makita < makita_20260530.bak
psql -Upostgres netbox < netbox_20260530.bak
psql -Upostgres paperless < paperless_20260530.bak
psql -Upostgres patchmon < patchmon_20260530.bak



cd /var/lib/postgresql/data

cat > restore_pg.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="./pg_restore_$(date +%F_%H-%M-%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting PostgreSQL restore at $(date)"

restore_db() {
  local db="$1"
  local file="$2"

  echo "Restoring $db from $file ..."

  if [[ ! -f "$file" ]]; then
    echo "ERROR: file not found: $file"
    exit 1
  fi

  psql -Upostgres "$db" < "$file"
  echo "OK: $db"
}

restore_db authentik authentik_20260530.bak
restore_db booking booking_20260530.bak
restore_db craftstudios craftstudios_20260530.bak
restore_db grafana grafana_20260530.bak
restore_db harbor-core harbor_core_20260530.bak
restore_db harbor-notary-server harbor_notserver_20260530.bak
restore_db harbor-notary-signer harbor_notsign_20260530.bak
restore_db harbor-trivy harbor_triv_20260530.bak
restore_db linkwarden linkwarden_20260530.bak
restore_db makita makita_20260530.bak
restore_db netbox netbox_20260530.bak
restore_db paperless paperless_20260530.bak
restore_db patchmon patchmon_20260530.bak

echo "All restores completed successfully at $(date)"
echo "ok"
EOF

chmod +x restore_pg.sh
./restore_pg.sh
cat pg_restore_2026-05-30_11-18-21.log | grep -i ERROR
tail -f pg_restore_2026-05-30_11-18-21.log | grep --line-buffered -i error