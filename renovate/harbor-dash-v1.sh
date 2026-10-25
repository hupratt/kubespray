#!/usr/bin/env bash
# harbor-dash-v1.sh — repos, tags & vulnerabilities from a Harbor registry
set -euo pipefail

# load creds from an env file if present (script dir, then home)
for f in "$(dirname "$0")/.harbor.env" "$HOME/.harbor.env"; do
  [ -f "$f" ] && . "$f" && break
done

: "${HARBOR_URL:?set HARBOR_URL, e.g. https://harbor.thekor.eu}"
: "${HARBOR_USER:?set HARBOR_USER (user or robot\$name)}"
: "${HARBOR_PASS:?set HARBOR_PASS}"
API="${HARBOR_URL%/}/api/v2.0"
AUTH=(-u "$HARBOR_USER:$HARBOR_PASS")

b=$'\e[1m'; d=$'\e[2m'; g=$'\e[32m'; y=$'\e[33m'; r=$'\e[31m'; c=$'\e[36m'; x=$'\e[0m'
curlj() { curl -fsS "${AUTH[@]}" -H 'accept: application/json' "$@"; }

# paginated list endpoint -> one compact JSON object per line
hlist() {
  local path="$1" page=1 chunk n sep
  while :; do
    [[ $path == *\?* ]] && sep='&' || sep='?'
    chunk=$(curlj "$API/$path${sep}page=$page&page_size=100") || break
    n=$(jq 'length' <<<"$chunk"); [ "$n" -eq 0 ] && break
    jq -c '.[]' <<<"$chunk"
    [ "$n" -lt 100 ] && break
    page=$((page+1))
  done
}

hb_ver=$(curlj "$API/systeminfo" | jq -r '.harbor_version // "unknown"')
proj_n=$(hlist projects | wc -l | tr -d ' ')

# one TSV row per repo: repo  tag  pushed  status  crit high med low
rows=$(
  hlist repositories | while read -r repo; do
    full=$(jq -r '.name' <<<"$repo"); proj=${full%%/*}; rest=${full#*/}
    enc=$(jq -rn --arg s "$rest" '$s|@uri')
    art=$(curlj "$API/projects/$proj/repositories/$enc/artifacts?with_scan_overview=true&with_tag=true&page_size=1&sort=-push_time" 2>/dev/null) || art='[]'
    jq -r --arg full "$full" '
      .[0] // empty | . as $a
      | ($a.tags[0].name // "<none>")                                   as $tag
      | (($a.push_time // "")[0:10])                                    as $pt
      | (if $a.scan_overview then ($a.scan_overview|to_entries[0].value) else {} end) as $s
      | ($s.scan_status // "n/a")                                       as $st
      | ($s.summary.summary // {})                                      as $v
      | [$full,$tag,$pt,$st,($v.Critical//0),($v.High//0),($v.Medium//0),($v.Low//0)]|@tsv
    ' <<<"$art"
  done
)

repo_n=$(printf '%s\n' "$rows" | grep -c . || true)

printf '%s\n' "$rows" | sort -t$'\t' -k5,5nr -k6,6nr -k1,1 | gawk -F'\t' \
  -v b="$b" -v d="$d" -v g="$g" -v y="$y" -v r="$r" -v c="$c" -v x="$x" \
  -v ver="$hb_ver" -v projn="$proj_n" -v repon="$repo_n" '
{
  n++; repo[n]=$1; tag[n]=$2; pt[n]=$3; st[n]=$4;
  cr[n]=$5; hi[n]=$6; me[n]=$7; lo[n]=$8;
  tC+=$5; tH+=$6; tM+=$7; tL+=$8;
  if ($5>0) critRepos++;
  if ($4!="Success") unscanned++;
  if ($2 ~ /^(latest|stable|<none>)$/) mut[n]=1;
}
END{
  printf "%s╭─ Harbor Dashboard ────────────────────────────────╮%s\n", c, x;
  printf "  version %s%s%s   projects %s%s%s   repos %s%s%s\n", b,ver,x, b,projn,x, b,repon,x;
  printf "  vulns  %sC:%d%s  %sH:%d%s  M:%d  L:%d   unscanned %s%d%s\n",
         r,tC,x, y,tH,x, tM, tL, y,unscanned,x;
  printf "%s╰───────────────────────────────────────────────────╯%s\n\n", c, x;

  printf "%s%sImages & vulnerabilities%s\n", b, g, x;
  for(i=1;i<=n;i++){
    col = (cr[i]>0)? r : (hi[i]>0)? y : (me[i]+lo[i]>0)? g : d;
    printf "%-46s %-12s %s  %sC:%-2d H:%-2d M:%-2d L:%-2d%s [%s]\n",
      repo[i], tag[i], pt[i], col, cr[i],hi[i],me[i],lo[i], x, st[i];
  }

  printf "\n%s%sMutable tags (drift risk)%s\n", b, d, x;
  for(i=1;i<=n;i++) if(mut[i]) printf "%-46s -> %s\n", repo[i], tag[i];

  printf "\n%s%sWarnings%s\n", b, r, x;
  for(i=1;i<=n;i++){
    if(cr[i]>0) printf "%s✗ %s: %d critical CVE(s) in %s%s\n", r, repo[i], cr[i], tag[i], x;
    else if(st[i]!="Success" && st[i]!="n/a") printf "%s! %s: scan %s%s\n", y, repo[i], st[i], x;
  }
}'