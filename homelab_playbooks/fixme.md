# fix me for next cluster bootstrap

Compiled all the manual steps that i didn't automate yet

## backup steps missing: 

```
mkdir /mnt/backupoutput
setfacl -m u:fedora-backup:rwx /mnt/backupoutput
setfacl -m d:u:fedora-backup:rwx /mnt/backupoutput

k apply -f files/backup-clusterrole.yml 
```

## postgres steps missing

```
for db in grafana linkwarden netbox authentik makita invidious paperless harbor_core harbor_notary_server harbor_notary_signer harbor_trivy booking; do
  psql -U postgres -d $db -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fedora_backup_user;"
  psql -U postgres -d $db -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO fedora_backup_user;"
  psql -U postgres -d $db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO fedora_backup_user;"
done

psql -U postgres -d authentik -c "GRANT USAGE ON SCHEMA template TO fedora_backup_user;"
psql -U postgres -d authentik -c "GRANT SELECT ON ALL TABLES IN SCHEMA template TO fedora_backup_user;"
psql -U postgres -d authentik -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA template TO fedora_backup_user;"
psql -U postgres -d authentik -c "ALTER DEFAULT PRIVILEGES IN SCHEMA template GRANT SELECT ON TABLES TO fedora_backup_user;"

psql -U postgres -d grafana -c "SELECT has_table_privilege('fedora_backup_user', 'public.alert', 'SELECT');
```

## mongo steps missing

```
db.createUser({
  user: "fedora_backup_user",
  pwd: "REPLACE_WITH_STRONG_PASSWORD",
  roles: [
    { role: "backup", db: "admin" }
  ]
})

db.users.findOne({ username: "fedora_backup_user" })
```