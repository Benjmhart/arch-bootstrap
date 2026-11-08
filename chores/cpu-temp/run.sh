#!/usr/bin/env bash
# cpu-temp -- every 15 minutes, one line to $OPS/<host>-cpu-temp.log: time, CPU package temperature, 1-minute load
# (station-maintenance beast-arch 141; Ben 2026-11-08). The same sensor as xmobar's ~/bin/cputemp-xmobar.
set -uo pipefail
log="${OPS:-$HOME/.local/state/ops}/$(uname -n)-cpu-temp.log"; mkdir -p "${log%/*}"
for d in /sys/class/hwmon/hwmon*; do
  case $(cat "$d/name" 2>/dev/null) in coretemp|k10temp|zenpower) ;; *) continue ;; esac
  for l in "$d"/temp*_label; do
    case $(cat "$l") in "Package id 0"|Tctl|Tdie) t=$(( $(cat "${l%_label}_input") / 1000 )); break 2 ;; esac
  done
done
[[ -n ${t:-} ]] || { echo "no CPU sensor"; exit 0; }
printf '%s %s %s\n' "$(date +%FT%H:%M)" "$t" "$(cut -d' ' -f1 /proc/loadavg)" >> "$log"
echo "${t} C"
