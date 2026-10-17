#!/usr/bin/env bash
# backup -- restic snapshots of $HOME on every machine, into one repo on Google Drive (station-maintenance
# beast-arch 92). What is in and out: excludes, beside this file. Retention: 7 daily, 4 weekly, 12 monthly, per host.
#
# Only micro (the fleet controller) holds the Drive token and runs this nightly (Ben 2026-10-17, decision 4).
# It backs itself up, then serves the repo APPEND-ONLY on its loopback (`rclone serve restic --append-only`)
# and lends it to each dirty machine over an `ssh -R` it opens itself: micro takes no inbound. On the dirty
# machine this file runs as `run.sh tunnel`, the forced command of micro's backup key, and can add snapshots
# but not delete or overwrite anything (forget, prune, key remove, raw DELETE: 403, tested 2026-10-16). So a
# compromised machine cannot destroy the backups. forget, rewrite, prune and check run only on micro.
#
# Each machine opens the repo with its OWN restic key (password file below, never in ~/secrets), so a
# compromised machine's key is revoked with `restic key remove` without touching the others (beast-arch 94).
# Until a machine has one, this exits 75 (needs you) and says how to set it up.
set -euo pipefail
export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-"rclone:personal drive:restic"}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/password}
here="$(dirname "$(readlink -f "$0")")"
host=${BACKUP_HOST:-$(uname -n)} self=${FLEET_SELF_HOST:-micro} port=${BACKUP_PORT:-18731}

if [[ ${1:-} == tunnel ]]; then
  export RESTIC_REPOSITORY="rest:http://127.0.0.1:$port/"   # micro's server, through its ssh -R
elif [[ $host != "$self" ]]; then
  echo "backups of $host run from $self (station-maintenance beast-arch 92); nothing to do here"
  exit 0
fi

if [[ ! -s $RESTIC_PASSWORD_FILE ]]; then
  echo "no restic key on $host: add one from micro (station-maintenance beast-arch 92), then save it to $RESTIC_PASSWORD_FILE (mode 600)"
  exit 75
fi

# --retry-lock: forget and prune need the repo to themselves. A run killed mid-backup (a laptop shut down, a
# stopped unit) leaves its lock behind and waiting never clears it, so `unlock` (stale locks only: older than
# 30 min with no refresh, or this host's with a dead PID; append-only allows it) runs after each backup.
restic backup --retry-lock 2h --quiet --host "$host" --one-file-system --exclude-caches \
  --exclude-file "$here/excludes" "$HOME"
restic unlock --quiet
if [[ ${1:-} == tunnel ]]; then
  echo "snapshot $(restic snapshots --host "$host" --latest 1 --json | jq -r '.[0] | "\(.short_id) \(.time[:16])"') of $HOME on $host"
  exit 0
fi

# micro from here. The dirty machines, one at a time over the tunnel. A machine that is off is skipped, not a
# failure (carbon is often off at night); a reachable one whose backup fails is. Staleness is checked below.
failed=0 needs=0
key=${BACKUP_KEY:-$HOME/.ssh/id_ed25519_backup}
hosts=${BACKUP_HOSTS:-"beast-arch carbon media-center"}
if [[ ! -f $key ]]; then
  echo "no backup key $key: create it on $self (station-maintenance beast-arch 92) -- the dirty machines were not backed up"
  needs=1
else
  rclone serve restic --append-only --addr "127.0.0.1:$port" "${RESTIC_REPOSITORY#rclone:}" & srv=$!
  trap 'kill $srv 2>/dev/null || true' EXIT
  for _ in $(seq 60); do curl -sfI -o /dev/null "http://127.0.0.1:$port/config" && break; sleep 1; done
  domain=${BACKUP_DOMAIN-$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty')}
  for h in $hosts; do
    rc=0
    # -F /dev/null: none of ~/.ssh/config's peer stanzas; the key's forced command decides what runs there.
    # shellcheck disable=SC2086
    ssh -F /dev/null -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o ExitOnForwardFailure=yes -o HostKeyAlias="$h" -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
        ${BACKUP_SSH_ARGS:-} -R "127.0.0.1:${BACKUP_TUNNEL_PORT:-$port}:127.0.0.1:$port" "$h${domain:+.$domain}" tunnel || rc=$?
    case $rc in
      0) ;;
      255) echo "skip  $h: unreachable (off?) or the tunnel was refused" ;;
      *) echo "FAIL  $h: backup exited $rc"; failed=1 ;;
    esac
  done
  kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
fi

restic forget --retry-lock 2h --quiet --keep-daily 7 --keep-weekly 4 --keep-monthly 12   # grouped by host
# Old snapshots follow the CURRENT excludes (Ben 2026-10-17: backup cleanup "fully automatic"): rewrite drops
# excluded paths from every snapshot taken before they were excluded -- the credentials before d20c7bd, media-center's
# ~/media in 3d562073 -- and leaves the rest untouched (a no-op run says "no snapshots were modified"). prune below
# then deletes the data. ponytail: so a new exclude also strips history, which is the point for credentials and
# media; to keep old copies of something, stop excluding it rather than add it.
restic rewrite --retry-lock 2h --quiet --forget --exclude-file "$here/excludes"
restic prune --retry-lock 2h --quiet
# A weekly read of 5% of the data catches a damaged repo before the day a restore needs it.
if [[ $(date +%u) == 7 ]]; then restic check --retry-lock 2h --read-data-subset=5%; fi

# One line per machine; a machine with no snapshot in 3 days fails the run (off for days, or broken).
now=$(date +%s)
for h in $self $hosts; do
  t=$(restic snapshots --host "$h" --latest 1 --json | jq -r '.[0] // empty | "\(.short_id) \(.time)"')
  if [[ -z $t ]]; then echo "FAIL  $h: no snapshot at all"; failed=1; continue; fi
  age=$(( (now - $(date -d "${t#* }" +%s)) / 3600 ))
  if (( age > 72 )); then echo "FAIL  $h: newest snapshot ${t%% *} is ${age}h old"; failed=1
  else echo "snapshot ${t%% *} ${t:9:16} on $h"; fi
done
(( needs )) && exit 75
exit "$failed"
