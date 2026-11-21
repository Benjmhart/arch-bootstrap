#!/bin/sh
# testvm-wait -- an Actions job's first step on surfboard (ACTIONS_RUNNER_HOOK_JOB_STARTED): wait while a test VM runs
# or a game is being played.
# The runner takes a hook only by a path ending .sh/.ps1/.js: without it every job failed at "Set up runner" (castiron PR #182, 2026-11-20).
# (tools/testvm). Ben 2026-11-20: "if either of the VM's are busy, surfboard should be unavailable for CI jobs".
# Timing tests failed under a busy VM (nihongo-smash PR #150, 2026-11-20). testvm stops an idle VM within 10-30 min.
# Ben 2026-11-21: "gameplay on surfboard should always take priority over other activity" (Steam starts every game as
# `reaper SteamLaunch AppId=<id>`). A job already running when a game starts is held to two CPUs (ci/game-priority.sh).
# comm is cut to 15 characters: qemu-system-x86. ponytail: any qemu counts as a test VM (surfboard runs no other); after
# 2 h the job runs anyway rather than time out, still at idle priority in ci.slice.
busy() {
  pgrep -x qemu-system-x86 >/dev/null && { why="a test VM is running"; return 0; }
  pgrep -f '[S]teamLaunch AppId=' >/dev/null && { why="a game is being played"; return 0; }
  return 1
}
end=$(( $(date +%s) + 7200 ))
while busy; do
  [ "$(date +%s)" -ge "$end" ] && { echo "testvm-wait: waited 2 h ($why): running this job now, at idle priority"; exit 0; }
  [ -n "${said:-}" ] || { echo "testvm-wait: $why on $(uname -n); this job waits its turn"; said=1; }
  sleep 30
done
[ -n "${said:-}" ] && echo "testvm-wait: surfboard is free: running"
exit 0
