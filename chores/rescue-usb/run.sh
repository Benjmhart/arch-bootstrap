#!/usr/bin/env bash
# Weekly: put the current, signature-verified Arch ISO on the Ventoy rescue stick, plus
# rescue-archlinux-VER.iso -- the same ISO with this repo's tools/ on PATH
# (make-rescue-iso) -- and install.sh / bootstrap.sh beside them. NO ROOT: the stick is mounted
# through udisks. Installing or upgrading Ventoy itself does need root, so that is
# reported (exit 75) rather than done.
#
# Config (bootstrap.conf): RESCUE_USB_SERIAL -- the stick's USB serial, from
#   lsblk -dno PATH,SERIAL,TRAN | grep usb
set -euo pipefail
: "${RESCUE_USB_SERIAL:?set RESCUE_USB_SERIAL in bootstrap.conf}"
here="$(dirname "$(readlink -f "$0")")"
repo="$here/../.."
cache="${XDG_CACHE_HOME:-$HOME/.cache}/rescue-usb"
keyring=/usr/share/pacman/keyrings/archlinux.gpg
mkdir -p "$cache"

# ---- the stick: by USB serial, never by /dev name (that changes with plug order)
disk=$(lsblk -dno PATH,SERIAL | awk -v s="$RESCUE_USB_SERIAL" '$2==s {print $1}')
[[ -n $disk ]] || { echo "rescue stick (serial $RESCUE_USB_SERIAL) is not plugged in"; exit 75; }
part() { lsblk -lno PATH,LABEL "$disk" | awk -v l="$1" '$2==l {print $1}'; }
data=$(part Ventoy); efi=$(part VTOYEFI)
[[ -n $data && -n $efi ]] || { echo "$disk has no Ventoy partitions: sudo ventoy -i $disk (ERASES it)"; exit 75; }

# Mount through udisks if nothing has; put things back as they were afterwards.
mounted_by_us=()
mnt=""
mount_dev() {       # $1 device, $2 extra udisks options; sets $mnt (no subshell, or
                    # mounted_by_us would be lost and the stick left mounted)
  mnt=$(findmnt -no TARGET "$1" || true)
  if [[ -z $mnt ]]; then
    udisksctl mount -b "$1" ${2:+-o "$2"} >/dev/null
    mounted_by_us+=("$1"); mnt=$(findmnt -no TARGET "$1")
  fi
}
cleanup() { sync; for d in "${mounted_by_us[@]}"; do udisksctl unmount -b "$d" >/dev/null || true; done; }
trap cleanup EXIT

# ---- the release: version, checksum and signing key from archlinux.org
rel=$(curl -fsSL https://archlinux.org/releng/releases/json/)
ver=$(jq -r .latest_version <<<"$rel")
pick() { jq -r --arg v "$ver" --arg k "$1" '.releases[] | select(.version==$v) | .[$k]' <<<"$rel"; }
sha=$(pick sha256_sum); fpr=$(pick pgp_fingerprint)
iso="archlinux-$ver-x86_64.iso"
[[ $ver =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ && $sha =~ ^[0-9a-f]{64}$ ]] \
  || { echo "unexpected release data from archlinux.org (version '$ver')"; exit 1; }

# ---- download once and verify: the ISO from a mirror, the signature from archlinux.org
if [[ ! -f $cache/$iso ]]; then
  # sed quits on the first match itself: `| head -n1` would SIGPIPE sed, and pipefail
  # turns that into exit 141 -- which is how the first real run died, silently.
  mirror=$(sed -n 's|^Server *= *\(.*\)/\$repo/os/\$arch.*|\1|p;T;q' /etc/pacman.d/mirrorlist)
  echo "downloading $iso from $mirror"
  curl -fL --retry 3 --no-progress-meter -o "$cache/$iso.part" "$mirror/iso/$ver/$iso"
  curl -fsSL -o "$cache/$iso.sig" "https://archlinux.org/iso/$ver/$iso.sig"

  # The keyring is the one pacman installed (archlinux-keyring), not anything fetched now.
  # It ships ASCII-armoured and gpgv reads only binary ("invalid packet (ctb=2d)", which
  # rejected a good ISO on the first run) -- so de-armour a copy, every time, from source.
  gpg --batch --homedir "$(mktemp -d)" --dearmor < "$keyring" > "$cache/keyring.gpg"
  st=$(gpgv --status-fd 1 --keyring "$cache/keyring.gpg" "$cache/$iso.sig" "$cache/$iso.part" 2>/dev/null) \
    || { echo "BAD SIGNATURE on $iso -- not used"; exit 1; }
  read -r signer primary < <(awk '$2=="VALIDSIG" {print $3, $NF}' <<<"$st") || true
  [[ -n ${primary:-} ]] || { echo "no valid signature on $iso -- not used"; exit 1; }
  [[ ${fpr^^} == "${signer^^}" || ${fpr^^} == "${primary^^}" ]] \
    || { echo "$iso signed by $primary, but archlinux.org names $fpr -- not used"; exit 1; }
  ! grep -qix "$primary" "${keyring%.gpg}-revoked" \
    || { echo "$iso signed by REVOKED key $primary -- not used"; exit 1; }
  echo "$sha  $cache/$iso.part" | sha256sum -c --quiet \
    || { echo "$iso checksum mismatch -- not used"; exit 1; }
  mv "$cache/$iso.part" "$cache/$iso"
  find "$cache" -maxdepth 1 -name 'archlinux-*' ! -name "$iso*" -delete
  rm -f "$cache/keyring.gpg"
  echo "verified $iso: signature by ${primary: -16}, sha256 matches archlinux.org"
fi

# ---- the rescue ISO, rebuilt when the ISO, tools/ or the builder changes
rescue="rescue-archlinux-$ver.iso"
stamp=$({ echo "$sha"; cat "$repo"/tools/* "$here/make-rescue-iso"; } | sha256sum | cut -d' ' -f1)
built=0
if [[ ! -f $cache/$rescue || $(cut -d' ' -f3 "$cache/$rescue.sha256" 2>/dev/null) != "$stamp" ]]; then
  rm -f "$cache"/rescue-archlinux-*
  "$here/make-rescue-iso" "$cache/$iso" "$cache/$rescue" || built=$?
  if (( built == 0 )); then
    echo "$(sha256sum < "$cache/$rescue" | cut -d' ' -f1) stamp $stamp" > "$cache/$rescue.sha256"
  elif (( built != 75 )); then
    echo "building $rescue FAILED -- stick left as it was"; exit 1
  fi
fi

# ---- onto the stick: copy, then check the copy, never trust cp
mount_dev "$data"
put() {             # $1 file in $cache, $2 its sha256
  [[ -f $mnt/$1 ]] && echo "$2  $mnt/$1" | sha256sum -c --quiet 2>/dev/null && return
  echo "copying $1 to the stick"
  cp "$cache/$1" "$mnt/.$1.part"
  sync
  echo "$2  $mnt/.$1.part" | sha256sum -c --quiet \
    || { rm -f "$mnt/.$1.part"; echo "copy of $1 on the stick does not match -- removed"; exit 1; }
  mv "$mnt/.$1.part" "$mnt/$1"
}
put "$iso" "$sha"
if (( built == 0 )); then put "$rescue" "$(cut -d' ' -f1 "$cache/$rescue.sha256")"; fi

# ---- boot the copies ON THE STICK in a throwaway VM; the rescue ISO must also have its
# tools on PATH. Old ISOs are pruned only after both pass, so an ISO that does not boot
# leaves the last known-good ones in place.
boot=0; "$here/vm-boot-test" "$mnt/$iso" || boot=$?
if (( boot == 0 && built == 0 )); then
  "$here/vm-boot-test" "$mnt/$rescue" 'command -v encrypt-root-in-place' || boot=$?
fi
if (( boot == 1 )); then
  echo "a new ISO is on the stick but did NOT pass the VM test -- older ISOs kept"; exit 1
fi
if (( boot == 0 && built == 0 )); then   # everything current passed: drop the rest
  for f in "$mnt"/archlinux-*-x86_64.iso "$mnt"/rescue-archlinux-*.iso; do
    [[ -f $f && ${f##*/} != "$iso" && ${f##*/} != "$rescue" ]] && rm -f -- "$f"
  done
fi

mkdir -p "$mnt/arch-bootstrap"
cp "$repo"/{install.sh,bootstrap.sh,bootstrap.conf.example,README.md} "$repo"/pkglist-*.txt "$mnt/arch-bootstrap/"
cp -r "$repo"/tools "$mnt/arch-bootstrap/"   # e.g. encrypt-root-in-place, run from this stick
{ git -C "$repo" log -1 --format='arch-bootstrap %H (%cd)'
  [[ -z $(git -C "$repo" status --porcelain) ]] || echo "  PLUS UNCOMMITTED CHANGES -- these files are not exactly that commit"
} > "$mnt/arch-bootstrap/COMMIT"
on_stick=$(cd "$mnt" && ls -1 archlinux-*-x86_64.iso rescue-archlinux-*.iso 2>/dev/null | tr '\n' ' ')

# ---- Ventoy itself: report, don't fix (root)
want=$(cat /opt/ventoy/ventoy/version 2>/dev/null || true)
mount_dev "$efi" ro
have=$(grep -ohE 'VENTOY_VERSION="[0-9.]+' "$mnt/grub/grub.cfg" | cut -d'"' -f2 || true)
if [[ -z $want ]]; then
  echo "ISOs: $on_stick| Ventoy $have on stick; ventoy-bin not installed here, so currency unknown"; exit 75
elif [[ $have != "$want" ]]; then
  echo "ISOs: $on_stick| Ventoy $have on stick, $want available: sudo ventoy -u $disk"; exit 75
fi
if (( built )); then
  echo "ISOs: $on_stick| Ventoy $have (current) | rescue ISO NOT built (see the log)"; exit 75
fi
if (( boot )); then
  echo "ISOs: $on_stick| Ventoy $have (current) | NOT boot-tested (no qemu or /dev/kvm -- see the log)"; exit 75
fi
echo "ISOs: $on_stick| Ventoy $have (current) | VM boot ok"
