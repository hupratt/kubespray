
for f in "$(dirname "$0")/.harbor.env" "$HOME/.harbor.env"; do
  [ -f "$f" ] && . "$f" && break
done
API="${HARBOR_URL%/}/api/v2.0"; AUTH=(-u "$HARBOR_USER:$HARBOR_PASS")

full='proxy-ghcr/goauthentik/server'
proj=${full%%/*}
rest=${full#*/}
enc=$(jq -rn --arg s "$rest" '$s|@uri')

echo "proj=$proj rest=$rest enc=$enc"
curl -sS -i "${AUTH[@]}" "$API/projects/$proj/repositories/$enc"