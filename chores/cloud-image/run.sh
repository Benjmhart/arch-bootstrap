#!/usr/bin/env bash
# Weekly: rebuild the headless cloud image from the newest verified Arch ISO that the
# rescue-usb chore cached, boot-test it on BIOS and UEFI, and only then replace the
# last good one. Keeps one image: ~/.cache/cloud-image/arch-cloud-VER.img (raw, sparse).
# NO ROOT. Uploading to a provider is NOT done here (see station-maintenance task 85).
set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"
repo="$here/../.."
cache="${XDG_CACHE_HOME:-$HOME/.cache}"
out="$cache/cloud-image"
mkdir -p "$out"
iso=$(ls -1 "$cache"/rescue-usb/archlinux-*-x86_64.iso 2>/dev/null | sort | tail -n1)
[[ -n $iso ]] || { echo "no verified Arch ISO -- run 'chore-run rescue-usb' first"; exit 75; }
ver=$(basename "$iso" | sed 's/archlinux-\(.*\)-x86_64.iso/\1/')
img="$out/arch-cloud-$ver.img"

# Rebuilt when the ISO, the repo's HEAD or the builder changes; also weekly regardless,
# since pacstrap pulls current packages (that is the point of a refresh).
stamp=$({ echo "$ver"; git -C "$repo" rev-parse HEAD; date +%G-W%V; cat "$here"/*; } | sha256sum | cut -d' ' -f1)
if [[ -f $img && $(cat "$img.stamp" 2>/dev/null) == "$stamp" ]]; then
  echo "cloud image $(basename "$img") is current"; exit 0
fi
"$here/make-cloud-image" "$iso" "$out/.new.img"
for fw in bios uefi; do
  "$here/vm-boot-test" "$out/.new.img" "$fw" \
    || { rm -f "$out/.new.img"; echo "new cloud image did NOT pass the $fw boot test -- last good image kept"; exit 1; }
done
find "$out" -maxdepth 1 -name 'arch-cloud-*.img*' -delete
mv "$out/.new.img" "$img"; mv "$out/.new.img.log" "$img.log"
echo "$stamp" > "$img.stamp"
echo "cloud image $(basename "$img"): built and boot-tested (BIOS, UEFI), $(du -h "$img" | cut -f1) on disk"
