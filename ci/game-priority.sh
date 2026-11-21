#!/bin/sh
# game-priority -- while a Steam game runs on surfboard, CI (ci.slice) is held to two CPUs; all of them again after.
# ci.slice is already idle-priority (ci/ci.slice), so the game wins every core it uses; this also keeps the heat and
# memory traffic of a Rust build off the cores the game runs on (a laptop). New Actions jobs wait in testvm-wait.sh.
# Steam starts every game as `reaper SteamLaunch AppId=<id> -- ...` (surfboard's console_log, 2026-11-21).
# Runs as root (game-priority.service): set-property on a system slice. --runtime: nothing survives a reboot.
CI_CPUS=${CI_CPUS:-6-7}
systemctl set-property --runtime ci.slice AllowedCPUs=   # a restart after a crash mid-game starts from "all"
on=""
while :; do
  if pgrep -f '[S]teamLaunch AppId=' >/dev/null; then
    [ -n "$on" ] || { systemctl set-property --runtime ci.slice AllowedCPUs="$CI_CPUS" && echo "a game is running: CI held to CPUs $CI_CPUS"; on=1; }
  elif [ -n "$on" ]; then
    systemctl set-property --runtime ci.slice AllowedCPUs= && echo "no game: CI gets every CPU again"; on=""
  fi
  sleep 5
done
