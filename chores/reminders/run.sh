#!/usr/bin/env bash
# reminders -- a notification for every reminder that is due (Ben 2026-11-08, one list instead of reminders scattered
# over tasks and calendars). The list is station-maintenance's reminders.md (private; arch-bootstrap is public):
# lines "- YYYY-MM-DD text". Due = that date or earlier. It keeps notifying (at login and 09:00 daily) until the line
# is deleted from the file. A host without station-maintenance (surfboard) has no list: nothing to do.
set -uo pipefail
f="$HOME/projects/station-maintenance/reminders.md"
[[ -r $f ]] || { echo "no reminder list here"; exit 0; }
today=$(date +%F) n=0
while IFS= read -r line; do
  [[ $line =~ ^-\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ +(.+)$ ]] || continue
  [[ ${BASH_REMATCH[1]} > $today ]] && continue
  notify-send -u normal -a reminder "Reminder (${BASH_REMATCH[1]})" "${BASH_REMATCH[2]}" 2>/dev/null || true
  n=$((n+1))
done < "$f"
echo "$n due"
