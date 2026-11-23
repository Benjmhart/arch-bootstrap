#!/bin/sh
# game-priority -- people first on surfboard. While a Steam game runs, or Ben is at the desk or typing in a shell there
# (ssh or a terminal; input in the last IDLE_MIN minutes), ci.slice (Actions/GitLab jobs, and test runs offloaded with
# surf-test) is held to two CPUs and CI_MEM of memory, and $CI_HOLD names why: testvm-wait.sh keeps new jobs waiting
# while it exists. All of it again after.
# Ben 2026-11-21: "gameplay on surfboard should always take priority over other activity". Ben 2026-11-22: "user
# interactions via ssh or direct access should always take preference over ci, tests, builds, or conversions" and
# "make sure it doesn't override the memory preference for games" (station-maintenance fleet 47).
# ci.slice is already idle-priority (ci/ci.slice), so a game or the desk wins every core it uses; the hold also keeps the
# heat and memory of a Rust build off the machine. Steam starts every game as `reaper SteamLaunch AppId=<id> -- ...`.
# Desk = X idle time (xprintidle on :0). Shell = a /dev/pts with input read lately (a tty's atime is its last input;
# agents' own `ssh host cmd` has no tty, so it never counts).
# Runs as root (game-priority.service): set-property on a system slice. --runtime: nothing survives a reboot.
CI_CPUS=${CI_CPUS:-6-7} CI_MEM=${CI_MEM:-8G} IDLE_MIN=${IDLE_MIN:-5} CI_HOLD=${CI_HOLD:-/run/ci-hold}
why() {
  pgrep -f '[S]teamLaunch AppId=' >/dev/null && { echo "a game is being played"; return 0; }
  ms=$(DISPLAY=:0 XAUTHORITY=/home/ben/.Xauthority xprintidle 2>/dev/null) &&
    [ "$ms" -lt $((IDLE_MIN * 60000)) ] && { echo "Ben is at the desk"; return 0; }
  [ -n "$(find /dev/pts -maxdepth 1 -name '[0-9]*' -amin -"$IDLE_MIN" -print -quit 2>/dev/null)" ] &&
    echo "Ben is using a shell there (ssh or a terminal)"
  return 0
}
[ "${1:-}" = --why ] && { why; exit 0; }   # what it would decide now, changing nothing
hold() { systemctl set-property --runtime ci.slice AllowedCPUs="$1" MemoryHigh="$2"; }
hold "" infinity; rm -f "$CI_HOLD"   # a restart after a crash mid-game starts from "all"
on=""
while :; do
  w=$(why)
  if [ -n "$w" ]; then
    [ -n "$on" ] || { hold "$CI_CPUS" "$CI_MEM" && echo "$w: CI held to CPUs $CI_CPUS and $CI_MEM"; on=1; }
    [ "$w" = "$(cat "$CI_HOLD" 2>/dev/null)" ] || echo "$w" > "$CI_HOLD"
  elif [ -n "$on" ]; then
    hold "" infinity && echo "nobody is using surfboard: CI gets every CPU and all memory again"
    rm -f "$CI_HOLD"; on=""
  fi
  sleep 5
done
