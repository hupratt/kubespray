#!/usr/bin/env bash
# gitlab-dash.sh — usage: ./gitlab-dash.sh /home/hpratt/Documents/kubespray/homelab_playbooks/renovate-debug.log
LOG="${1:-renovate.log}"

b=$'\e[1m'; d=$'\e[2m'; g=$'\e[32m'; y=$'\e[33m'; r=$'\e[31m'; c=$'\e[36m'; x=$'\e[0m'

ver=$(grep -m1 -oP '"renovateVersion": "\K[^"]+' "$LOG")
files=$(grep -oP '"fileCount": \K[0-9]+' "$LOG" | tail -1)
deps=$(grep -oP '"depCount": \K[0-9]+' "$LOG" | tail -1)
outd=$(grep -oP '"outdated": \K[0-9]+' "$LOG" | tail -1)
ly=$(grep -oP '"libYears": \{"managers".*?"total": \K[0-9.]+' "$LOG" | tail -1)
dur=$(grep -oP '"durationMs": \K[0-9]+' "$LOG" | tail -1)

printf "%s╭─ Renovate Dashboard ──────────────────────────────╮%s\n" "$c" "$x"
printf "  version %s%s%s   files %s%s%s   deps %s%s%s   outdated %s%s%s\n" \
  "$b" "$ver" "$x" "$b" "$files" "$x" "$b" "$deps" "$x" "$y" "$outd" "$x"
printf "  tech debt %s%.1f lib-years%s   runtime %ss\n" "$r" "$ly" "$x" "$((dur/1000))"
printf "%s╰───────────────────────────────────────────────────╯%s\n\n" "$c" "$x"

printf "%s%sAvailable updates%s\n" "$b" "$g" "$x"
gawk '
  /"depName":/      { if (match($0,/"depName": "([^"]+)"/,a))      dep=a[1] }
  /"currentValue":/ { if (match($0,/"currentValue": "([^"]+)"/,a)) cur=a[1] }
  /"newVersion":/   { if (match($0,/"newVersion": "([^"]+)"/,a))   nv=a[1] }
  /"updateType":/   { if (match($0,/"updateType": "([^"]+)"/,a))
                        printf "%-52s %-12s -> %-10s [%s]\n", dep, cur, nv, a[1] }
' "$LOG" | sort -u | sed \
  -e "s/\[major\]/${r}[major]${x}/" \
  -e "s/\[minor\]/${y}[minor]${x}/" \
  -e "s/\[patch\]/${g}[patch]${x}/"

printf "\n%s%sPinned to floating tags (skipped)%s\n" "$b" "$d" "$x"
grep -oP 'Dependency \K\S+ has unsupported/unversioned value \S+' "$LOG" \
  | sort -u | sed 's| has unsupported/unversioned value | -> |'

printf "\n%s%sWarnings%s\n" "$b" "$r" "$x"
grep -oP 'WARN: \K.*' "$LOG" | sort -u