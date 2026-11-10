#!/usr/bin/env bash
# fleet-health -- on micro, daily: every machine's health in one report, $OPS/micro-fleet-health-<date>.log
# (station-maintenance fleet 14; Ben 2026-11-10). Read-only: it reads each host over ssh (the peer key, no agent) and the
# logs the other chores keep there (cpu-temp, tailnet-paths). PROBLEM and NEWS lines are what count: when their set
# differs from the last report's, exit 75 so chore-run notifies; otherwise quiet (quiet-ok).
#
#   PROBLEM  unreachable, failed units (system or user), a filesystem >= 90 %, CPU >= 85 C in the last day, kernel
#            memory errors (EDAC/MCE) in the last day, the last fpush apply rc != 0
#   NOTE     reboot pending (running kernel's modules gone), the last fpush's age, journal errors in the last day,
#            tailnet address moves yesterday, SMART not watched (no smartd)
#   NEWS     Arch news newer than the fleet's pinned repo-date: manual interventions are announced there, so read
#            them before the next fpush moves the date (Ben 2026-11-10: "put it in the fleet health report")
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
OPS=${OPS:-$HOME/.local/state/ops}
hosts=${FLEET_HEALTH_HOSTS:-micro beast-arch carbon media-center surfboard}
self=$(uname -n)
out=$OPS/$self-fleet-health-$(date +%F).log
prev=$(ls "$OPS/$self"-fleet-health-*.log 2>/dev/null | grep -v -- "-$(date +%F).log" | tail -1)

# Run on each host by `bash -s`: plain KEY VALUE lines.
probe() { cat <<'P'
h=$(uname -n); ops=${OPS:-$HOME/.local/state/ops}
# each failed unit with the time it failed: a weekly unit stays "failed" until its next run
for u in '' --user; do
  echo "failed-$([ -n "$u" ] && echo user || echo system) $(systemctl $u --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | while read -r n; do
    printf '%s(%s) ' "$n" "$(date -d "$(systemctl $u show -p StateChangeTimestamp --value "$n")" '+%m-%d %H:%M' 2>/dev/null)"; done)"
done
df -P -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {sub("%","",$5); if ($5+0 >= 90) print "disk-full " $6 " " $5 "%"}'
since=$(date -d '-1 day' +%Y-%m-%dT%H:%M)
[ -f "$ops/$h-cpu-temp.log" ] && echo "temp-max $(awk -v s="$since" '$1 >= s && $2 ~ /^[0-9]+$/ { if ($2 > m) m = $2 } END { print m+0 }' "$ops/$h-cpu-temp.log")"
echo "mem-errors $(journalctl -k --since -1d -q --no-pager 2>/dev/null | grep -ciE 'hardware error|machine check events|EDAC.*(error|[^a-z]CE[^a-z]|[^a-z]UE[^a-z])')"
echo "journal-errors $(journalctl -p err --since -1d -q --no-pager 2>/dev/null | wc -l)"
[ -d "/usr/lib/modules/$(uname -r)" ] || echo "reboot-pending $(uname -r)"
[ -f ~/.local/state/fleet/applied ] && echo "applied $(cut -d' ' -f4,5 ~/.local/state/fleet/applied)"
[ -f "$ops/$h-tailnet-paths.log" ] && echo "tailnet $(grep '^== ' "$ops/$h-tailnet-paths.log" | tail -1 | sed 's/^== //')"
systemctl is-active --quiet smartd 2>/dev/null || echo "no-smartd"
P
}

{
echo "fleet health $(date '+%F %H:%M') from $self"
for h in $hosts; do
  if [[ $h == "$self" ]]; then r=$(probe | bash -s 2>/dev/null)
  else r=$(probe | SSH_AUTH_SOCK= ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" bash -s 2>/dev/null) || r=; fi
  echo "== $h"
  if [[ -z $r ]]; then echo "PROBLEM $h: unreachable"; continue; fi
  while read -r k v; do
    case $k in
      failed-system|failed-user) [[ -n $v ]] && echo "PROBLEM $h: ${k#failed-} units failed: $v" ;;
      disk-full)      echo "PROBLEM $h: filesystem $v full" ;;
      temp-max)       (( v >= 85 )) && echo "PROBLEM $h: CPU reached $v C in the last day" || echo "ok      $h: CPU max $v C" ;;
      mem-errors)     (( v > 0 )) && echo "PROBLEM $h: $v kernel memory-error lines in the last day (EDAC/MCE)" ;;
      journal-errors) echo "NOTE    $h: $v journal error lines in the last day" ;;
      reboot-pending) echo "NOTE    $h: reboot pending (running $v; its modules are gone)" ;;
      applied)        set -- $v
                      [[ $2 == rc=0 ]] || echo "PROBLEM $h: last fpush apply ${2} ($1)"
                      echo "NOTE    $h: last fpush applied $1 ($(( ( $(date +%s) - $(date -d "$1" +%s) ) / 86400 )) days ago)" ;;
      tailnet)        echo "NOTE    $h: tailnet $v" ;;
      no-smartd)      echo "NOTE    $h: SMART not watched (no smartd)" ;;
    esac
  done <<<"$r"
done

# Arch news newer than the pinned date of the last approved snapshot (what the fleet runs).
snaps=${FLEET_SNAPSHOTS:-$HOME/.local/state/fleet/snapshots}
ab=$(tail -1 "$snaps" 2>/dev/null | cut -d' ' -f2)
pinned=$(git -C "$repo" show "${ab:-HEAD}:repo-date" 2>/dev/null)
echo "== Arch news since the fleet's repo-date (${pinned:-unknown})"
if [[ -n $pinned ]] && feed=$(curl -fsS -m 30 https://archlinux.org/feeds/news/); then
  python3 -I -c '
import sys, email.utils, xml.etree.ElementTree as ET
since = sys.argv[1]
for i in ET.fromstring(sys.stdin.read()).iter("item"):
    d = email.utils.parsedate_to_datetime(i.findtext("pubDate")).strftime("%Y-%m-%d")
    if d >= since: print("NEWS   ", d, i.findtext("title"), i.findtext("link"))
' "$pinned" <<<"$feed"
else echo "NOTE    news not read (no repo-date, or archlinux.org did not answer)"; fi
} > "$out"

keys() { grep -E '^(PROBLEM|NEWS)' "$1" 2>/dev/null | sort; }
n=$(keys "$out" | grep -c ^PROBLEM); news=$(keys "$out" | grep -c ^NEWS)
new=$(comm -13 <(keys "${prev:-/dev/null}") <(keys "$out") | wc -l)
summary="fleet health: $n problem(s), $news news item(s); $new new since the last report -- $out"
if (( new )); then
  comm -13 <(keys "${prev:-/dev/null}") <(keys "$out") | head -5
  echo "$summary"; exit 75
fi
echo "$summary"
