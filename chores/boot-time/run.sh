#!/usr/bin/env bash
# boot-time -- once per boot, append how long it took and the ten slowest services to
# $OPS/<host>-boot-times.log with the chain that held it up, so boot speed is read as a trend (Ben 2026-11-08: "yes - but over time"; beast-arch 127).
set -uo pipefail
log="${OPS:-$HOME/.local/state/ops}/$(uname -n)-boot-times.log"; mkdir -p "${log%/*}"
id=$(cat /proc/sys/kernel/random/boot_id)
grep -qs "boot $id" "$log" && { echo "this boot already logged"; exit 0; }
sum=$(systemd-analyze 2>/dev/null | head -1) || { echo "boot not finished yet"; exit 75; }
{ echo "== $(date -Is) boot $id"
  echo "$sum"
  # The chain that held up graphical.target, not `blame`: blame also lists units started later in the session (on micro,
  # 2026-11-08, upower at +68 min and the midnight freshclam each showed ~15 s and looked like boot costs).
  systemd-analyze critical-chain --no-pager 2>/dev/null | tail -n +3 | head -12 | sed 's/^/  /'
} >> "$log"
echo "${sum#Startup finished in }"
