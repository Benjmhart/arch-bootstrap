#!/usr/bin/env bash
#
# install.sh -- unattended archinstall, from the Arch ISO, in about five answers.
#
# Run as root on the live ISO:
#
#   curl -fsSLO https://raw.githubusercontent.com/Benjmhart/arch-bootstrap/main/install.sh
#   bash install.sh [hostname] [username]
#
# It asks for: the target drive, the disk-encryption password, and the user
# password (Enter = same as the disk password). Hostname and username come from
# the arguments, or are asked with a default. Then it WIPES the drive and runs
# archinstall with a generated configuration -- no archinstall menus at all.
#
# What it installs (mirrors how beast-arch was built by hand):
#   GPT on UEFI / msdos on BIOS, archinstall's own default layout, reproduced here:
#     1 GiB fat32 /boot   (unencrypted -- GRUB and the kernel have to be readable)
#     ext4 /      32 GiB (disk < 320 GiB), disk/10 (320-500 GiB), 50 GiB (> 500 GiB)
#     ext4 /home  the rest
#   BOTH / and /home LUKS-encrypted, one passphrase at boot: archinstall adds the
#   `encrypt` hook and cryptdevice= for /, and unlocks /home with a keyfile kept
#   on the encrypted root (/etc/cryptsetup-keys.d/home.key). Encrypting only
#   /home -- how beast-arch was built before 2026-09-30 -- left /etc, /usr and
#   /var readable and writable offline; after the phishing incident that
#   prompted this script, root is encrypted by default.
#   GRUB, linux kernel, NetworkManager, pipewire, zram swap, en_US.UTF-8, us keymap,
#   America/Toronto with NTP, one sudo user, root locked (sudo only),
#   plus base-devel git zsh openssh github-cli -- what bootstrap.sh needs to start.
#   Xorg and everything else come later, from bootstrap.sh.
#
# Why the layout is computed HERE: archinstall's JSON cannot ask it for its
# default layout. "config_type": "default_layout" is only a label; the parser
# builds partitions solely from explicit start/size values (archinstall 4.5,
# lib/models/device.py DiskLayoutConfiguration.parse_arg). The arithmetic below
# is archinstall's own (lib/disk/default_layouts.py suggest_single_disk_layout),
# checked against it at 12 disk sizes on both firmware types.
#
# Validated against archinstall 4.4 (on the 2026.08/09 ISOs) and 4.5 with their
# own config parser and partitioner on disk images. NOT yet run end to end on
# real hardware -- first use should be a VM or a disk you can lose.
#
# Options:
#   --home-only-encryption  encrypt /home but NOT / (the pre-2026-09-30 layout)
#   --render-only DIR       write the two JSON files to DIR and stop (testing)
#   --disk PATH             skip the drive prompt
#
# Testing overrides (with --render-only): DISK_SIZE_BYTES, FIRMWARE=uefi|bios,
# LUKS_PASSWORD, USER_PASSWORD.

set -euo pipefail

TIMEZONE="America/Toronto"
LOCALE="en_US.UTF-8"
KEYMAP="us"
EXTRA_PACKAGES=(base-devel git zsh openssh github-cli)
TESTED_ARCHINSTALL="4.4 4.5"

die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
info() { printf '  --  %s\n' "$*"; }
ask()  { local __v=$1 prompt=$2 def=${3:-} ans; read -r -p "$prompt${def:+ [$def]}: " ans </dev/tty; printf -v "$__v" '%s' "${ans:-$def}"; }

encrypt_root=1 render_dir="" disk_arg=""
pos=()
while (( $# )); do
  case $1 in
    --home-only-encryption) encrypt_root=0 ;;
    --render-only)  render_dir="${2:?--render-only needs a directory}"; shift ;;
    --disk)         disk_arg="${2:?--disk needs a path}"; shift ;;
    -h|--help)      sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*)             die "unknown option $1" ;;
    *)              pos+=("$1") ;;
  esac
  shift
done

if [[ -z $render_dir ]]; then
  (( EUID == 0 )) || die "run as root on the Arch ISO"
  have_ai="$(archinstall --version 2>/dev/null || true)"
  [[ -n $have_ai ]] || die "archinstall not found -- is this the Arch ISO?"
  [[ " $TESTED_ARCHINSTALL " == *" ${have_ai%%-*} "* ]] \
    || printf 'warn  archinstall %s is untested with this script (tested: %s)\n' \
         "$have_ai" "$TESTED_ARCHINSTALL" >&2
fi

# ---- target drive ----------------------------------------------------------
#
# The path must be the one parted reports: archinstall looks the device up by
# exact path, and an unknown path is DROPPED SILENTLY -- with encryption off that
# parses as "zero disks" and installs nothing. So resolve symlinks, and insist
# on a whole disk.
if [[ -n $disk_arg ]]; then
  disk="$disk_arg"
elif [[ -n $render_dir ]]; then
  die "--render-only needs --disk"
else
  mapfile -t disks < <(lsblk -dpno NAME,TYPE,RM | awk '$2=="disk" && $3=="0" {print $1}')
  (( ${#disks[@]} )) || die "no non-removable disks found"
  printf '\nDisks:\n'
  i=0
  for d in "${disks[@]}"; do
    i=$((i+1))
    printf '  %d) %s  %s  %s\n' "$i" "$d" \
      "$(lsblk -dno SIZE "$d" | tr -d ' ')" "$(lsblk -dno MODEL "$d" 2>/dev/null | sed 's/ *$//')"
  done
  def=""; (( ${#disks[@]} == 1 )) && def=1
  ask n "Install to which disk (number)" "$def"
  [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#disks[@]} )) || die "no such disk: $n"
  disk="${disks[n-1]}"
fi
[[ -e $disk ]] && disk="$(readlink -f -- "$disk")"
if [[ -z $render_dir ]]; then
  [[ -b $disk ]] || die "$disk is not a block device"
  [[ $(lsblk -dno TYPE "$disk") == disk ]] || die "$disk is not a whole disk"
fi

# ---- names -----------------------------------------------------------------
host="${pos[0]:-}" user="${pos[1]:-}"
[[ -n $host || -n $render_dir ]] || ask host "Hostname" "archlinux"
[[ -n $user || -n $render_dir ]] || ask user "Username" "user"
[[ $host =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "bad hostname: '$host'"
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]           || die "bad username: '$user'"

# ---- passwords -------------------------------------------------------------
#
# An EMPTY encryption password makes archinstall install UNENCRYPTED without a
# word (lib/models/device.py, 4.5). Refuse it here.
read_pw() {  # read_pw VAR "prompt" allow_empty
  local __v=$1 a b
  while :; do
    read -r -s -p "$2: " a </dev/tty; echo
    if [[ -z $a ]]; then
      [[ $3 == 1 ]] && { printf -v "$__v" ''; return; }
      echo "  cannot be empty"; continue
    fi
    read -r -s -p "  again: " b </dev/tty; echo
    [[ $a == "$b" ]] && { printf -v "$__v" '%s' "$a"; return; }
    echo "  did not match -- try again"
  done
}
if [[ -z ${LUKS_PASSWORD:-} ]]; then
  [[ -z $render_dir ]] || die "--render-only needs LUKS_PASSWORD in the environment"
  echo
  read_pw LUKS_PASSWORD "Disk encryption password" 0
fi
if [[ -z ${USER_PASSWORD:-} && -z $render_dir ]]; then
  read_pw USER_PASSWORD "Password for $user (Enter = same as the disk password)" 1
fi
USER_PASSWORD="${USER_PASSWORD:-$LUKS_PASSWORD}"

# ---- layout ----------------------------------------------------------------
MiB=$((1024*1024)); GiB=$((1024*MiB))
total="${DISK_SIZE_BYTES:-$(blockdev --getsize64 "$disk")}"
if [[ -n ${FIRMWARE:-} ]]; then fw=$FIRMWARE
elif [[ -d /sys/firmware/efi ]]; then fw=uefi
else fw=bios; fi

# archinstall only offers a separate /home at >= 64 GiB.
(( total >= 64*GiB )) || die "disk is under 64 GiB -- this layout needs a separate /home"
total_gib=$(( total / GiB ))
if   (( total_gib > 500 )); then root_gib=50
elif (( total_gib < 320 )); then root_gib=32
else root_gib=$(( total_gib / 10 )); fi
root_mib=$(( root_gib * 1024 ))
if [[ $fw == uefi ]]; then avail_mib=$(( (total - MiB) / MiB ))   # backup GPT header
else avail_mib=$(( total / MiB )); fi
home_start_mib=$(( 1025 + root_mib ))
home_mib=$(( avail_mib - home_start_mib ))
(( home_mib > 0 )) || die "no room for /home"

# ---- confirm ---------------------------------------------------------------
if [[ -z $render_dir ]]; then
  printf '\n'
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$disk"
  printf '\nAbout to ERASE %s and install Arch:\n' "$disk"
  printf '  host %s, user %s, %s boot, / %s GiB (%s), /home %s GiB (encrypted)\n' \
    "$host" "$user" "$fw" "$root_gib" "$( ((encrypt_root)) && echo encrypted || echo NOT encrypted)" \
    "$(( home_mib / 1024 ))"
  ask confirm "Type WIPE to continue"
  [[ $confirm == WIPE ]] || die "not confirmed -- nothing was changed"
fi

# ---- render ----------------------------------------------------------------
out="${render_dir:-$(mktemp -d /tmp/archinstall.XXXXXX)}"
mkdir -p "$out"; chmod 700 "$out"
cleanup() { [[ -n $render_dir ]] || rm -f "$out/user_credentials.json"; }
trap cleanup EXIT

# The user password goes in as a yescrypt hash made by archinstall's own helper,
# so the plaintext never reaches a file. The LUKS password has to be plaintext --
# it is what archinstall formats the volume with -- so the credentials file is
# mode 600 in a 700 directory on the ISO's tmpfs, and deleted on exit.
# NEVER add --debug to the archinstall call below: it writes the credentials
# into install.log, and that log is copied into the installed system.
export IS_DISK="$disk" IS_HOST="$host" IS_USER="$user" IS_FW="$fw" \
       IS_ROOT_MIB="$root_mib" IS_HOME_START="$home_start_mib" IS_HOME_MIB="$home_mib" \
       IS_ENCRYPT_ROOT="$encrypt_root" IS_TZ="$TIMEZONE" IS_LOCALE="$LOCALE" \
       IS_KEYMAP="$KEYMAP" IS_PKGS="${EXTRA_PACKAGES[*]}" IS_OUT="$out" \
       IS_LUKS="$LUKS_PASSWORD" IS_UPW="$USER_PASSWORD"
umask 077
"${PYTHON:-python3}" - <<'PY'
import json, os, sys
e = os.environ
def size(v, unit="MiB"):
    return {"value": int(v), "unit": unit, "sector_size": {"value": 512, "unit": "B"}}
uefi = e["IS_FW"] == "uefi"
ROOT, HOME, BOOT = ("9dbda828-aaaa-4024-8fff-098ef9dca776",
                    "751585c1-9f9f-4f12-8119-dc0d7656a5f1",
                    "8c5ffa14-b178-46b3-97de-384db16ee566")
def part(obj_id, start, sz, fs, mnt, flags):
    return {"obj_id": obj_id, "status": "create", "type": "primary",
            "start": size(start), "size": sz, "fs_type": fs, "mountpoint": mnt,
            "mount_options": [], "flags": flags, "btrfs": [], "dev_path": None}
cfg = {
  "archinstall-language": "English",
  "script": "guided",
  "disk_config": {
    "config_type": "default_layout",
    "device_modifications": [{
      "device": e["IS_DISK"], "wipe": True,
      "partitions": [
        part(BOOT, 1, size(1, "GiB"), "fat32", "/boot", ["boot", "esp"] if uefi else ["boot"]),
        part(ROOT, 1025, size(e["IS_ROOT_MIB"]), "ext4", "/", []),
        part(HOME, e["IS_HOME_START"], size(e["IS_HOME_MIB"]), "ext4", "/home",
             ["linux-home"] if uefi else []),
      ]}],
    "disk_encryption": {"encryption_type": "luks",
                        "partitions": [ROOT, HOME] if e["IS_ENCRYPT_ROOT"] == "1" else [HOME],
                        "lvm_volumes": []},
  },
  "bootloader_config": {"bootloader": "Grub", "uki": False, "removable": True},
  "kernels": ["linux"],
  "hostname": e["IS_HOST"],
  "locale_config": {"kb_layout": e["IS_KEYMAP"], "sys_lang": e["IS_LOCALE"], "sys_enc": "UTF-8"},
  "timezone": e["IS_TZ"],
  "ntp": True,
  "network_config": {"type": "nm"},
  "app_config": {"audio_config": {"audio": "pipewire"}},
  "profile_config": {"profile": {"main": "Minimal"}, "gfx_driver": None, "greeter": None},
  "swap": {"enabled": True, "algorithm": "zstd"},
  "packages": e["IS_PKGS"].split(),
  "pacman_config": {"parallel_downloads": 5, "color": True},
  "services": [],
  "custom_commands": [],
}
try:
    from archinstall.lib.crypt import crypt_yescrypt
except Exception as ex:
    sys.exit(f"cannot import archinstall's crypt helper ({ex}) -- is this the Arch ISO?")
h = crypt_yescrypt(e["IS_UPW"])
if not h.startswith("$y$"):
    sys.exit("password hashing failed")
if not e["IS_LUKS"]:
    sys.exit("empty encryption password -- archinstall would install UNENCRYPTED")
creds = {"encryption_password": e["IS_LUKS"],
         "users": [{"username": e["IS_USER"], "enc_password": h, "sudo": True, "groups": []}]}
out = e["IS_OUT"]
with open(os.path.join(out, "user_configuration.json"), "w") as f: json.dump(cfg, f, indent=2)
with open(os.path.join(out, "user_credentials.json"), "w") as f: json.dump(creds, f, indent=2)
PY
unset IS_LUKS IS_UPW

if [[ -n $render_dir ]]; then
  info "rendered to $out (fw=$fw root=${root_mib}MiB home_start=${home_start_mib}MiB home=${home_mib}MiB)"
  exit 0
fi

# ---- install ---------------------------------------------------------------
# --silent skips archinstall's menu AND its final confirmation (the WIPE prompt
# above replaced it). --skip-wifi-check: otherwise, with no network, the Wi-Fi TUI
# opens even under --silent.
archinstall --config "$out/user_configuration.json" --creds "$out/user_credentials.json" \
  --silent --skip-wifi-check
rm -f "$out/user_credentials.json"

# ---- verify ----------------------------------------------------------------
# archinstall can exit 0 on failure (a bootloader-validation failure, "No disk
# configuration"), so check the result instead of trusting the status. The
# target is still mounted at /mnt: Installer.__exit__ syncs but never unmounts
# (lib/installer.py @ 4.5), which is what its post-install chroot option relies on.
fails=0
chk() { if eval "$2"; then info "ok: $1"; else printf 'FAIL  %s\n' "$1" >&2; fails=$((fails+1)); fi; }
chk "archinstall reported success" \
  "grep -q 'Installation completed without any errors' /var/log/archinstall/install.log"
chk "fstab written"          "[ -s /mnt/etc/fstab ]"
chk "grub.cfg generated"     "[ -s /mnt/boot/grub/grub.cfg ]"
chk "user $user exists"      "grep -q '^$user:' /mnt/etc/passwd"
chk "/home is LUKS"          "grep -q luks /mnt/etc/crypttab || grep -q cryptdevice /mnt/etc/default/grub"
chk "hostname set"           "[ \"\$(cat /mnt/etc/hostname 2>/dev/null)\" = '$host' ]"
if (( fails )); then
  printf '\n%d check(s) failed. The log is /var/log/archinstall/install.log (and\n' "$fails" >&2
  printf 'under /mnt/var/log/archinstall/ if it got that far). Do not reboot yet.\n' >&2
  exit 1
fi

cat <<EOF

Installed. Reboot, log in as $user on the TTY, then:

  git clone https://github.com/Benjmhart/arch-bootstrap ~/projects/arch-bootstrap
  cd ~/projects/arch-bootstrap && ./bootstrap.sh

EOF
