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
# How a /restart is sent (fixed 2026-11-08; the first version filled idle prompts with one "/restart" per run):
# - Claude Code draws the prompt as "❯" + a NO-BREAK SPACE, so a check for "❯ /restart" never matched: every run typed
#   another /restart and reported success without one being sent. The input box is now read as the lines between the
#   last two rules (─), with the prompt mark and any blanks stripped.
# - Enter is not always submit: ~/.claude/keybindings.json can bind "enter" to chat:newline (Ben's does; submit is
#   alt/shift/ctrl+enter). The submit key is read from there: the first ctrl+enter/shift+enter/alt+enter/enter bound to
#   chat:submit, else enter.
# - Any "Can't restart while ..." reply is a refusal. Background work running: retried after an hour (state bg-<pid>).
# - A session with Remote Control connected refuses: "Can't restart while Remote Control is connected". It is told once
#   per process (state file below), then skipped until that claude exits; it needs exiting and `claude` + /resume.
# - Only an EMPTY input box is used (Claude Code's dim suggestion text does not count). A box holding only "/restart" lines (left by the old version) is cleared with one
#   ctrl+c; any other text is a draft and the pane is skipped.
state=${XDG_STATE_HOME:-$HOME/.local/state}/claude-restart; mkdir -p "$state"
kb=$HOME/.claude/keybindings.json
submit=enter
if [[ -r $kb ]]; then
  for k in ctrl+enter shift+enter alt+enter enter; do
    [[ $(jq -r --arg k "$k" '[.bindings[]?|select(.context=="Chat")|.bindings[$k]?]|map(select(.!=null))|.[0]//""' "$kb" 2>/dev/null) == chat:submit ]] \
      && { submit=$k; break; }
  done
fi
# Typing "/restart" opens the slash-command menu, and while it is open the submit key does nothing (2026-11-08): the
# entry is accepted first with the menu's accept key (Autocomplete autocomplete:accept; Ben's is alt+enter, default tab).
accept=tab
if [[ -r $kb ]]; then
  a=$(jq -r '[.bindings[]?|select(.context=="Autocomplete")|.bindings|to_entries[]|select(.value=="autocomplete:accept")|.key][0]//""' "$kb" 2>/dev/null)
  [[ -n $a ]] && accept=$a
fi
nbsp=$'\xc2\xa0'   # as bytes: $'\u00a0' depends on the locale, and a chore may run without one
box() {   # the input box's text, one line per line, prompt mark and blanks stripped. Dim text (SGR 2) is Claude Code's
          # greyed-out prompt suggestion ("push it"), not a draft: dropped (seen in three panes, 2026-11-08).
  "$herdr" agent read "$1" --ansi 2>/dev/null | sed -E $'s/\x1b\\[2m[^\x1b]*//g; s/\x1b\\[[0-9;?]*[A-Za-z]//g' | awk '/^─/ {n++; last[n]=NR} {l[NR]=$0} END {for (i=last[n-1]+1; i<last[n]; i++) print l[i]}' \
    | tr -d '\r' | sed "s/^❯//; s/$nbsp/ /g; s/^ *//; s/ *\$//" | grep -v '^$'
}
claude_pid() {   # the pane's claude process
  local e p; for e in /proc/[0-9]*/environ; do
    grep -qz "^HERDR_PANE_ID=$1\$" "$e" 2>/dev/null || continue; p=${e#/proc/}; p=${p%/environ}
    [[ $(readlink "/proc/$p/exe" 2>/dev/null) == "$vdir"/* ]] && { echo "$p"; return; }
  done
}
restart() {   # 0 restarted, 2 skipped (draft), 3 refused (remote control), 1 failed
  local pane=$1 pid b i; pid=$(claude_pid "$pane")
  [[ -n $pid && -e $state/rc-$pid ]] && { echo "skip $pane: Remote Control (told before; exit and start claude again)"; return 3; }
  [[ -n $pid && -e $state/nr-$pid ]] && { echo "skip $pane: this claude has no /restart (exit and start claude again)"; return 3; }
  [[ -n $pid && -n $(find "$state/bg-$pid" -mmin -60 2>/dev/null) ]] && { echo "skip $pane: background work (refused <1h ago)"; return 2; }
  b=$(box "$pane")
  if [[ -n $b ]] && ! grep -qv '^/restart$' <<<"$b"; then "$herdr" pane send-keys "$pane" c-c >/dev/null; sleep 1; b=$(box "$pane"); fi
  [[ -z $b ]] || { echo "skip $pane: the prompt holds a draft"; return 2; }
  local refused0 why; refused0=$("$herdr" agent read "$pane" 2>/dev/null | grep -c "Can't restart while")
  "$herdr" pane send-text "$pane" /restart >/dev/null || return 1
  # The menu's highlighted entry must BE /restart before it is accepted. A claude without /restart (2.1.318 in w2:p1,
  # 2026-11-08) highlights the nearest match instead, and accepting it ran /deep-research twice in Ben's session.
  sleep 1; local sel
  sel=$("$herdr" agent read "$pane" 2>/dev/null | tr -d '\r' | sed "s/$nbsp/ /g" \
        | awk '/^─/ {n++; last[n]=NR} {l[NR]=$0} END {for (i=last[n-1]-1; i>0 && i>last[n-1]-20; i--) if (l[i] ~ /^ +❯ \//) {print l[i]; exit}}' \
        | awk '{print $2}')
  if [[ $sel != /restart ]]; then
    "$herdr" pane send-keys "$pane" c-c >/dev/null; [[ -n $pid ]] && : > "$state/nr-$pid"
    echo "skip $pane: no /restart in its menu (highlighted: ${sel:-nothing}); cleared"; return 3
  fi
  "$herdr" pane send-keys "$pane" "$accept" >/dev/null || return 1
  sleep 1; "$herdr" pane send-keys "$pane" "$submit" >/dev/null || return 1
  for i in 1 2 3 4 5 6; do
    sleep 2
    why=$("$herdr" agent read "$pane" 2>/dev/null | grep "Can't restart while")
    if (( $(grep -c . <<<"$why") > refused0 )); then
      why=$(tail -1 <<<"$why")
      if [[ $why == *"Remote Control"* ]]; then [[ -n $pid ]] && : > "$state/rc-$pid"
        echo "refused $pane: Remote Control is connected (exit, start claude, /resume)"; return 3
      fi
      [[ -n $pid ]] && : > "$state/bg-$pid"   # e.g. "work is running in the background": retried in an hour
      echo "refused $pane: ${why#*restart while }"; return 2
    fi
    [[ $(readlink "/proc/$(claude_pid "$pane")/exe" 2>/dev/null) == "$cur" ]] && return 0
  done
  echo "note: $pane: /restart sent ($accept, $submit), but the pane still runs an old claude"; return 1
}
find "$state" -name 'rc-*' -o -name 'bg-*' -o -name 'nr-*' 2>/dev/null | while read -r f; do [[ -e /proc/${f##*-} ]] || rm -f "$f"; done
done_n=0 busy=0 rc=0
if (( ${#stale[@]} )) && [[ -x $herdr ]]; then
  states=$("$herdr" agent list 2>/dev/null | jq -r '.result.agents[] | "\(.pane_id) \(.agent_status)"')
  for pane in "${!stale[@]}"; do
    st=$(awk -v p="$pane" '$1 == p {print $2}' <<<"$states")
    if [[ $st == idle || $st == done ]]; then
      if (( dry )); then echo "would restart $pane (${stale[$pane]}, $st)"
      else restart "$pane"; case $? in 0) echo "restarted $pane (was ${stale[$pane]})"; done_n=$((done_n+1));; 3) rc=$((rc+1));; esac; fi
      (( dry )) && done_n=$((done_n+1))
    else busy=$((busy+1)); fi
  done
fi
(( dry )) && w="to restart" || w=restarted
echo "claude ${cur##*/}: $done_n $w, $busy busy (next pass), $rc held by Remote Control, $outside outside herdr"
