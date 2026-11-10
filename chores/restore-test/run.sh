#!/usr/bin/env bash
# restore-test -- on micro, weekly: prove the backups restore (station-maintenance fleet 19, Ben 2026-11-10). chores/backup
# proves a snapshot exists and its Sunday `restic check` reads 5% of the data; neither restores a file. This restores a
# few random files from each machine's newest snapshot, from the repo (its address is ~/.config/restic/repository) and from micro's copy of it, with --verify
# (restic re-reads each restored file and compares it with the snapshot), and checks every size. Read-only on the repos.
set -euo pipefail
repofile=$HOME/.config/restic/repository
export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-$( [[ -s $repofile ]] && cat "$repofile" || echo "rclone:personal drive:restic")}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/password}
self=${FLEET_SELF_HOST:-micro}
[[ $(uname -n) == "$self" ]] || { echo "restore tests run on $self; nothing to do here"; exit 0; }
[[ -s $RESTIC_PASSWORD_FILE ]] || { echo "no restic key on $self ($RESTIC_PASSWORD_FILE)"; exit 75; }
hosts="$self ${BACKUP_HOSTS:-beast-arch carbon media-center}" n=${RESTORE_FILES:-3}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=0

# test REPO HOST: n random files (1 byte .. 20 MB) from HOST's newest snapshot in REPO
test_one() {
  local repo=$1 h=$2 id t inc=() p
  id=$(restic -r "$repo" snapshots --host "$h" --latest 1 --json | jq -r '.[0].short_id // empty')
  [[ -n $id ]] || { echo "FAIL  $h ($repo): no snapshot"; failed=1; return; }
  restic -r "$repo" ls --json "$id" | jq -r 'select(.type == "file" and .size > 0 and .size < 20000000) | "\(.size) \(.path)"' \
    | shuf -n "$n" > "$tmp/pick"
  [[ -s $tmp/pick ]] || { echo "FAIL  $h ($repo): snapshot $id lists no files"; failed=1; return; }
  while read -r _ p; do inc+=(--include "$p"); done < "$tmp/pick"
  rm -rf "$tmp/out"
  if ! restic -r "$repo" restore "$id" --target "$tmp/out" --verify --quiet "${inc[@]}" >/dev/null; then
    echo "FAIL  $h ($repo): restic restore of snapshot $id failed"; failed=1; return
  fi
  while read -r size p; do
    t=$(stat -c %s "$tmp/out$p" 2>/dev/null || echo missing)
    [[ $t == "$size" ]] || { echo "FAIL  $h ($repo): $p restored as $t bytes, snapshot says $size"; failed=1; return; }
  done < "$tmp/pick"
  echo "ok    $h ($repo): $(wc -l < "$tmp/pick") files from $id restored and verified"
}

for h in $hosts; do test_one "$RESTIC_REPOSITORY" "$h"; done
copy=${RESTORE_COPY:-$HOME/.local/share/restic-copy}
[[ -f $copy/config ]] && test_one "$copy" "$self"
(( failed )) && { echo "restore test FAILED (see above)"; exit 1; }
echo "restore test: every machine's newest snapshot restored $n files and verified"
