#!/usr/bin/env bash
# status-push -- on micro, every 10 min: what a peer session would otherwise need a micro session to read, written to
# STATUS_PEER (beast-arch) under ~/.local/state/peer-status/<this host>/. micro is outbound-only (nothing can ssh in),
# so this is the only way an agent elsewhere sees it (station-maintenance fleet 25: the micro agent lost to collapsed
# unsorted was diagnosed blind from beast-arch). Read-only here; one ssh out, files replaced whole (tmp + mv).
#   status.txt     time, uptime, memory, failed units, the herdr agents (pane, kind, status, cwd), the chores' last outcomes
#   queues.json    this host's herdr-queues state (its own view of the shared state)
set -uo pipefail
peer=${STATUS_PEER:-beast-arch}; h=$(uname -n)
herdr=$HOME/.local/bin/herdr
status() {
  echo "# $h status, $(date -Is) (arch-bootstrap chores/status-push)"
  echo "uptime: $(uptime)"; free -h | sed -n 2p | awk '{print "memory: " $3 " used of " $2 ", " $7 " available"}'
  echo "failed units: system $(systemctl --failed --no-legend --plain | awk '{printf "%s ", $1}'); user $(systemctl --user --failed --no-legend --plain | awk '{printf "%s ", $1}')"
  echo; echo "## herdr agents"
  "$herdr" agent list 2>/dev/null | jq -r '.result.agents[] | [.pane_id, .agent, .agent_status, .cwd] | @tsv' 2>/dev/null || echo "herdr not answering"
  echo; echo "## herdr panes (queues tokens)"
  "$herdr" pane list 2>/dev/null | jq -r '.result.panes[] | [.pane_id, .terminal_id, (.agent // "-"), (.tokens.queues_rank // "-"), .terminal_title_stripped] | @tsv' 2>/dev/null
  echo; echo "## chores"
  jq -r '[.name, .status, .finished[0:16], .summary] | @tsv' "${XDG_STATE_HOME:-$HOME/.local/state}"/chores/*.json 2>/dev/null
}
q=${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/benjmhart.queues/queues.json
d=.local/state/peer-status/$h
s=$(status)
ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer" "mkdir -p $d && cat > $d/status.txt.tmp && mv $d/status.txt.tmp $d/status.txt" <<<"$s" || { echo "could not reach $peer"; exit 1; }
[[ -r $q ]] && { ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer" "cat > $d/queues.json.tmp && mv $d/queues.json.tmp $d/queues.json" <"$q" || exit 1; }
echo "pushed to $peer:~/$d ($(grep -c . <<<"$s") lines)"
