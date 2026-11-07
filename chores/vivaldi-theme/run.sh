#!/usr/bin/env bash
# vivaldi-theme -- Vivaldi's Dracula theme once Vivaldi is closed (station-maintenance beast-arch 127; Ben 2026-11-07: "set
# it via fpush and just let it take effect later"). tools/vivaldi-theme cannot write while Vivaldi runs (it rewrites its
# Preferences on exit), so this retries every 10 minutes and at login, before Vivaldi autostarts. Waiting is not a failure:
# exit 0, and quiet-ok keeps it silent. Nothing to do once the theme is set.
set -uo pipefail
out=$(python3 -I "$(dirname "$(readlink -f "$0")")/../../tools/vivaldi-theme" 2>&1); rc=$?
case $rc in
  0) echo "${out#vivaldi-theme: }" ;;
  3) echo "waiting for Vivaldi to close" ;;
  *) echo "$out"; exit 1 ;;
esac
