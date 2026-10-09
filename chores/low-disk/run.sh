#!/usr/bin/env bash
# low-disk -- warn when any local filesystem is LOW_DISK_PCT% full or more (default 90).
# Hourly on every machine (station-maintenance beast-arch 76): a full root is how the 2026-10-04
# runner move went wrong, and a full /boot fails a kernel upgrade half-way. Exit 75 (needs you)
# when one is over, so chore-run notifies; quiet when all are fine (quiet-ok beside this file).
set -euo pipefail
limit=${LOW_DISK_PCT:-90}
over=() all=()
while read -r pct avail target; do
  pct=${pct%\%}
  [[ $target == /run/media/* ]] && continue      # USB sticks fill up on purpose
  all+=("$target $pct%")
  (( pct >= limit )) && over+=("$target $pct% ($avail free)")
done < <(df -h --local --output=pcent,avail,target \
           -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay -x iso9660 | tail -n +2 | sort -u -k3)
if (( ${#over[@]} )); then
  printf '%s\n' "${over[@]}"
  echo "${#over[@]} filesystem(s) at ${limit}%+: ${over[*]}"
  exit 75
fi
echo "all below ${limit}%: ${all[*]}"
