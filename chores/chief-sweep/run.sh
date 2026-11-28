#!/usr/bin/env bash
# chief-sweep -- twice a day on micro: the chief of staff's sweep (station-maintenance fleet 53; Ben 2026-11-27:
# "you are the chief of staff on micro ... go ahead with 53").
# 1. Gathers the facts, read-only, into $OPS/micro-chief-sweep-<date>-<HHMM>.facts: every machine's agents (herdr),
#    the inbox mail waiting for the chief of staff (chief-of-staff@beast-arch / @media-center), scripts waiting for Ben,
#    and the newest fleet-health report.
# 2. Prompts the station-maintenance agent on micro (a live Claude session: it has the Artifact tool, which a headless
#    `claude -p` does not) to read them, settle what decisions.md already answers, route the rest, and republish
#    Ben's brief. It prompts only an idle pane Ben is not looking at, so it never types into his conversation; it
#    retries every 10 min for 2 h, then gives up with a 🔖 and exit 75.
# Read-only everywhere except that one prompt. Offline machines are skipped and named.
set -uo pipefail
OPS=${OPS:-$HOME/.local/state/ops}
export PATH=$HOME/.local/bin:$PATH
hosts=${CHIEF_SWEEP_HOSTS:-beast-arch carbon media-center surfboard}
self=$(uname -n)
facts=$OPS/$self-chief-sweep-$(date +%F-%H%M).facts
sm='~/projects/station-maintenance'

agents() {  # herdr agents on one machine: pane, repo, status (muse = queue headings, skipped)
  jq -r '.result.agents[] | select(.agent != "muse") | "\(.pane_id) \(.cwd | split("/") | last) \(.agent) \(.agent_status)\(if .focused then " (focused)" else "" end)"' 2>/dev/null
}
{
  echo "chief-sweep facts $(date '+%F %H:%M') from $self"
  echo; echo "== agents"
  echo "-- $self"; herdr agent list 2>/dev/null | agents
  for h in $hosts; do
    echo "-- $h"
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$h" '.local/bin/herdr agent list 2>/dev/null || herdr agent list' 2>/dev/null | agents || echo "(offline or no herdr)"
  done
  echo; echo "== mail for the chief of staff (ack each once handled)"
  for h in beast-arch media-center; do
    echo "-- $h"
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$h" "cd $sm && bin/inbox list chief-of-staff --full" 2>/dev/null || echo "(offline)"
  done
  echo; echo "== scripts waiting for Ben (NEEDS-BEN, no log yet)"
  for h in $self $hosts; do
    p='o=${OPS:-$HOME/.local/state/ops}; for s in "$o"/*.sh; do [ -f "$s" ] || continue; w=$(sed -n "s/^# NEEDS-BEN: *//p" "$s" | head -1); [ -n "$w" ] && [ ! -e "${s%.sh}.log" ] && echo "$(basename "$s")|$w"; done; true'
    if [[ $h == "$self" ]]; then r=$(bash -c "$p"); else r=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$h" "bash -c $(printf %q "$p")" 2>/dev/null) || r="(offline)"; fi
    [[ -n $r ]] && sed "s/^/$h: /" <<<"$r"
  done
  echo; echo "== newest fleet-health report"
  f=$(ls -t "$OPS/$self"-fleet-health-*.log 2>/dev/null | head -1)
  [[ -n $f ]] && { echo "($f)"; grep -E '^(PROBLEM|NEWS|NOTE)' "$f"; } || echo "(none)"
  echo; echo "== dev-progress dashboard data (devprog.py on beast-arch)"
  dp=$OPS/$self-chief-sweep-devprog
  mkdir -p "$dp" && scp -q -o ConnectTimeout=8 -o BatchMode=yes "$(dirname "$(readlink -f "$0")")/devprog.py" beast-arch:/tmp/devprog.py \
    && ssh -o ConnectTimeout=8 -o BatchMode=yes beast-arch 'python3 /tmp/devprog.py /tmp' \
    && scp -q -o BatchMode=yes beast-arch:/tmp/devprog-repos.json beast-arch:/tmp/devprog-activity.json "$dp/" \
    && echo "$dp/devprog-repos.json $dp/devprog-activity.json" || echo "(beast-arch offline: dashboard not refreshed)"
} >"$facts" 2>&1
[[ ${CHIEF_SWEEP_NO_PROMPT:-0} == 1 ]] && { echo "facts only (CHIEF_SWEEP_NO_PROMPT): $facts"; exit 0; }

msg="Chief-of-staff sweep: the facts are in $facts. Read them with decisions.md and the fleet index; settle and route what decisions.md already answers (inbox, ack each chief-of-staff message you handled); republish Ben's brief (the brief.html Artifact, edition +1); if the facts list devprog JSON files, upload them to the dev-progress dashboard (https://claude.ai/artifact/Tx1dPdoPrGB2kZ333zrvi8) and point its repos and activity datasets at the new uploads (update, with updated.at) with only real decisions under Needs you; flag yourself 🔖 only if there is a new decision for Ben. Read-only otherwise: no pushes, no root, nothing new decided. Log one line in fleet 53."
pane() {  # the station-maintenance agent here, if idle and not in front of Ben
  herdr agent list 2>/dev/null | jq -r '[.result.agents[] | select(.agent == "claude" and (.cwd | endswith("/station-maintenance")))] | sort_by(.pane_id) | .[0] | select(. != null) | "\(.pane_id) \(.agent_status) \(.focused)"'
}
for try in $(seq 12); do
  read -r p st foc <<<"$(pane)"
  [[ -z ${p:-} ]] && { echo "no station-maintenance agent on $self: facts left in $facts"; exit 75; }
  if [[ $st == idle && $foc != true ]]; then
    agent-prompt "$p" "$msg" && { echo "prompted the station-maintenance agent ($p) with $facts"; exit 0; }
  fi
  sleep 600
done
herdr-queues revisit "$p" on >/dev/null 2>&1
echo "the station-maintenance agent ($p) stayed busy or in front of Ben for 2 h: sweep not run; facts in $facts"
exit 75
