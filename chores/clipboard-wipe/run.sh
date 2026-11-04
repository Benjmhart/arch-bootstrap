#!/usr/bin/env bash
# clipboard-wipe -- empty the clipboard and its history, nightly at 02:00 on every machine (station-maintenance
# beast-arch 145; Ben 2026-11-04: "wipe clipboard for the entire tailnet every night at 2am").
#   X (DISPLAY): the CLIPBOARD, PRIMARY and SECONDARY selections, then clipmenu's history (clipdel, then the clip files it
#     leaves behind; the cache is in $XDG_RUNTIME_DIR, and clipmenud keeps running).
#   Wayland (WAYLAND_DISPLAY): wl-copy --clear (both selections).
#   cliphist's database (~/.cache/cliphist, ON DISK): wiped wherever it exists.
# No session (logged out, a headless box): nothing to clear, exit 0. Quiet when ok (quiet-ok).
set -uo pipefail
done_=() fail=()
step() { local what=$1; shift; if "$@" >/dev/null 2>&1; then done_+=("$what"); else fail+=("$what"); fi; }

if [[ -n ${DISPLAY:-} ]] && xset q >/dev/null 2>&1; then   # a live X server, not a stale DISPLAY
  for s in clipboard primary secondary; do step "X $s" xsel --clear --"$s"; done
  if command -v clipdel >/dev/null; then
    # "." matches every entry; ".*" would remove clipmenu's whole directory out from under the running clipmenud.
    step "clipmenu history" clipdel -d .
  fi
  # clipdel only empties the line cache: clip files it no longer lists stay in the cache dir (150 of 264 on beast-arch,
  # 2026-11-04), still readable. Remove every clip file; keep clipmenud's line_cache and lock files.
  for d in "${CM_DIR:-${XDG_RUNTIME_DIR:-/tmp}}"/clipmenu.*."$USER"; do
    [[ -d $d ]] && step "clipmenu files" find "$d" -maxdepth 1 -type f ! -name 'line_cache*' ! -name '*lock' -delete
  done
fi
if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-copy >/dev/null; then
  step "Wayland clipboard" wl-copy --clear
  step "Wayland primary" wl-copy --primary --clear
fi
if command -v cliphist >/dev/null && [[ -e ${XDG_CACHE_HOME:-$HOME/.cache}/cliphist/db ]]; then
  step "cliphist db" cliphist wipe
fi

(( ${#fail[@]} )) && { echo "clipboard-wipe: FAILED ${fail[*]}; cleared ${done_[*]:-nothing}"; exit 1; }
echo "clipboard cleared: ${done_[*]:-nothing to clear (no session)}"
