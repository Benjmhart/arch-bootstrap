#!/usr/bin/env bash
# canary -- nightly on the KVM host (beast-arch): the VM canary (tests/rehearse-install canary) on origin's heads of
# arch-bootstrap and the dotfiles, so `fleet push` can say whether what it is about to apply already ran in a fleet-like
# guest (station-maintenance fleet 11; Ben 2026-11-10). Result: ~/.local/state/fleet/canary, one line
# "<ab> <dot> <time> pass|FAIL <log>", which fleet-apply's `canary` request hands to fleet push. Log in $OPS.
# Skips when the heads are the ones last tested. Exit 75 (notify) on FAIL or when there is no provisioned guest.
# The guest: ~/.cache/vm-rehearsal/uefi-virtio, made once by `tests/rehearse-install install` then `... provision`.
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
OPS=${OPS:-$HOME/.local/state/ops}
state=${FLEET_STATE:-$HOME/.local/state/fleet}/canary
work=$HOME/.cache/vm-rehearsal
[[ -s $work/uefi-virtio/disk.raw && -f $work/uefi-virtio/provision.log ]] \
  || { echo "canary: no provisioned guest in $work/uefi-virtio (tests/rehearse-install install, then provision)"; exit 75; }
git -C "$repo" fetch -q origin && git --git-dir="$HOME/.dot" fetch -q origin || { echo "canary: fetch failed"; exit 1; }
ab=$(git -C "$repo" rev-parse origin/main) dot=$(git --git-dir="$HOME/.dot" rev-parse origin/master)
if read -r lab ldot lt lres _ < "$state" 2>/dev/null && [[ $lab == "$ab" && $ldot == "$dot" ]]; then
  echo "canary: nothing new since $lt ($lres for ${ab:0:7} / ${dot:0:7})"; exit 0
fi
mkdir -p "$OPS" "$(dirname "$state")"
log=$OPS/$(uname -n)-canary-$(date +%F-%H%M).log
# flock: one guest at a time (a rehearsal by hand holds the disk's write lock too)
AB=$ab DOT=$dot AB_REPO=$repo VM_MEM=6144 VM_CPUS=6 flock -n "$work/canary.lock" "$repo/tests/rehearse-install" canary > "$log" 2>&1
rc=$?
res=pass; (( rc )) && res=FAIL
printf '%s %s %s %s %s\n' "$ab" "$dot" "$(date -Iseconds)" "$res" "$log" > "$state"
grep -E '^(FAIL|TIMEOUT|HUNG)' "$log" | head -3
echo "canary: $res for arch-bootstrap ${ab:0:7}, dotfiles ${dot:0:7} -- $log"
(( rc )) && exit 75
exit 0
