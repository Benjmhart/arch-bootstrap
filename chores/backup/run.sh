#!/usr/bin/env bash
# backup -- restic snapshot of $HOME to one shared repo on Google Drive (station-maintenance beast-arch 92).
# Daily on every machine. What is in and out: excludes, beside this file. Retention: 7 daily, 4 weekly,
# 12 monthly, per host.
#
# Each machine opens the repo with its OWN restic key (password file below, never in ~/secrets), so a
# compromised machine's key is revoked with `restic key remove` without touching the others
# (beast-arch 94). Until a machine has one, this exits 75 (needs you) and says how to set it up.
#
# Only the fleet controller (micro) prunes and checks: pruning is the one step that deletes data, so a
# dirty machine only ever adds snapshots and marks its own old ones for removal.
set -euo pipefail
# --retry-lock: forget and prune need the repo to themselves, and the four machines share it. Without it
# the first run (all four started together, 2026-10-15) failed at forget with exit 11 on three of them.
export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-"rclone:personal drive:restic"}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/password}
here="$(dirname "$(readlink -f "$0")")"
host=$(uname -n)

if [[ ! -s $RESTIC_PASSWORD_FILE ]]; then
  echo "no restic key on $host: add one from micro (station-maintenance beast-arch 92), then save it to $RESTIC_PASSWORD_FILE (mode 600)"
  exit 75
fi

restic backup --retry-lock 2h --quiet --host "$host" --one-file-system --exclude-caches \
  --exclude-file "$here/excludes" "$HOME"
# A run killed mid-backup (a laptop shut down, a stopped unit) leaves its lock behind, and forget and
# prune need the repo to themselves, so one dead lock stops every host's cleanup for good; waiting
# (--retry-lock) never clears it. Plain `unlock` removes only stale locks: older than 30 min with no
# refresh, or this host's with a dead PID. Live runs refresh theirs every 5 min. beast-arch 92.
restic unlock --quiet
restic forget --retry-lock 2h --quiet --host "$host" --keep-daily 7 --keep-weekly 4 --keep-monthly 12

if [[ $host == "${FLEET_SELF_HOST:-micro}" ]]; then
  restic prune --retry-lock 2h --quiet
  # A weekly read of 5% of the data catches a damaged repo before the day a restore needs it.
  [[ $(date +%u) == 7 ]] && restic check --retry-lock 2h --read-data-subset=5%
fi

latest=$(restic snapshots --host "$host" --latest 1 --json | jq -r '.[0] | "\(.short_id) \(.time[:16])"')
echo "snapshot $latest of $HOME on $host"
