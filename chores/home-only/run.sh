#!/usr/bin/env bash
# home-only -- every 2 min on a laptop (carbon): home-only.target (dotfiles) runs only at home, which means on the home
# wifi AND on AC power; away, it is stopped, and so is every unit that joined it. Heavy background work joins with
#   [Unit] PartOf=home-only.target   [Install] WantedBy=home-only.target   (then `systemctl --user enable` it)
# (station-maintenance fleet 45; Ben 2026-11-22: "stop the carbon conversion job until it re-joins the garfield wifi").
# ponytail: home = one wifi SSID; a wired-only home connection reads as away. Add an ethernet check if carbon ever docks.
set -uo pipefail
target=${HOME_ONLY_TARGET:-home-only.target}
ssid=${HOME_SSID:-Garfield}
why=""
nmcli -t -f active,ssid dev wifi 2>/dev/null | grep -qxF "yes:$ssid" || why="not on $ssid"
ac=0; for s in /sys/class/power_supply/*; do
  [[ $(cat "$s/type" 2>/dev/null) == Mains && $(cat "$s/online" 2>/dev/null) == 1 ]] && ac=1; done
(( ac )) || why+="${why:+, }on battery"
if [[ -n $why ]]; then
  systemctl --user is-active --quiet "$target" || { echo "away ($why): $target already stopped"; exit 0; }
  systemctl --user stop "$target" && echo "away ($why): stopped $target and its units"
else
  systemctl --user is-active --quiet "$target" && { echo "home: $target running"; exit 0; }
  systemctl --user start "$target" && echo "home (on $ssid, on AC): started $target"
fi
