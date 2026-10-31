#!/bin/bash
# wifi-unlock (station-maintenance surfboard 04): the initramfs joins Wi-Fi and runs sshd, so micro can answer the LUKS
# passphrase prompt with the laptop closed (`tools/unlock` on micro). surfboard has no Ethernet. Installed by
# arch-bootstrap (setup_wifi_unlock) with its inputs in /etc/wifi-unlock (root 0600):
#   wpa_supplicant.conf  the home network, psk only    net.conf  IFADDR=<addr/prefix>
#   authorized_keys      micro's key, forced command   ssh_host_ed25519_key  this initramfs's own host key
# All four end up in the image on the unencrypted /boot: the Wi-Fi psk and that host key are readable to anyone with the
# disk (Ben accepted the psk in the clear on the rescue stick, 2026-10-06). Nothing unlocks without the passphrase.

check() {
    require_binaries wpa_supplicant ip sshd systemd-tty-ask-password-agent || return 1
    return 255   # only when asked for (add_dracutmodules)
}

depends() {
    echo systemd systemd-ask-password
}

install() {
    local c=${WIFI_UNLOCK_DIR:-/etc/wifi-unlock}   # the override is for building a test image as a user
    local f; for f in wpa_supplicant.conf net.conf authorized_keys ssh_host_ed25519_key; do
        [[ -r $c/$f ]] || { dfatal "wifi-unlock: $c/$f missing"; return 1; }
    done
    # The Wi-Fi driver and what WPA2 needs, whatever hostonly would have left out.
    hostonly='' instmods iwlwifi iwlmvm cfg80211 mac80211 ccm gcm ctr cmac
    inst_multiple -o /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s
    inst_multiple wpa_supplicant ip sleep seq ls cat kill sshd systemd-tty-ask-password-agent
    inst_multiple -o /usr/lib/ssh/sshd-session /usr/lib/ssh/sshd-auth

    /usr/bin/install -D -m 600 $c/wpa_supplicant.conf "$initdir/etc/wifi-unlock/wpa_supplicant.conf"
    inst_simple $c/net.conf /etc/wifi-unlock/net.conf
    /usr/bin/install -D -m 600 $c/ssh_host_ed25519_key "$initdir/etc/ssh/ssh_host_ed25519_key"
    /usr/bin/install -D -m 700 -d "$initdir/root/.ssh"
    /usr/bin/install -m 600 $c/authorized_keys "$initdir/root/.ssh/authorized_keys"
    inst_simple "$moddir/sshd_config" /etc/ssh/sshd_config
    inst_script "$moddir/wifi-unlock-net" /usr/bin/wifi-unlock-net
    inst_script "$moddir/unlock-prompt" /usr/bin/unlock-prompt
    inst_simple "$moddir/wifi-unlock.service" "$systemdsystemunitdir/wifi-unlock.service"
    inst_simple "$moddir/wifi-unlock-sshd.service" "$systemdsystemunitdir/wifi-unlock-sshd.service"

    # Arch builds sshd with privsep user nobody; /var/empty is its chroot.
    grep -q '^nobody:' "$initdir/etc/passwd" 2>/dev/null || grep '^nobody:' /etc/passwd >> "$initdir/etc/passwd"
    grep -q '^nobody:' "$initdir/etc/group" 2>/dev/null || grep '^nobody:' /etc/group >> "$initdir/etc/group"
    mkdir -p -m 0755 "$initdir/var/empty" "$initdir/var/log"

    $SYSTEMCTL -q --root "$initdir" enable wifi-unlock.service wifi-unlock-sshd.service
}
