#!/usr/bin/env bash
# claude-restart -- /restart each idle Claude Code session in a herdr pane that runs an older version than the one
# installed, so "update installed, /restart to apply" clears itself (Ben 2026-11-08). Every 10 minutes.
# Only a pane's own session (a claude whose parent is a shell); the daemon's background sessions (parent: a bg-pty-host)
# are left alone. Only when herdr says the agent is idle or done, never working or blocked. A claude outside herdr
# (a plain terminal) cannot be reached and is only counted. --dry-run: say what would be restarted.
# Ceiling: a prompt typed but not sent in an idle session would be submitted with the /restart; none of the panes
# shows a draft to herdr's state.
set -uo pipefail
dry=0; [[ ${1:-} == --dry-run ]] && dry=1
herdr=$HOME/.local/bin/herdr
cur=$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null) || { echo "no claude installed"; exit 0; }
vdir=$HOME/.local/share/claude/versions
declare -A stale=()   # pane -> version
outside=0
for e in /proc/[0-9]*/exe; do
  x=$(readlink "$e" 2>/dev/null) || continue
  [[ $x == "$vdir"/* && $x != "$cur" ]] || continue
  p=${e#/proc/}; p=${p%/exe}
  pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || continue
  [[ $(cat "/proc/$pp/comm" 2>/dev/null) =~ ^(zsh|bash|sh|fish)$ ]] || continue
  pane=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^HERDR_PANE_ID=//p')
  if [[ -n $pane ]]; then stale[$pane]=${x##*/}; else outside=$((outside+1)); fi
done
# `herdr agent prompt PANE /restart` typed the command but left it unsent (beast-arch wR:p1, 2026-11-08): the Enter
# went to the slash-command menu. So: type it, then Enter, and Enter again while the prompt line still holds it.
restart() {
  "$herdr" agent read "$1" 2>/dev/null | grep -q '^❯ /restart *$' || "$herdr" pane send-text "$1" /restart >/dev/null || return 1
  local i; for i in 1 2 3; do
    sleep 1; "$herdr" agent send-keys "$1" Enter >/dev/null || return 1; sleep 2
    "$herdr" agent read "$1" 2>/dev/null | grep -q '^❯ /restart *$' || return 0
  done
  echo "note: $1 still shows /restart unsent"; return 1
}
done_n=0 busy=0
if (( ${#stale[@]} )) && [[ -x $herdr ]]; then
  states=$("$herdr" agent list 2>/dev/null | jq -r '.result.agents[] | "\(.pane_id) \(.agent_status)"')
  for pane in "${!stale[@]}"; do
    st=$(awk -v p="$pane" '$1 == p {print $2}' <<<"$states")
    if [[ $st == idle || $st == done ]]; then
      if (( dry )); then echo "would restart $pane (${stale[$pane]}, $st)"
      else restart "$pane" && echo "restarted $pane (was ${stale[$pane]})"; fi
      done_n=$((done_n+1))
    else busy=$((busy+1)); fi
  done
fi
(( dry )) && w="to restart" || w=restarted
echo "claude ${cur##*/}: $done_n $w, $busy busy (next pass), $outside outside herdr"
