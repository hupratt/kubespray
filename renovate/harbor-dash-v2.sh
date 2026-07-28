#!/usr/bin/env bash
# harbor-dash-v2.sh — "available updates" table from tags held in Harbor
set -euo pipefail

# increase retention period

# curl -fsS -u "$HARBOR_USER:$HARBOR_PASS" \
#   -X PUT -H 'Content-Type: application/json' \
#   "$HARBOR_URL/api/v2.0/retentions/6" \
#   -d '{
#     "algorithm": "or",
#     "rules": [{
#       "action": "retain",
#       "template": "nDaysSinceLastPull",
#       "params": { "nDaysSinceLastPull": 3650 },
#       "scope_selectors": { "repository": [{ "decoration": "repoMatches", "kind": "doublestar", "pattern": "**" }] },
#       "tag_selectors": [{ "decoration": "matches", "kind": "doublestar", "pattern": "**" }]
#     }],
#     "scope": { "level": "project", "ref": 7 },
#     "trigger": { "kind": "Schedule", "settings": { "cron": "0 0 0 * * *" } }
#   }'

# load creds from an env file if present (script dir, then home)
for f in "$(dirname "$0")/.harbor.env" "$HOME/.harbor.env"; do
  [ -f "$f" ] && . "$f" && break
done

: "${HARBOR_URL:?}"; : "${HARBOR_USER:?}"; : "${HARBOR_PASS:?}"
API="${HARBOR_URL%/}/api/v2.0"; AUTH=(-u "$HARBOR_USER:$HARBOR_PASS")
CURFILE="${1:-}"

g=$'\e[32m'; y=$'\e[33m'; r=$'\e[31m'; b=$'\e[1m'; x=$'\e[0m'
curlj(){ curl -fsS "${AUTH[@]}" -H 'accept: application/json' "$@"; }

hlist(){ local p="$1" pg=1 ch n s; while :; do
  [[ $p == *\?* ]] && s='&' || s='?'
  ch=$(curlj "$API/$p${s}page=$pg&page_size=100")||break
  n=$(jq 'length' <<<"$ch"); [ "$n" -eq 0 ] && break
  jq -c '.[]' <<<"$ch"; [ "$n" -lt 100 ] && break; pg=$((pg+1)); done; }

# emit "repo<TAB>tag" for every tag Harbor holds
{
  hlist repositories | while read -r repo; do
    full=$(jq -r '.name' <<<"$repo"); proj=${full%%/*}; rest=${full#*/}
    enc=$(jq -rn --arg s "$rest" '$s|@uri')
    curlj "$API/projects/$proj/repositories/$enc/artifacts?with_tag=true&page_size=100" 2>/dev/null \
      | jq -r --arg f "$full" '.[].tags[]?.name | "\($f)\t\(.)"'
  done
} | gawk -F'\t' -v g="$g" -v y="$y" -v r="$r" -v b="$b" -v x="$x" -v curfile="$CURFILE" '
  # ---- semver helpers ----
  function norm(t,  s){ s=t; sub(/^v/,"",s); return s }
  function parts(t,a,  s){ s=norm(t); split(s,a,/[.\-_]/); a[1]+=0; a[2]+=0; a[3]+=0 }
  function isver(t){ return norm(t) ~ /^[0-9]+([.\-_][0-9].*)?$/ }
  # returns 1 if x is a strictly higher version than y
  function gt(xx,yy, ax,ay){ parts(xx,ax); parts(yy,ay);
    if(ax[1]!=ay[1]) return ax[1]>ay[1];
    if(ax[2]!=ay[2]) return ax[2]>ay[2];
    return ax[3]>ay[3] }
  function utype(cur,new, ac,an){ parts(cur,ac); parts(new,an);
    if(an[1]>ac[1]) return "major";
    if(an[2]>ac[2]) return "minor";
    return "patch" }
  BEGIN{
    if(curfile!=""){ while((getline l < curfile)>0){ split(l,f,/[ \t]+/); cur[f[1]]=f[2] } }
  }
  {
    repo=$1; tag=$2; if(!isver(tag)) next; seen[repo]=1
    if(!(repo in hi) || gt(tag,hi[repo])){ prev[repo]=hi[repo]; hi[repo]=tag }
    else if((!(repo in prev) || gt(tag,prev[repo])) && gt(hi[repo],tag)) prev[repo]=tag
  }
  END{
    printf "%s%sAvailable updates%s\n", b,g,x
    for(repo in seen){
      new=hi[repo]
      base=(repo in cur)? cur[repo] : prev[repo]
      if(base=="" || !gt(new,base)) continue
      t=utype(base,new)
      col=(t=="major")?r:(t=="minor")?y:g
      out[repo]=sprintf("%-52s %-12s -> %-10s %s[%s]%s", repo, base, new, col, t, x)
    }
    n=asorti(out,idx)
    for(i=1;i<=n;i++) print out[idx[i]]
  }'