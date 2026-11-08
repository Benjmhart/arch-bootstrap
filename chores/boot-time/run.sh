#!/usr/bin/env bash
# boot-time -- once per boot, append how long it took and the ten slowest services to
# $OPS/<host>-boot-times.log, so boot speed is read as a trend (Ben 2026-11-08: "yes - but over time"; beast-arch 127).
# Devices are left out of the list: on micro they only mirror the disk's wait.
set -uo pipefail
log="${OPS:-$HOME/.local/state/ops}/$(uname -n)-boot-times.log"; mkdir -p "${log%/*}"
id=$(cat /proc/sys/kernel/random/boot_id)
grep -qs "boot $id" "$log" && { echo "this boot already logged"; exit 0; }
sum=$(systemd-analyze 2>/dev/null | head -1) || { echo "boot not finished yet"; exit 75; }
{ echo "== $(date -Is) boot $id"
  echo "$sum"
  systemd-analyze blame --no-pager 2>/dev/null | grep -v '\.device$' | head -10 | sed 's/^/  /'
} >> "$log"
echo "${sum#Startup finished in }"
