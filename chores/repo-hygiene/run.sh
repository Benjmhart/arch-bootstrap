#!/usr/bin/env bash
# repo-hygiene -- push unpushed commits in ~/projects/* to their upstream, and report what should be tracked
# (station-maintenance beast-arch 134; Ben 2026-11-01: push to GitHub, fpush and pulls bring the machines up to
# date; a report in $OPS that maintenance agents act on). Daily on every machine.
#
# Pushes: every branch with an upstream that is ahead and not behind (after a fetch), never forced, and only when
# tools/secret-scan finds nothing in the outgoing commits. ~/.dot and ~/secrets are reported, never pushed: they
# move through fpush. Writes $OPS/<host>-repo-hygiene-<date>.log. Exit 75 (notify) when something needs a person:
# a push held by the secret scan, a diverged or failed push. REPO_HYGIENE_DRY=1: fetch and report, push nothing.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
scan=$here/../../tools/secret-scan
host=$(uname -n)
ops=${OPS:-$HOME/.local/state/ops}; mkdir -p "$ops"
log=$ops/$host-repo-hygiene-$(date +%Y%m%d).log
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20" GIT_TERMINAL_PROMPT=0
pushed=0 attention=0 suggest=0
declare -A need=()   # project repo dir -> why, for section 5
out() { echo "$*" >> "$log"; }
: > "$log"
out "# repo-hygiene $host $(date -Is). PUSHED/HELD/DIVERGED/FAILED = acted on; SUGGEST = for a maintenance agent."

# 1. ~/projects/*: push what is ahead; suggest repos, upstreams, tracking.
for d in "$HOME"/projects/*/; do
  d=${d%/}; p=${d/#$HOME/\~}
  # A folder Ben keeps out of git on purpose carries a .not-a-repo marker (beast-arch 134, 2026-11-11).
  [[ ! -e $d/.git && -e $d/.not-a-repo ]] && continue
  if [[ ! -e $d/.git ]]; then
    out "SUGGEST $p: not a git repository ($(du -sh "$d" 2>/dev/null | cut -f1), last change $(find "$d" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)) -- make it a repo, or move it out of ~/projects"
    (( suggest++ )); continue
  fi
  g=(git -C "$d")
  timeout 120 "${g[@]}" fetch -q --all --prune 2>/dev/null || out "FETCH-FAILED $p: fetch failed (no network, or a key that needs a person)"
  while read -r b u; do
    if [[ -z $u ]]; then out "SUGGEST $p: branch $b has no upstream -- push it to GitHub (git push -u origin $b) or delete it"; (( suggest++ )); continue; fi
    read -r ahead behind < <("${g[@]}" rev-list --left-right --count "$b...$u" 2>/dev/null) || continue
    (( ahead )) || continue
    if (( behind )); then out "DIVERGED $p: $b is $ahead ahead, $behind behind $u -- rebase or merge, then push"; (( attention++ )); need[$d]+="$b diverged from $u; "; continue; fi
    hits=$("${g[@]}" log -p --no-renames --format= "$u..$b" | python3 "$scan")
    if [[ -n $hits ]]; then out "HELD $p: $b not pushed, the secret scan flagged: ${hits//$'\n'/; }"; (( attention++ )); continue; fi
    remote=${u%%/*}
    if [[ -n ${REPO_HYGIENE_DRY:-} ]]; then out "WOULD-PUSH $p: $b ($ahead commit(s)) -> $u"; continue; fi
    if err=$(timeout 120 "${g[@]}" push -q "$remote" "refs/heads/$b:refs/heads/${u#*/}" 2>&1); then
      out "PUSHED $p: $b ($ahead commit(s)) -> $u, now $("${g[@]}" rev-parse --short "$b")"; (( pushed++ ))
    else out "FAILED $p: push of $b -> $u: ${err//$'\n'/ }"; (( attention++ )); fi
  done < <("${g[@]}" for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads)
  # git status, not `ls-files -o --directory`: that lists a directory whose only files are ignored (station-maintenance
  # .claude/ holding the ignored scheduled_tasks.lock, flagged 2026-11-11).
  untracked=$("${g[@]}" status --porcelain -unormal | sed -n 's/^?? //p')
  n=$(grep -c . <<<"$untracked")
  (( n )) && { out "SUGGEST $p: $n untracked path(s), not ignored -- track or .gitignore: $(head -5 <<<"$untracked" | tr '\n' ' ')"; (( suggest++ )); need[$d]+="$n untracked path(s); "; }
  n=$("${g[@]}" status --porcelain -uno | wc -l)
  (( n )) && { out "SUGGEST $p: $n tracked file(s) changed, not committed -- commit or discard: $("${g[@]}" status --porcelain -uno | head -5 | cut -c4- | tr '\n' ' ')"; (( suggest++ )); need[$d]+="$n changed file(s) not committed; "; }
done

# 2. The system repos: report only (fpush moves them).
for spec in "dotfiles:git --git-dir=$HOME/.dot --work-tree=$HOME" "secrets:git -C $HOME/secrets"; do
  name=${spec%%:*}; read -r -a g <<<"${spec#*:}"
  "${g[@]}" rev-parse -q --git-dir >/dev/null 2>&1 || continue
  ahead=$("${g[@]}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
  dirty=$("${g[@]}" status --porcelain -uno 2>/dev/null | wc -l)
  [[ $ahead == 0 && $dirty == 0 ]] || { out "SUGGEST $name: $ahead unpushed commit(s), $dirty changed file(s) -- not pushed here; commit/push by hand or let fpush carry it: $("${g[@]}" status --porcelain -uno | head -5 | cut -c4- | tr '\n' ' ')"; (( suggest++ )); }
done

# 3. Config and scripts the dotfiles do not track, changed in the last 14 days (small text only: caches and
#    browser profiles are big or binary).
dot=(git -C "$HOME" --git-dir="$HOME/.dot" --work-tree="$HOME")
if "${dot[@]}" rev-parse -q --git-dir >/dev/null 2>&1; then
  while read -r f; do
    rel=${f#"$HOME"/}
    [[ -n $("${dot[@]}" ls-files -- "$rel" | head -1) ]] && continue
    [[ -d $f ]] && (( $(du -s "$f" | cut -f1) > 1024 )) && continue
    [[ -f $f ]] && ! grep -Iq . "$f" 2>/dev/null && continue
    # secret-scan reads a diff: present the files as added lines, so a token here turns the advice around.
    if [[ -n $(find "$f" -type f -size -256k -print0 2>/dev/null | xargs -0r awk 'FNR == 1 { print "+++ b/" FILENAME } { print "+" $0 }' 2>/dev/null | python3 "$scan") ]]; then
      out "SUGGEST ~/$rel: changed in the last 14 days, holds credentials (secret scan) -- do NOT add to the dotfiles; secrets repo or vault if it must be kept"
    else out "SUGGEST ~/$rel: changed in the last 14 days, not in the dotfiles -- track it, or note why not"; fi
    (( suggest++ ))
  # Not dotfiles, by decision (2026-11-10, station-maintenance fleet): dconf = the binary gsettings db that
  # theme-gsettings writes every fpush; QtProject.conf = Qt's file-dialog history; procps = toprc only (often empty).
  done < <(find "$HOME/.config" "$HOME/bin" "$HOME/.local/bin" -mindepth 1 -maxdepth 1 -mtime -14 \
             -not -name '*.lock' -not -name '*.log' -not -name '*.sock' \
             -not -name dconf -not -name QtProject.conf -not -name procps 2>/dev/null | sort)
fi

# 4. Loose files in ~ (scratch belongs in $OPS, work in a repo).
while read -r f; do
  out "SUGGEST ~/${f#"$HOME"/}: loose file in ~ -- into a repo, \$OPS, or delete"; (( suggest++ ))
done < <(find "$HOME" -mindepth 1 -maxdepth 1 -type f -not -name '.*' 2>/dev/null | sort)

# 5. Ask the repo's own agent to clean up (station-maintenance fleet 13, Ben 2026-11-08). For each project repo above
#    with work left, an IDLE Claude agent in herdr whose cwd is that repo gets one prompt (agent-prompt: the text plus
#    Alt+Enter, which submits in Ben's keybindings). Busy agents and repos without an agent are left to the report.
prompted=0
hb=$HOME/.local/bin
if (( ${#need[@]} )) && [[ -x $hb/herdr && -x $hb/agent-prompt ]] && agents=$(PATH=$hb:$PATH herdr agent list 2>/dev/null); then
  for d in "${!need[@]}"; do
    pane=$(python3 -c '
import json, sys
d = sys.argv[1]
for a in json.loads(sys.stdin.read())["result"]["agents"]:
    if a.get("agent") == "claude" and a.get("cwd") == d and a.get("agent_status") in ("idle", "done"):
        print(a["pane_id"]); break' "$d" <<<"$agents" 2>/dev/null)
    [[ -n $pane ]] || continue
    msg="From the repo-hygiene chore on $host ($(date +%F)): this repo has work not committed or pushed: ${need[$d]}Please commit what belongs in the repo, .gitignore what does not (never commit secrets, credentials or personal documents), and push by this repo's own convention. Reply in one line: what you committed and pushed, and anything you left and why. Details: $log"
    if [[ -n ${REPO_HYGIENE_DRY:-} ]]; then out "WOULD-PROMPT ${d/#$HOME/\~}: agent $pane"; continue; fi
    if r=$(PATH=$hb:$PATH agent-prompt "$pane" "$msg" 2>&1); then out "PROMPTED ${d/#$HOME/\~}: agent $pane ($r)"; (( prompted++ ))
    else out "PROMPT-FAILED ${d/#$HOME/\~}: agent $pane: ${r//$'\n'/ }"; fi
  done
fi

# 6. The agent inbox (station-maintenance fleet 27): senders told at 3 days unread, ESCALATE lines at 7 for Ben.
#    Not on micro, which runs no station-maintenance code and takes no mail.
inbox=$HOME/projects/station-maintenance/bin/inbox
if [[ $host != micro && -x $inbox ]] && grep -q cmd_escalate "$inbox"; then
  if [[ -n ${REPO_HYGIENE_DRY:-} ]]; then "$inbox" stale --days 7 >> "$log" 2>&1
  else
    "$inbox" escalate >> "$log" 2>&1; rc=$?
    (( rc == 75 )) && (( attention++ ))
    (( rc != 0 && rc != 75 )) && { out "FAILED inbox escalate exited $rc"; (( attention++ )); }
  fi
fi

summary="$pushed pushed, $prompted agent(s) prompted, $attention need a person, $suggest suggestion(s) -- $log"
out "# $summary"
echo "$summary"
(( attention )) && exit 75
exit 0
