#!/usr/bin/env bash
# claude-restart -- /restart each idle Claude Code session in a herdr pane that runs an older version than the one
# installed, so "update installed, /restart to apply" clears itself (Ben 2026-11-08). Every 10 minutes.
# Only a pane's own session (a claude whose parent is a shell); the daemon's background sessions (parent: a bg-pty-host)
# are left alone. Only when herdr says the agent is idle or done, never working or blocked. A claude outside herdr
# (a plain terminal) cannot be reached and is only counted. --dry-run: say what would be restarted.
#
# Loops (Ben 2026-11-16: "orchestrate graceful loop-stops and restarts ... and get the loops back up after"): a session in
# /loop refuses /restart ("work is running in the background") for as long as it loops, so loops never upgraded. Only the
# session knows whether its subagents, watchers or shells are mid-work, so a stale looping session is asked once (state
# ask-<pid>) to stop its loop at its next safe point and end its reply with "RESTART-READY /loop ...". A later pass that
# finds that line (transcript) and the agent idle exits and resumes it on the installed version, then types the /loop
# line back (pending in relaunch-<session id> until it starts, so a failed relaunch is retried every pass).
#
# Ben 2026-11-16: "you don't need for the agent to be idle, we can stop and resume unless it will lose substantial
# work". [Superseded 2026-11-19 (Ben): no Esc and no exit; a busy or looping session is asked to wind down (shells,
# subagents, monitors, loop) and say RESTART-READY, then Remote Control off and /restart.] Before: a working session
# was interrupted (Esc) and resumed, and a looping one was stopped and resumed with its loop
# typed back (the /loop line from its last ScheduleWakeup), unless it has substantial work in flight: a shell of its own
# running over 2 min, or a subagent started over 2 min ago that is still writing. Those keep the old behaviour: left
# while working; asked to stop at a safe point when idle and looping. Blocked sessions (a question for Ben) are left.
# Drafts: nothing is typed into a box holding text, nor into Claude's agent view (untypable, 2026-11-21). Ceiling: a
# draft typed in the second between the check and the typing.
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
# - A session with Remote Control connected refuses: "Can't restart while Remote Control is connected" (2.1.321-2.1.325
#   at least, by design: the check is in the binary). Since 2026-11-13 (Ben: every agent on Remote Control, and "fix
#   the chore") such a session was exited (ctrl+d) and resumed; **never since 2026-11-19 (Ben: no ctrl+d)**: one that
#   /restart can't reach is reported and left running. A resume pending from before is still typed into a bare shell. Resuming
#   reattaches the Remote Control session recorded in the conversation (docs: remote-control). Checked after: a new
#   claude in the pane, on the installed version, on the same session id, with no Remote Control failure on screen.
#   Since 2026-11-18 (Ben: "gracefully disconnect the agent from remote control, restart them, and get them back on
#   remote control"): a session whose file has a bridgeSessionId is first disconnected (/remote-control, "Disconnect this
#   session"), then /restart runs as for any session, then Remote Control comes back (the restarted claude reconnects by
#   itself, as a NEW Remote Control session; /remote-control if not in 20 s). Exit + resume is the fallback when the
#   disconnect does not take. Rehearsed with this code on a throwaway 2.1.326 session in herdr-sandbox: 2.1.327, same
#   pid and session id, Remote Control back, no refusal on screen.
#   Until then these were told once per process and skipped for good, so those sessions never updated (beast-arch
#   journal, refusals from 2026-11-08).
# - Only an EMPTY input box is used (Claude Code's dim suggestion text does not count). A box holding only "/restart" lines (left by the old version) is cleared with one
#   ctrl+c; any other text is a draft and the pane is skipped.
state=${XDG_STATE_HOME:-$HOME/.local/state}/claude-restart; mkdir -p "$state"
# herdr-agent-upgrade's loop (station-maintenance fleet 40) does these passes where its plugin runs: it touches
# plugin-loop.alive every pass (10 min), so a fresh one means stand aside. Both take upgrade.lock: one pass at a time.
if (( ! dry )); then
  [[ -n $(find "$state/plugin-loop.alive" -mmin -15 2>/dev/null) ]] && { echo "herdr-agent-upgrade's loop runs the upgrades here: stood aside"; exit 0; }
  exec 9>"$state/upgrade.lock"; flock -n 9 || { echo "another upgrade pass is running: skipped"; exit 0; }
fi
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
# Claude's agent view (`claude agents`: the Needs input / Completed list): no /restart there, and a prompt typed there
# starts a new session. personal-comms sat in it 2026-11-20..21 and ~100 passes typed /restart into it. Its footer, seen
# in herdr-sandbox on 2.1.330 (2026-11-21). Port of herdr-agent-upgrade's agent_view/untypable.
agent_view() { "$herdr" agent read "$1" 2>/dev/null | grep -qE 'ctrl\+x to remove all|describe a task for a new session'; }
# untypable <pane>: why nothing may be typed there now, or nothing. Every path that types checks it right before typing:
# trstn-meta's draft (carbon, 2026-11-20 18:00) was lost under the wind-down ask.
untypable() {
  local b; agent_view "$1" && { echo "it shows Claude's agent view; open the session there (Ben) to upgrade it"; return; }
  b=$(box "$1"); [[ -z $b ]] || echo "draft in box: ${b:0:40}"
}
# resume <pane> <pid>: exit that claude and start the installed one on the same conversation, with its own flags.
# 0 done, 1 failed. Only called with an empty input box (checked before /restart was typed).
no_exit() { echo "fail $1: $2; not restarted, not exited (Ben 2026-11-19: no ctrl+d): look at the pane"; }
type_resume() {
  local pane=$1 sid=$2 cmd=$3 i np
  rm -f "$state/resume-$sid"
  "$herdr" pane send-text "$pane" "$cmd" >/dev/null && "$herdr" pane send-keys "$pane" enter >/dev/null \
    || { echo "FAIL $pane: claude exited but could not type '$cmd' into the pane; up-arrow there or run it by hand"; return 1; }
  for i in $(seq 30); do
    sleep 1; np=$(claude_pid "$pane")
    [[ -n $np && $(readlink "/proc/$np/exe" 2>/dev/null) == "$cur" \
       && $(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$np.json" 2>/dev/null) == "$sid" ]] && return 0
  done
  echo "FAIL $pane: typed '$cmd' but no claude ${cur##*/} on session $sid came up in 30 s; look at the pane"; return 1
}
# pending: a resume whose claude exited after resume() stopped waiting. Typed once its pane has no claude left.
pending() {
  local f sid pane cmd p
  for f in "$state"/resume-*; do
    [[ -e $f ]] || continue
    sid=${f##*/resume-}; IFS=$'\t' read -r pane cmd < "$f"
    "$herdr" pane get "$pane" >/dev/null 2>&1 || { echo "note: pane $pane is gone; not resumed: $cmd"; rm -f "$f"; continue; }
    p=$(claude_pid "$pane")
    if [[ -n $p ]]; then   # still exiting: next pass. Restarted by someone (another session): nothing to do.
      [[ $(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$p.json" 2>/dev/null) == "$sid" && $(readlink "/proc/$p/exe") != "$cur" ]] || rm -f "$f"
      continue
    fi
    shell_fg "$pane" || { echo "note $pane: its shell is not at a prompt; not typing: $cmd"; continue; }
    (( dry )) && { echo "would type in $pane: $cmd"; continue; }
    type_resume "$pane" "$sid" "$cmd" && echo "resumed $pane late (its claude exited after the wait): $cmd"
  done
}
shell_fg() {   # the pane's shell owns its terminal (nothing else in the foreground to type into)
  local e p st; for e in /proc/[0-9]*/environ; do
    grep -qz "^HERDR_PANE_ID=$1\$" "$e" 2>/dev/null || continue; p=${e#/proc/}; p=${p%/environ}
    [[ $(cat "/proc/$p/comm" 2>/dev/null) =~ ^(zsh|bash|sh|fish)$ ]] || continue
    read -ra st < <(sed 's/^.*) //' "/proc/$p/stat")   # fields from state on: [2] pgrp, [5] tpgid
    (( st[2] == st[5] )) && return 0
  done; return 1
}
claude_pid() {   # the pane's claude process
  local e p; for e in /proc/[0-9]*/environ; do
    grep -qz "^HERDR_PANE_ID=$1\$" "$e" 2>/dev/null || continue; p=${e#/proc/}; p=${p%/environ}
    [[ $(readlink "/proc/$p/exe" 2>/dev/null) == "$vdir"/* ]] && { echo "$p"; return; }
  done
}
transcript() { ls "$HOME"/.claude/projects/*/"$1".jsonl 2>/dev/null | head -1; }
# loop_state <session id>: "none", "active" (a loop is scheduled), or "ready <the /loop line to relaunch>".
loop_state() {
  local f; f=$(transcript "$1"); [[ -n $f ]] || { echo none; return; }
  python3 - "$f" <<'EOP'
import json, re, sys
state, line = "none", ""
for ln in open(sys.argv[1]):
    try:
        d = json.loads(ln)
    except ValueError:
        continue
    m = d.get("message") or {}
    c = m.get("content")
    if not isinstance(c, list):
        continue
    for b in c:
        if b.get("type") == "tool_use" and b.get("name") == "ScheduleWakeup":
            i = b.get("input", {})
            state = "none" if i.get("stop") else "active"
            if not i.get("stop"):
                line = "/loop" if "autonomous-loop" in (i.get("prompt") or "") else (i.get("prompt") or "")
        elif b.get("type") == "tool_use" and b.get("name") == "CronCreate" and not b.get("input", {}).get("durable") \
                and b.get("input", {}).get("recurring", True):
            state, line = "active", ""  # a cron loop's /loop line is not in the call: only the agent can say it
        elif b.get("type") == "tool_use" and b.get("name") == "CronDelete" and state == "active":
            state, line = "none", ""    # one-shot reminders and deleted crons are no loop (2026-11-19)
        elif b.get("type") == "text" and m.get("role") == "assistant":
            r = re.findall(r"^RESTART-READY(?:[ \t]+(/loop\b.*))?[ \t]*$", b.get("text") or "", re.M)
            if r:
                state, line = "ready", (r[-1] or "").strip().strip("`")
print(state + (" " + line if state != "none" and line.startswith("/loop") else ""))
EOP
}
# heavy <pid> <session id>: why stopping this claude now would lose substantial work, or nothing.
heavy() {
  local pid=$1 sid=$2 t f d now; now=$(date +%s)
  t=$(ps --ppid "$pid" -o etimes=,args= 2>/dev/null | awk '/shell-snapshots/ && $1 > 120 {print $1; exit}')
  [[ -n $t ]] && { echo "a shell running $((t/60)) min"; return; }
  d=$(dirname "$(transcript "$sid")")/$sid/subagents
  for f in "$d"/agent-*.jsonl; do
    [[ -e $f ]] || continue
    (( now - $(stat -c %Y "$f") < 120 )) || continue
    # started = its transcript's first timestamp (the .meta.json is rewritten when it finishes)
    t=$(head -c 65536 "$f" | grep -om1 '"timestamp":"[^"]*"' | cut -d'"' -f4); t=$(date -d "$t" +%s 2>/dev/null) || continue
    (( now - t > 120 )) && { echo "a subagent working $(( (now - t) / 60 )) min"; return; }
  done
}
status() { "$herdr" agent list 2>/dev/null | jq -r --arg p "$1" '.result.agents[] | select(.pane_id == $p) | .agent_status'; }
# say <pane> <text>: type a prompt into an idle claude with an empty box and submit it. A leading "/" opens the slash
# menu: its highlighted entry must be the typed command before it is accepted (the /deep-research incident, 2026-11-08).
say() {
  local pane=$1 text=$2 sel i s
  s=$(untypable "$pane"); [[ -z $s ]] || { echo "$s"; return 1; }
  "$herdr" pane send-text "$pane" "$text" >/dev/null || return 1
  sleep 1
  if [[ $text == /* ]]; then
    sel=$("$herdr" agent read "$pane" 2>/dev/null | tr -d '\r' | sed "s/$nbsp/ /g" \
          | awk '/^─/ {n++; last[n]=NR} {l[NR]=$0} END {for (i=last[n-1]-1; i>0 && i>last[n-1]-20; i--) if (l[i] ~ /^ +❯ \//) {print l[i]; exit}}' \
          | awk '{print $2}')
    if [[ -n $sel ]]; then
      [[ $sel == "${text%% *}" ]] || { "$herdr" pane send-keys "$pane" c-c >/dev/null; echo "menu highlighted $sel, not ${text%% *}"; return 1; }
      "$herdr" pane send-keys "$pane" "$accept" >/dev/null; sleep 1
    fi
  fi
  "$herdr" pane send-keys "$pane" "$submit" >/dev/null || return 1
  for i in $(seq 10); do
    sleep 1; s=$(status "$pane")
    [[ $s == working || $s == blocked ]] && return 0
  done
  echo "typed but the agent did not start (still ${s:-?})"; return 1
}
ASK="[claude-restart chore] Claude Code %s is installed; this session still runs %s. At your next safe point (between loop iterations, if you loop): gracefully finish or stop every background shell, subagent and monitor of yours (TaskStop what can't finish soon), stop your loop if you have one (ScheduleWakeup with stop: true; CronDelete your recurring cron jobs), then end that reply with one line exactly: RESTART-READY, followed by the /loop command that restarts your loop as it was if you had one (e.g. RESTART-READY /loop /next-story:bmad-pony). The chore then disconnects Remote Control, restarts this session on the new version, reconnects it and types that /loop line back. If work is running now, carry on and do this when it is done; you will not be asked again."
# relaunch [pane]: for each session with a pending /loop line (relaunch-<sid>) whose claude is on the installed version,
# idle, with an empty box: type the line. Every pass, so a relaunch that failed is retried.
relaunch() {
  local f sid line pane np i r
  for f in "$state"/relaunch-*; do
    [[ -e $f ]] || continue
    sid=${f##*/relaunch-}; line=$(cat "$f")
    np=; for i in "$HOME"/.claude/sessions/*.json; do
      [[ $(jq -r '.sessionId // empty' "$i" 2>/dev/null) == "$sid" ]] || continue
      i=${i##*/}; i=${i%.json}; [[ -e /proc/$i && $(readlink "/proc/$i/exe") == "$cur" ]] && np=$i
    done
    [[ -n $np ]] || continue
    pane=$(tr '\0' '\n' < "/proc/$np/environ" 2>/dev/null | sed -n 's/^HERDR_PANE_ID=//p')
    [[ -n $pane && ( -z ${1:-} || $1 == "$pane" ) ]] || continue
    for i in $(seq 20); do
      [[ $(status "$pane") =~ ^(idle|done)$ && -z $(box "$pane") ]] && break
      sleep 2
    done
    if (( dry )); then echo "would relaunch in $pane: $line"; continue; fi
    r=$(untypable "$pane"); [[ -z $r ]] || { echo "skip $pane: relaunch of '$line' waits: $r"; continue; }   # typed anyway after 40 s until 2026-11-21
    if r=$(say "$pane" "$line"); then rm -f "$f"; echo "relaunched in $pane: $line"
    else echo "FAIL $pane: relaunch of '$line' ($r); retried next pass"; fi
  done
}
# resume_of <pid> <session id>: the command that resumes this claude with its own flags (the old session choice dropped).
resume_of() {
  local -a a out=(); local x skip=0
  mapfile -d '' -t a < "/proc/$1/cmdline" 2>/dev/null || return 1
  for x in "${a[@]:1}"; do
    (( skip )) && { skip=0; continue; }
    case ${x%%=*} in -c|--continue|-r|--resume|--session-id) [[ $x == -r || $x == --resume || $x == --session-id ]] && skip=1; continue;; esac
    out+=("$(printf %q "$x")")
  done
  echo "claude --resume $2${out[*]:+ ${out[*]}}"
}
# settled <pane> <session id> <resume command>: /restart started the new claude; it counts only if it is still there 15 s
# later. keybind-find-meta's exited within seconds (beast-arch, 17:21 2026-11-19) and its pane sat at the shell for
# 17 min: one that dropped to its shell is resumed there (a relaunch, not an exit). Port of herdr-agent-upgrade e3b4c07.
settled() {
  local pane=$1 sid=$2 cmd=$3; sleep 15
  [[ -n $(claude_pid "$pane") ]] && return 0
  [[ -n $cmd ]] || { echo "fail $pane: the new claude exited after /restart and its session is unknown; resume it by hand"; return 1; }
  if ! shell_fg "$pane"; then
    printf '%s\t%s\n' "$pane" "$cmd" > "$state/resume-$sid"   # pending() types it later
    echo "fail $pane: the new claude exited after /restart; its shell is busy, the next pass resumes it: $cmd"; return 1
  fi
  echo "note $pane: the new claude exited within 15 s of /restart; resumed: $cmd"
  type_resume "$pane" "$sid" "$cmd"
}
# refused <pane>: the refusal under the last "❯ /restart", or nothing. Claude redraws a repeated refusal in place, so
# counting refusal lines missed the orchestrator's (2026-11-19) and /restart was re-sent every pass.
refused() {
  "$herdr" agent read "$1" 2>/dev/null | tr -d '\r' | sed "s/$nbsp/ /g" | grep -v '^[[:space:]]*$' \
    | awk '/^[[:space:]]*❯ \/restart/ {at=NR; r=""; next} at && NR <= at+3 && r == "" && /Can.t restart while/ {r=$0} END {sub(/^[[:space:]]+/, "", r); print r}'
}
# holders <pid>: what a claude's own shells are running ("pid N (M min) command head; ...").
holders() {
  ps --ppid "$1" -o pid=,etimes=,args= 2>/dev/null | awk '{p=$1; m=int($2/60); $1=$2=""; c=$0; sub(/^ +/, "", c)
    i=index(c, "eval \047"); if (i) c=substr(c, i+6); printf "%spid %s (%d min) %s", (n++ ? "; " : ""), p, m, substr(c, 1, 90)}'
}
# loops_due: after a pass that restarted anything, the orchestrator runs its trusted-loops pass (loops.md): loops that
# stopped on their own are not this chore's job (Ben 2026-11-19). It lives on beast-arch: typed into it there once it is
# idle with an empty box, sent by the agent inbox from any other machine. The flag carries it to the next pass until then.
LOOPS_AGENT=$HOME/projects/orchestrator
loops_due() {
  local flag=$state/loops-due pane ib=$HOME/projects/station-maintenance/bin/inbox
  [[ -e $flag ]] || return 0
  if [[ ! -d $LOOPS_AGENT ]]; then
    [[ -x $ib ]] || { echo "note: no $ib to ask the orchestrator for its trusted-loops pass; next pass"; return 0; }
    (cd "$HOME" && "$ib" send --to orchestrator@beast-arch --subject "Claude upgrade on $(uname -n): run the trusted-loops pass" < "$flag" >/dev/null 2>&1) \
      && { rm -f "$flag"; echo "asked the orchestrator on beast-arch (inbox) to run its trusted-loops pass"; } \
      || echo "note: could not send the orchestrator its trusted-loops ask; next pass"
    return 0
  fi
  pane=$("$herdr" agent list 2>/dev/null | jq -r --arg d "$LOOPS_AGENT" '[.result.agents[] | select(.agent == "claude" and .cwd == $d and (.agent_status == "idle" or .agent_status == "done"))][0].pane_id // empty')
  [[ -n $pane && -z $(box "$pane") ]] || return 0
  if r=$(say "$pane" "$(cat "$flag")"); then rm -f "$flag"; echo "asked $pane (orchestrator) to run its trusted-loops pass"
  else echo "note $pane: could not ask for the trusted-loops pass ($r); next pass"; fi
}
bridge() { jq -r '.bridgeSessionId // empty' "$HOME/.claude/sessions/$1.json" 2>/dev/null; }   # Remote Control's id
# rc_slash <pane>: type /remote-control and run it, only if the menu highlights exactly that entry (as /restart below).
rc_slash() {
  local pane=$1 sel
  [[ -z $(untypable "$pane") ]] || return 1   # its ctrl+c on a mismatch would wipe a draft
  "$herdr" pane send-text "$pane" /remote-control >/dev/null || return 1
  sleep 1
  sel=$("$herdr" agent read "$pane" 2>/dev/null | tr -d '\r' | sed "s/$nbsp/ /g" | grep -E '^ +❯ /' | tail -1 | awk '{print $2}')
  [[ $sel == /remote-control ]] || { "$herdr" pane send-keys "$pane" c-c >/dev/null; return 1; }
  "$herdr" pane send-keys "$pane" "$accept" >/dev/null; sleep 1; "$herdr" pane send-keys "$pane" "$submit" >/dev/null
}
# rc_off <pane> <pid>: Remote Control's dialog (Disconnect this session / Show QR code / Continue, Continue selected):
# up to "Disconnect this session", Enter; 0 once the session file has no bridgeSessionId. Rehearsed on a throwaway
# session in herdr-sandbox, 2.1.327, 2026-11-18 ("Remote Control disconnected.").
rc_off() {
  local pane=$1 pid=$2 i
  rc_slash "$pane" || { echo "note $pane: no /remote-control in its menu"; return 1; }
  sleep 3
  for i in 1 2 3 4; do
    "$herdr" agent read "$pane" 2>/dev/null | sed "s/$nbsp/ /g" | grep -q '❯ Disconnect this session' && break
    "$herdr" pane send-keys "$pane" up >/dev/null; sleep 0.5
  done
  "$herdr" agent read "$pane" 2>/dev/null | sed "s/$nbsp/ /g" | grep -q '❯ Disconnect this session' \
    || { "$herdr" pane send-keys "$pane" escape >/dev/null; echo "note $pane: Remote Control's dialog had no Disconnect"; return 1; }
  "$herdr" pane send-keys "$pane" enter >/dev/null
  for i in $(seq 20); do sleep 0.5; [[ -z $(bridge "$pid") ]] && { sleep 1; return 0; }; done
  echo "note $pane: Remote Control did not disconnect"; return 1
}
# rc_on <pane>: the restarted claude reconnects by itself (seen in the rehearsal: a new Remote Control session, so a
# new entry on the phone); if it has not in 20 s, /remote-control connects it.
rc_on() {
  local pane=$1 i np
  for i in $(seq 20); do sleep 1; np=$(claude_pid "$pane"); [[ -n $np && -n $(bridge "$np") ]] && return 0; done
  rc_slash "$pane" && for i in $(seq 20); do sleep 1; [[ -n $(bridge "$np") ]] && { echo "note $pane: Remote Control reconnected by /remote-control"; return 0; }; done
  echo "FAIL $pane: restarted, but Remote Control is off; run /remote-control there"
}
# rc_restart <pane>: restart, and a session it disconnected from Remote Control gets it back whatever happened next
# (restarted, refused, failed). Not after exit + resume (4): a resumed claude reconnects by itself.
RCWAS=
rc_restart() { RCWAS=; restart "$1"; local r=$?; [[ -n $RCWAS && $r != 4 ]] && rc_on "$1"; return $r; }
restart() {   # 0 restarted (/restart), 4 resumed (exit + claude --resume), 2 skipped (draft, busy), 1 failed
  local pane=$1 pid b i sid ls
  agent_view "$pane" && { echo "skip $pane: it shows Claude's agent view (no /restart there); nothing typed: open the session there"; return 2; }
  pid=$(claude_pid "$pane")
  sid=$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$pid.json" 2>/dev/null)
  ls=$( [[ -n $sid ]] && loop_state "$sid" || echo none)
  local why; why=$( [[ -n $pid && -n $sid ]] && heavy "$pid" "$sid")
  # Ben 2026-11-19: no Esc, no ctrl+d. Working, shells/subagents in flight, a background refusal, or a loop: asked once
  # to wind down at a safe point and say RESTART-READY. A READY counts only after this pid was asked.
  local ready=; [[ $ls == ready* && -n $pid && -e $state/ask-$pid ]] && ready=1
  # A background refusal (bg-<pid>) holds it for an hour, as line 47 says: without the age the marker held the session
  # for good, and carbon's trstn-meta (refused once 2026-11-21, then idle, loop stopped) failed every 10 min for 3 days
  # as "still not RESTART-READY" (station-maintenance fleet 40, 2026-11-23).
  local bg=; [[ -n $pid && -n $(find "$state/bg-$pid" -mmin -60 2>/dev/null) ]] && bg=1
  if [[ -z $ready ]] && [[ $(status "$pane") == working || -n $why || -n $bg || $ls == active* ]]; then
    if [[ -e $state/ask-$pid ]]; then
      local age=$(( $(date +%s) - $(stat -c %Y "$state/ask-$pid") ))
      # dungeon-smash waited 1 h 48 min on a self-matching `pgrep -f` loop (2026-11-19): reported, with its shells
      (( age > 3600 )) && { local hd; hd=$(holders "$pid"); echo "fail $pane: asked to wind down $((age / 60)) min ago and still not RESTART-READY; held by: ${hd:-nothing visible (a subagent or monitor?)}"; return 1; }
      echo "skip $pane: asked to wind down; waiting for its RESTART-READY"; return 2
    fi
    b=$(box "$pane"); [[ -z $b ]] || { echo "skip $pane: the prompt holds a draft: ${b:0:40}"; return 2; }
    say "$pane" "$(printf "$ASK" "${cur##*/}" "$(basename "$(readlink "/proc/$pid/exe")")")" >/dev/null \
      && { : > "$state/ask-$pid"; echo "asked $pane to wind down (shells, subagents, loop) at a safe point"; return 2; }
    echo "fail $pane: could not ask it to wind down"; return 1
  fi
  b=$(box "$pane")
  if [[ -n $b ]] && ! grep -qv '^/restart$' <<<"$b"; then "$herdr" pane send-keys "$pane" c-c >/dev/null; sleep 1; b=$(box "$pane"); fi
  [[ -z $b ]] || { echo "skip $pane: the prompt holds a draft: ${b:0:40}"; return 2; }
  [[ -n $ready && $ls != ready ]] && printf '%s\n' "${ls#ready }" > "$state/relaunch-$sid"
  # Remote Control connected (the session file's bridgeSessionId): disconnect it, /restart, and it comes back (Ben
  # 2026-11-18: "gracefully disconnect the agent from remote control, restart them, and get them back on"). A
  # disconnect that does not take is reported: no ctrl+d, ever (Ben 2026-11-19).
  [[ -n $pid && -n $(bridge "$pid") ]] && rc_off "$pane" "$pid" && RCWAS=1
  [[ -n $pid && -n $(bridge "$pid") ]] && { no_exit "$pane" "Remote Control would not disconnect"; return 1; }
  local cmd= att sel; [[ -n $pid && -n $sid ]] && cmd=$(resume_of "$pid" "$sid")
  # The menu's highlighted entry must BE /restart before it is accepted. A claude without /restart (2.1.318 in w2:p1,
  # 2026-11-08) highlights the nearest match instead, and accepting it ran /deep-research twice in Ben's session.
  # Right after Remote Control's dialog closes the menu can highlight nothing (orchestrator 17:40 2026-11-19): one more
  # try 3 s later.
  for att in 1 2; do
  b=$(untypable "$pane"); [[ -z $b ]] || { echo "skip $pane: $b"; return 2; }
  "$herdr" pane send-text "$pane" /restart >/dev/null || return 1
  sleep 1
  sel=$("$herdr" agent read "$pane" 2>/dev/null | tr -d '\r' | sed "s/$nbsp/ /g" \
        | awk '/^─/ {n++; last[n]=NR} {l[NR]=$0} END {for (i=last[n-1]-1; i>0 && i>last[n-1]-20; i--) if (l[i] ~ /^ +❯ \//) {print l[i]; exit}}' \
        | awk '{print $2}')
  [[ $sel == /restart ]] && break
  "$herdr" pane send-keys "$pane" c-c >/dev/null
  if (( att == 2 )); then
    sleep 1; [[ -z $(box "$pane") ]] || { echo "skip $pane: the prompt is not empty after clearing"; return 2; }
    no_exit "$pane" "no /restart in its menu (highlighted: ${sel:-nothing})"; return 1
  fi
  sleep 3
  done
  "$herdr" pane send-keys "$pane" "$accept" >/dev/null || return 1
  sleep 1; "$herdr" pane send-keys "$pane" "$submit" >/dev/null || return 1
  for i in 1 2 3 4 5 6; do
    sleep 2
    [[ $(readlink "/proc/$(claude_pid "$pane")/exe" 2>/dev/null) == "$cur" ]] && { settled "$pane" "$sid" "$cmd"; return; }
    local why; why=$(refused "$pane")
    if [[ -n $why ]]; then
      if [[ $why == *"Remote Control"* ]]; then [[ -n $pid ]] && : > "$state/rc-$pid"
        echo "note $pane: /restart refused (Remote Control is connected): exit + resume instead"
        sleep 1; [[ -z $(box "$pane") ]] || { echo "skip $pane: the prompt is not empty after the refusal"; return 2; }
        no_exit "$pane" "/restart can't run here"; return 1
      fi
      [[ -n $pid ]] && : > "$state/bg-$pid"   # e.g. "work is running in the background": retried in an hour
      echo "refused $pane: ${why#*restart while }"; return 2
    fi
  done
  echo "note: $pane: /restart sent ($accept, $submit), but the pane still runs an old claude"; return 1
}
find "$state" -name 'rc-*' -o -name 'bg-*' -o -name 'ask-*' 2>/dev/null | while read -r f; do [[ -e /proc/${f##*-} ]] || rm -f "$f"; done
# /restart keeps the pid, so a marker from an earlier round survives the line above: one older than the installed claude
# belongs to that round (carbon trstn-meta failed every pass on a 2026-11-20 ask; station-maintenance fleet 40).
find "$state" \( -name 'ask-*' -o -name 'bg-*' \) ! -newer "$cur" -delete 2>/dev/null
done_n=0 busy=0 resumed=0 failed=0
if (( ${#stale[@]} )) && [[ -x $herdr ]]; then
  states=$("$herdr" agent list 2>/dev/null | jq -r '.result.agents[] | "\(.pane_id) \(.agent_status)"')
  for pane in "${!stale[@]}"; do
    st=$(awk -v p="$pane" '$1 == p {print $2}' <<<"$states")
    if [[ $st == idle || $st == done || $st == working ]]; then
      if (( dry )); then p=$(claude_pid "$pane"); i=$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$p.json" 2>/dev/null)
        echo "would restart $pane (${stale[$pane]}, $st, loop: $(loop_state "$i"), in flight: $(heavy "$p" "$i"))"
      else rc_restart "$pane"; case $? in 0) echo "restarted $pane (was ${stale[$pane]})"; done_n=$((done_n+1));;
                                         4) resumed=$((resumed+1)); done_n=$((done_n+1));; 1) failed=$((failed+1));; esac; fi
      (( dry )) && done_n=$((done_n+1))
    else busy=$((busy+1)); fi
  done
fi
(( done_n && ! dry )) && printf '%s\n' "The Claude upgrade pass at $(date +%H:%M) on $(uname -n) restarted $done_n session(s) onto ${cur##*/} (journalctl --user -u chore@claude-restart there). Run your trusted-loops pass (loops.md): bring back the loops that should be running, and tell Ben what you did." > "$state/loops-due"
[[ -x $herdr ]] && { pending; relaunch; (( dry )) || loops_due; }
(( dry )) && w="to restart" || w=restarted
echo "claude ${cur##*/}: $done_n $w ($resumed by exit + resume), $busy busy (next pass), $failed failed, $outside outside herdr"
(( failed == 0 ))
