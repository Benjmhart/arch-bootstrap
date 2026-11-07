#!/bin/bash
# remote-unlock (station-maintenance surfboard 04; Ben 2026-10-31): the initramfs gets online (DHCP on every interface,
# Wi-Fi too where the machine has no cable), joins the tailnet as its own node "<host>-boot" (tag:unlock: reachable on
# :22 from micro, carbon and beast-arch, reaches nothing), and runs sshd, so `tools/unlock <host>` answers the LUKS
# passphrase prompt from anywhere -- after a YubiKey touch, since only sk keys may log in. Inputs in /etc/remote-unlock
# (root, 0600), written by arch-bootstrap (setup_remote_unlock) and tools/remote-unlock-enroll:
#   tailscaled.state      the boot node's identity (enrolled once; Tailnet Lock signs it)
#   ssh_host_ed25519_key  this initramfs's own host key          authorized_keys  sk keys, forced command
#   wpa_supplicant.conf   only on a machine whose network is Wi-Fi
# All of it sits in the image on the unencrypted /boot: someone with the disk can read the Wi-Fi psk, run the boot node
# elsewhere (it can only be connected to) and present the host key. The disk itself still needs the passphrase.
# Without tailscaled.state (a cloud box, tools/cloud-box; Ben 2026-11-05: boxes are inbound-only, off the tailnet) the
# initramfs has no tailscale at all and sshd answers on the box's public address. sshd_config here, if present,
# replaces the module's own (tools/cloud-box writes one only for a test box's plain key, CLOUD_BOX_EXTRA_LOGIN_KEY).

check() {
    require_binaries ip sshd systemd-tty-ask-password-agent || return 1
    return 255   # only when asked for (add_dracutmodules)
}

depends() {
    echo systemd systemd-ask-password systemd-networkd
}

install() {
    local c=${REMOTE_UNLOCK_DIR:-/etc/remote-unlock}   # the override is for building a test image as a user
    local ts=; [[ -e $c/tailscaled.state ]] && ts=1
    local f; for f in authorized_keys ssh_host_ed25519_key; do
        [[ -r $c/$f ]] || { dfatal "remote-unlock: $c/$f missing"; return 1; }
    done
    # Every network driver this machine uses (hostonly would keep only the disk's), plus what WPA2 needs.
    local n m; for n in /sys/class/net/*/device/driver/module; do
        [[ -e $n ]] || continue
        m=$(basename "$(readlink -f "$n")")
        hostonly='' instmods "$m"
        [[ $m == iwlwifi ]] && hostonly='' instmods iwlmvm iwldvm
    done
    hostonly='' instmods cfg80211 mac80211 ccm gcm ctr cmac
    inst_multiple -o /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s
    inst_multiple ip sleep seq ls cat kill rm true sshd systemd-tty-ask-password-agent wc sed head tail timeout systemctl
    inst_multiple -o journalctl   # unlock-prompt's status lines (carbon 12)
    inst_multiple -o /usr/lib/ssh/sshd-session /usr/lib/ssh/sshd-auth wpa_supplicant
    if [[ $ts ]]; then
        inst_multiple tailscaled
        # Go reads the CA bundle here for TLS to the control server (a symlink into /etc/ca-certificates on Arch).
        inst_multiple /etc/ssl/certs/ca-certificates.crt "$(readlink -f /etc/ssl/certs/ca-certificates.crt)"
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$initdir/etc/resolv.conf"   # no resolved in here
        /usr/bin/install -D -m 600 "$c/tailscaled.state" "$initdir/etc/remote-unlock/tailscaled.state"
    fi
    if [[ -r $c/wpa_supplicant.conf ]]; then
        /usr/bin/install -D -m 600 "$c/wpa_supplicant.conf" "$initdir/etc/remote-unlock/wpa_supplicant.conf"
    fi
    /usr/bin/install -D -m 600 "$c/ssh_host_ed25519_key" "$initdir/etc/ssh/ssh_host_ed25519_key"
    /usr/bin/install -D -m 700 -d "$initdir/root/.ssh"
    /usr/bin/install -m 600 "$c/authorized_keys" "$initdir/root/.ssh/authorized_keys"
    if [[ -r $c/sshd_config ]]; then inst_simple "$c/sshd_config" /etc/ssh/sshd_config
    else inst_simple "$moddir/sshd_config" /etc/ssh/sshd_config; fi
    inst_script "$moddir/remote-unlock-wifi" /usr/bin/remote-unlock-wifi
    inst_script "$moddir/unlock-prompt" /usr/bin/unlock-prompt
    local u; for u in remote-unlock-wifi remote-unlock-tailscale remote-unlock-sshd remote-unlock-netclean; do
        inst_simple "$moddir/$u.service" "$systemdsystemunitdir/$u.service"
    done

    # Arch builds sshd with privsep user nobody and chroot /usr/share/empty.sshd: without it sshd exits 255 at once
    # ("Missing privilege separation directory", surfboard's first boot 2026-10-31; /var/empty is upstream's).
    grep -q '^nobody:' "$initdir/etc/passwd" 2>/dev/null || grep '^nobody:' /etc/passwd >> "$initdir/etc/passwd"
    grep -q '^nobody:' "$initdir/etc/group" 2>/dev/null || grep '^nobody:' /etc/group >> "$initdir/etc/group"
    mkdir -p -m 0755 "$initdir/usr/share/empty.sshd" "$initdir/var/empty" "$initdir/var/log"
    # sshd (UsePAM no) refuses a locked account, and systemd-sysusers (78systemd-sysusers, before this module) writes root
    # as "!unprovisioned": "User root not allowed because account is locked" (a cloud box's first unlock, 2026-11-06).
    # "*": no password works, and the key's forced command is still all root can run.
    if grep -q '^root:' "$initdir/etc/shadow" 2>/dev/null; then sed -i 's/^root:[^:]*:/root:*:/' "$initdir/etc/shadow"
    else echo 'root:*:::::::' >> "$initdir/etc/shadow"; chmod 600 "$initdir/etc/shadow"; fi

    $SYSTEMCTL -q --root "$initdir" enable remote-unlock-sshd.service remote-unlock-netclean.service
    [[ $ts ]] && $SYSTEMCTL -q --root "$initdir" enable remote-unlock-tailscale.service
    if [[ -r $c/wpa_supplicant.conf ]]; then
        $SYSTEMCTL -q --root "$initdir" enable remote-unlock-wifi.service
    fi
    return 0
}
