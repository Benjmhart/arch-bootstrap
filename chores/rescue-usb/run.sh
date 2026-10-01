#!/usr/bin/env bash
# Weekly: put the current, signature-verified Arch ISO on the Ventoy rescue stick,
# with this repo's install.sh / bootstrap.sh beside it. NO ROOT: the stick is mounted
# through udisks. Installing or upgrading Ventoy itself does need root, so that is
# reported (exit 75) rather than done.
#
# Config (bootstrap.conf): RESCUE_USB_SERIAL -- the stick's USB serial, from
#   lsblk -dno PATH,SERIAL,TRAN | grep usb
set -euo pipefail
: "${RESCUE_USB_SERIAL:?set RESCUE_USB_SERIAL in bootstrap.conf}"
repo="$(dirname "$(readlink -f "$0")")/../.."
cache="${XDG_CACHE_HOME:-$HOME/.cache}/rescue-usb"
keyring=/usr/share/pacman/keyrings/archlinux.gpg
keep=2            # ISOs kept on the stick: the new one, and the last one known good
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

# ---- onto the stick
mount_dev "$data"
if [[ ! -f $mnt/$iso ]]; then
  echo "copying $iso to the stick"
  cp "$cache/$iso" "$mnt/.$iso.part"
  sync
  echo "$sha  $mnt/.$iso.part" | sha256sum -c --quiet \
    || { rm -f "$mnt/.$iso.part"; echo "copy on the stick does not match -- removed"; exit 1; }
  mv "$mnt/.$iso.part" "$mnt/$iso"
fi

# ---- boot the copy ON THE STICK in a throwaway VM. Older ISOs are pruned only after it
# passes, so a new ISO that does not boot leaves the last known-good one in place.
boot=0; "$(dirname "$(readlink -f "$0")")/vm-boot-test" "$mnt/$iso" || boot=$?
if (( boot == 1 )); then
  echo "$iso is on the stick but did NOT boot in the VM -- older ISOs kept"; exit 1
fi
(( boot == 0 )) || keep=99      # could not test: prune nothing
# Newest $keep ISOs stay (names sort by date); anything else of ours goes.
{ ls -1 "$mnt"/archlinux-*-x86_64.iso 2>/dev/null || true; } | sort -r | tail -n +$((keep + 1)) | xargs -r -d '\n' rm -f --

mkdir -p "$mnt/arch-bootstrap"
cp "$repo"/{install.sh,bootstrap.sh,bootstrap.conf.example,README.md} "$repo"/pkglist-*.txt "$mnt/arch-bootstrap/"
cp -r "$repo"/tools "$mnt/arch-bootstrap/"   # e.g. encrypt-root-in-place, run from this stick
{ git -C "$repo" log -1 --format='arch-bootstrap %H (%cd)'
  [[ -z $(git -C "$repo" status --porcelain) ]] || echo "  PLUS UNCOMMITTED CHANGES -- these files are not exactly that commit"
} > "$mnt/arch-bootstrap/COMMIT"
on_stick=$(cd "$mnt" && ls -1 archlinux-*-x86_64.iso | tr '\n' ' ')

# ---- Ventoy itself: report, don't fix (root)
want=$(cat /opt/ventoy/ventoy/version 2>/dev/null || true)
mount_dev "$efi" ro
have=$(grep -ohE 'VENTOY_VERSION="[0-9.]+' "$mnt/grub/grub.cfg" | cut -d'"' -f2 || true)
if [[ -z $want ]]; then
  echo "ISOs: $on_stick| Ventoy $have on stick; ventoy-bin not installed here, so currency unknown"; exit 75
elif [[ $have != "$want" ]]; then
  echo "ISOs: $on_stick| Ventoy $have on stick, $want available: sudo ventoy -u $disk"; exit 75
fi
if (( boot )); then
  echo "ISOs: $on_stick| Ventoy $have (current) | NOT boot-tested (no qemu or /dev/kvm -- see the log)"; exit 75
fi
echo "ISOs: $on_stick| Ventoy $have (current) | VM boot ok"
