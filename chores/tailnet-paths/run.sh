#!/usr/bin/env bash
# tailnet-paths -- once a day, yesterday's tailscale path renegotiations per hour plus a netcheck, appended to
# $OPS/<host>-tailnet-paths.log (station-maintenance beast-arch 147; Ben 2026-11-08). The journal is purged to 14 days
# (log-purge), so this log is where the trend survives.
set -uo pipefail
log="${OPS:-$HOME/.local/state/ops}/$(uname -n)-tailnet-paths.log"; mkdir -p "${log%/*}"
day=$(date -d yesterday +%F)
grep -qs "^== $day" "$log" && { echo "$day already logged"; exit 0; }
hours=$(journalctl -u tailscaled --since "$day 00:00" --until "$day 23:59:59" -q --no-pager -o short-iso 2>/dev/null \
  | grep 'now using' | cut -c12-13 | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')
total=$(awk '{for(i=1;i<=NF;i++){split($i,a,":"); s+=a[2]}} END{print s+0}' <<<"$hours")
{ echo "== $day  path changes: $total"
  echo "  by hour: ${hours:-none}"
  tailscale netcheck 2>/dev/null | grep -E 'UDP|IPv4|MappingVariesByDestIP|Nearest DERP' | sed 's/^/  /'
} >> "$log"
echo "$day: $total path changes"
