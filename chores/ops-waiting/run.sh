#!/usr/bin/env bash
# ops-waiting -- hourly on micro: every script on any machine that is waiting for Ben. A script for Ben carries the line
#   # NEEDS-BEN: <what it unblocks>
# and is done once its log ($OPS/<name>.log, which ops_log writes) exists on that machine. While any is waiting: list
# them, flag 🔖 the station-maintenance agent here, and exit 75 so chore-run notifies, every hour until none are left
# (station-maintenance fleet 46; Ben 2026-11-22: "Keep reminding me of these until I have run them all. These are urgent.").
# Read-only on every machine (peer-key ssh); an offline machine is skipped and named.
set -uo pipefail
hosts=${OPS_WAITING_HOSTS:-micro beast-arch carbon media-center surfboard}
self=$(uname -n)
probe='o=${OPS:-$HOME/.local/state/ops}; for s in "$o"/*.sh; do [ -f "$s" ] || continue
  w=$(sed -n "s/^# NEEDS-BEN: *//p" "$s" | head -1); [ -n "$w" ] || continue
  [ -e "${s%.sh}.log" ] || echo "$(basename "$s")|$w"; done'
n=0; off=""; list=""
for h in $hosts; do
  if [[ $h == "$self" ]]; then out=$(bash -c "$probe")
  else out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" bash -s <<<"$probe" 2>/dev/null) || { off+=" $h"; continue; }; fi
  while IFS='|' read -r s w; do [[ -n $s ]] || continue
    list+="  $h: \$OPS/$s  -- $w"$'\n'; n=$((n + 1)); done <<<"$out"
done
[[ -n $off ]] && echo "not checked (offline):$off"
if (( n == 0 )); then echo "no script is waiting for Ben"; exit 0; fi
printf 'waiting for Ben: %d script(s)\n%s' "$n" "$list"
p=$(PATH=$HOME/.local/bin:$PATH herdr agent list 2>/dev/null \
  | jq -r '[.result.agents[] | select(.agent == "claude" and (.cwd | endswith("/station-maintenance")))] | sort_by(.pane_id) | .[0].pane_id // empty')
[[ -n $p ]] && "$HOME/.local/bin/herdr-queues" revisit "$p" on >/dev/null 2>&1 && echo "flagged 🔖 the station-maintenance agent ($p)"
exit 75
