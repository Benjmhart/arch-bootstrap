#!/usr/bin/env bash
# build-prune -- weekly: delete each Rust project's whole target/ under ~/projects that no build has written to for
# BUILD_PRUNE_DAYS days (default 14) (station-maintenance fleet 47, Ben 2026-11-22: "yes go ahead and set this up").
# 2026-11-22 the target dirs on beast-arch held 271 G (castiron 165, multiclip 55, dungeon-smash 51).
# Only a dir cargo marked as its own (CACHEDIR.TAG) goes. "Written to" = any directory down to target/<triple>/debug/deps
# changed: every build adds or replaces files there. The next build remakes it all.
# ponytail: an active project is never shrunk (castiron); cargo-sweep trims by artifact age but is unmaintained (2026-11).
# Quiet (quiet-ok): what it freed goes to the journal.
set -euo pipefail
root=${BUILD_PRUNE_ROOT:-$HOME/projects} days=${BUILD_PRUNE_DAYS:-14}
[[ -d $root ]] || { echo "no $root: nothing to prune"; exit 0; }
n=0 freed=0
while IFS= read -r -d '' tag; do
  t=${tag%/CACHEDIR.TAG}
  [[ -f ${t%/target}/Cargo.toml ]] || continue
  [[ -z $(find "$t" -maxdepth 4 -type d -newermt "-$days days" -print -quit) ]] || continue
  kb=$(du -sk "$t" | cut -f1)
  rm -rf -- "$t"
  echo "removed $t ($((kb / 1024)) M, unused $days+ days)"
  n=$((n + 1)) freed=$((freed + kb))
done < <(find "$root" -mindepth 2 -maxdepth 4 -path '*/target/CACHEDIR.TAG' -not -path '*/.git/*' -print0)
echo "build-prune: $n target dir(s) removed, $((freed / 1048576)) G freed under $root"
