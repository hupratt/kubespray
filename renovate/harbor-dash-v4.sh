
for f in "$(dirname "$0")/.harbor.env" "$HOME/.harbor.env"; do
  [ -f "$f" ] && . "$f" && break
done
API="${HARBOR_URL%/}/api/v2.0"; AUTH=(-u "$HARBOR_USER:$HARBOR_PASS")

# 1) list all projects
curl -fsS "${AUTH[@]}" "$API/projects?page_size=100" \
  | jq -r '.[] | "\(.project_id)\t\(.name)"' | while IFS=$'\t' read -r pid pname; do

    # 2) list repos in THIS project (paginated), print count>0 with tags
    page=1
    while :; do
      chunk=$(curl -fsS "${AUTH[@]}" \
        "$API/projects/$pname/repositories?page=$page&page_size=100") || break
      n=$(jq 'length' <<<"$chunk"); [ "$n" -eq 0 ] && break
      jq -r '.[] | select(.artifact_count>0) | "\(.artifact_count)\t\(.name)"' <<<"$chunk"
      [ "$n" -lt 100 ] && break
      page=$((page+1))
    done
done

