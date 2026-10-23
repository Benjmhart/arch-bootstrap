#!/usr/bin/env bash
# virus-scan -- weekly ClamAV scan of $HOME on every machine (station-maintenance beast-arch 129).
# Signatures come from clamav-freshclam.service (SYSTEM_UNITS). Exit 75 (needs you) on a hit or when there are no
# signatures yet, so chore-run notifies; quiet when clean (quiet-ok). The hit list is in ~/.local/state/chores/virus-scan.log.
# ponytail: clamscan loads the whole signature set (~1.5 GB RSS) per run; clamd only pays off for frequent scans.
set -uo pipefail
db=${CLAMAV_DB:-/var/lib/clamav}
compgen -G "$db/*.c[lv]d" >/dev/null || { echo "no ClamAV signatures in $db yet (is clamav-freshclam.service running?)"; exit 75; }
# Bulk that is not ours to scan: caches, game installs, container layers (beast-arch keeps Docker under /home),
# toolchains, and restic repos (encrypted, so no signature can match). The first run (2026-10-23) was still in
# ~/.rustup's docs on micro after 3 h, with micro's 30 GB of restic repos still ahead.
excl=(.cache .local/share/Steam/steamapps .local/share/docker .local/share/containerd .local/share/containers
      .rustup .stack .ghcup .config/restic/repo .local/share/restic-copy)
args=()
for e in "${excl[@]}"; do args+=(--exclude-dir="^$HOME/$e"); done
# Cargo build output: our own code, recompiled (beast-arch's projects are 117 GB, mostly target/).
# ponytail: skips any dir named target; narrow it if a project keeps sources under one.
args+=(--exclude-dir='/target$')
out=$(nice -n 19 ionice -c 3 clamscan -r -i --no-summary --database="$db" "${args[@]}" "$HOME" 2>&1); rc=$?
case $rc in
  0) echo "clean: $HOME" ;;
  1) printf '%s\n' "$out" | grep ' FOUND$'
     echo "$(grep -c ' FOUND$' <<<"$out") infected file(s) under $HOME -- see ~/.local/state/chores/virus-scan.log"; exit 75 ;;
  *) printf '%s\n' "$out" | tail -5; echo "clamscan failed (rc $rc)"; exit "$rc" ;;
esac
