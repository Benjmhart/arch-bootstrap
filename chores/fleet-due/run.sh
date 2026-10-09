#!/usr/bin/env bash
# fleet-due -- on micro, daily: say when the fleet's packages are a week old (station-maintenance
# beast-arch 76, Ben 2026-10-09: "a chore to update all systems every week or so -- and to review
# any local holds"). Reads the last approved snapshot's repo-date; nothing is changed here, since a
# fleet update needs Ben's review and passwords. Exit 75 (needs you) when due, so chore-run
# notifies; quiet otherwise (quiet-ok).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
snaps=${FLEET_SNAPSHOTS:-$HOME/.local/state/fleet/snapshots}
days=${FLEET_DUE_DAYS:-7}
[[ -s $snaps ]] || { echo "no approved fleet snapshot yet: run fpush"; exit 75; }
read -r t ab _ <<<"$(tail -1 "$snaps")"
date=$(git -C "$repo" show "$ab:repo-date" 2>/dev/null) || { echo "fleet snapshot ${ab:0:7} has no repo-date (not pinned): run fpush"; exit 75; }
age=$(( ( $(date -d "${FLEET_TODAY:-today}" +%s) - $(date -d "$date" +%s) ) / 86400 ))
held=$(git -C "$repo" show "$ab:holds" 2>/dev/null | awk '!/^#/ && NF' | wc -l)
if (( age >= days )); then
  echo "fleet update due: packages are pinned to $date ($age days); $held held package(s) to review -- run fpush"
  exit 75
fi
echo "fleet packages at $date ($age days old, due at $days); approved $t; $held held"
