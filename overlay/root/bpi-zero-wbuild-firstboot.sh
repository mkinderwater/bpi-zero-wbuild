#!/bin/bash
set -euo pipefail

LOG=/var/log/bpi-zero-wbuild-firstboot.log
PKG_LOG=/var/log/bpi-zero-wbuild-packages.log
MARKER=/var/lib/bpi-zero-wbuild-firstboot.done
READY_MARKER=/var/lib/bpi-zero-wbuild-ready-to-finalize.done
RESIZE_MARKER=/var/lib/bpi-zero-wbuild-resize.done
CFG_MNT=/mnt/bpi-zero-wbuild-config
CFG_DEV=/dev/disk/by-label/BPIWBUILD
WIFI_IF=wlan0
PACKAGES=(
  /root/readline-common_8.2-6_all.deb
  /root/libreadline8t64_8.2-6_armhf.deb
  /root/libell0_0.77-1_armhf.deb
  /root/wireless-regdb_2026.05.30-1~deb13u1_all.deb
  /root/iwd_3.8-2_armhf.deb
)

mkdir -p /var/lib
exec > >(tee -a "$LOG") 2>&1

stage() { echo; echo "[BPI-ZERO-WBUILD] $*"; }
note() { echo "$*"; }

write_status() {
    printf 'FIRSTBOOT=%s\nWIFI=%s\nIPV4=%s\n' "$1" "${2:-pending}" "${3:-NONE}" \
        >/var/lib/bpi-zero-wbuild-status
}

fail() {
    echo "ERROR: $*"
    write_status failed unknown NONE
    printf 'ERROR=%s\n' "$*" >>/var/lib/bpi-zero-wbuild-status
    exit 1
}

ipv4_for_wlan0() {
    SYSTEMD_COLORS=0 networkctl status wlan0 --no-pager 2>/dev/null | awk '
        /Address:/ {
            for (i=2; i<=NF; i++) {
                candidate=$i
                sub(/\/[0-9]+$/, "", candidate)
                if (candidate ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                    print candidate; exit
                }
            }
        }' || true
}

start_ssh() {
    systemctl is-active --quiet ssh.service 2>/dev/null && return 0
    systemctl start ssh.service || fail "unable to start SSH."
    systemctl is-active --quiet ssh.service || fail "SSH did not become active."
}

mount_config() {
    local mode="$1"
    mkdir -p "$CFG_MNT"
    udevadm settle --timeout=10 2>/dev/null || true
    [ -b "$CFG_DEV" ] || fail "BPIWBUILD partition is not available at $CFG_DEV."
    mount -t vfat -o "$mode" "$CFG_DEV" "$CFG_MNT" || fail "unable to mount BPIWBUILD ($mode)."
}

cleanup_config_mount() {
    mountpoint -q "$CFG_MNT" && umount "$CFG_MNT" || true
}
trap cleanup_config_mount EXIT

scrub_config_secrets() {
    local config tmp rc
    cleanup_config_mount
    mount_config "rw,sync,umask=0077"
    config="$CFG_MNT/CONFIG.TXT"

    # A power loss may leave a previous temporary replacement behind. It is
    # never authoritative; remove it before evaluating the durable CONFIG.TXT.
    rm -f -- "$CFG_MNT"/.CONFIG.TXT.scrub.* 2>/dev/null || true

    # Once ready-to-finalize is committed, a missing CONFIG.TXT or a file with
    # neither credential key is already safe from plaintext credential reuse.
    # Do not wedge an otherwise-complete system because the FAT update was
    # interrupted or an operator removed the file after provisioning.
    if [ ! -f "$config" ]; then
        sync
        cleanup_config_mount
        note "CONFIG.TXT absent during finalization; treating credentials as already scrubbed."
        return 0
    fi
    if ! grep -Eq '^(PSK|ROOT_PASSWORD)=' "$config"; then
        sync
        cleanup_config_mount
        note "CONFIG.TXT contains no credential keys; treating credentials as already scrubbed."
        return 0
    fi

    tmp="$CFG_MNT/.CONFIG.TXT.scrub.$$"
    rc=0
    if (
        umask 077
        awk '
            /^PSK=/ { print "PSK="; next }
            /^ROOT_PASSWORD=/ { print "ROOT_PASSWORD="; next }
            { print }
        ' "$config" >"$tmp"
    ); then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        cleanup_config_mount
        fail "unable to rewrite CONFIG.TXT for credential scrub (awk rc=$rc)."
    fi
    sync
    mv -f "$tmp" "$config" || { rm -f "$tmp"; cleanup_config_mount; fail "unable to replace CONFIG.TXT during credential scrub."; }
    sync
    if grep -Eq '^PSK=.+|^ROOT_PASSWORD=.+' "$config"; then
        cleanup_config_mount
        fail "credential scrub verification found a nonblank PSK or ROOT_PASSWORD."
    fi
    cleanup_config_mount
    note "CONFIG.TXT credentials scrubbed: PSK and ROOT_PASSWORD are blank or absent."
}

attempt_root_resize() {
    local root_dev partnum pkname disk total_sectors root_basename part_start kernel_before expected_sectors
    local kernel_after before_root after_root attempt
    [ -e "$RESIZE_MARKER" ] && return 0

    root_dev="$(readlink -f "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
    [ -n "$root_dev" ] || { note "WARNING: resize deferred: unable to determine root device."; return 1; }
    partnum="$(lsblk -no PARTN "$root_dev" 2>/dev/null | tr -d '[:space:]')"
    pkname="$(lsblk -no PKNAME "$root_dev" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$partnum" ] && [ -n "$pkname" ] || { note "WARNING: resize deferred: root partition geometry unavailable."; return 1; }
    disk="/dev/$pkname"
    total_sectors="$(blockdev --getsz "$disk" 2>/dev/null || true)"
    root_basename="$(basename "$root_dev")"
    part_start="$(cat "/sys/class/block/$root_basename/start" 2>/dev/null || true)"
    kernel_before="$(blockdev --getsz "$root_dev" 2>/dev/null || true)"
    printf '%s' "$total_sectors" | grep -Eq '^[0-9]+$' || { note "WARNING: resize deferred: invalid disk geometry."; return 1; }
    printf '%s' "$part_start" | grep -Eq '^[0-9]+$' || { note "WARNING: resize deferred: invalid partition geometry."; return 1; }
    expected_sectors=$((total_sectors - part_start))
    [ "$expected_sectors" -gt 0 ] || { note "WARNING: resize deferred: invalid expected root size."; return 1; }

    if ! timeout 20s perl - "$disk" "$partnum" "$total_sectors" <<'PERL'
use strict;
use warnings;
my ($disk, $part, $total) = @ARGV;
die "bad partition number\n" unless defined($part) && $part =~ /^[1-4]$/;
die "bad disk sector count\n" unless defined($total) && $total =~ /^\d+$/ && $total > 0;
open(my $fh, '+<', $disk) or die "open $disk: $!\n";
binmode($fh);
seek($fh, 510, 0) or die "seek signature: $!\n";
read($fh, my $sig, 2) == 2 or die "read signature: $!\n";
die "bad MBR signature\n" unless $sig eq "\x55\xAA";
my $off = 446 + 16 * ($part - 1);
seek($fh, $off + 8, 0) or die "seek partition: $!\n";
read($fh, my $raw, 8) == 8 or die "read partition: $!\n";
my ($start, $old) = unpack('VV', $raw);
my $new = $total - $start;
die "invalid expanded partition size\n" if $new <= 0 || $new > 0xFFFFFFFF;
if ($new != $old) {
    seek($fh, $off + 12, 0) or die "seek size field: $!\n";
    print $fh pack('V', $new) or die "write size field: $!\n";
}
close($fh) or die "close $disk: $!\n";
PERL
    then
        note "WARNING: root partition expansion failed; provisioning will continue and retry next boot."
        return 1
    fi

    sync
    if ! timeout --signal=TERM --kill-after=5s 30s partx --update --nr "$partnum" "$disk"; then
        note "WARNING: kernel partition-table refresh failed; provisioning will continue and retry next boot."
        return 1
    fi
    udevadm settle --timeout=5 2>/dev/null || true
    kernel_after=""
    for attempt in $(seq 1 10); do
        kernel_after="$(blockdev --getsz "$root_dev" 2>/dev/null || true)"
        [ "$kernel_after" = "$expected_sectors" ] && break
        sleep 1
    done
    if [ "$kernel_after" != "$expected_sectors" ]; then
        note "WARNING: expanded partition is not visible yet; provisioning will continue and retry next boot."
        return 1
    fi

    before_root="$(df -h / | awk 'NR==2 {print $2}')"
    if ! timeout --signal=TERM --kill-after=10s 180s resize2fs "$root_dev"; then
        note "WARNING: online resize2fs failed; Wi-Fi/SSH provisioning will continue and resize will retry next boot."
        return 1
    fi
    after_root="$(df -h / | awk 'NR==2 {print $2}')"
    touch "$RESIZE_MARKER"
    sync
    note "Root filesystem: ${before_root:-unknown} -> ${after_root:-unknown}"
    return 0
}

cleanup_packages() {
    rm -f "${PACKAGES[@]}" || note "WARNING: unable to remove all staged package archives."
}

finish_provisioning() {
    local ip mac
    # Keep headless recovery available even if a later finalization step fails.
    start_ssh
    cleanup_packages
    scrub_config_secrets
    ip="$(ipv4_for_wlan0)"
    mac="$(cat /sys/class/net/wlan0/address 2>/dev/null || true)"
    mkdir -p /etc/issue.d
    printf 'Wi-Fi: wlan0  MAC: %s  IPv4: \\4{wlan0}\n' "${mac:-unavailable}" \
        >/etc/issue.d/90-bpi-zero-network.issue
    touch "$MARKER"
    rm -f "$READY_MARKER"
    write_status complete connected "${ip:-NONE}"
    sync
    if [ -e "$RESIZE_MARKER" ]; then
        systemctl disable bpi-zero-wbuild-firstboot.service >/dev/null 2>&1 || \
            fail "provisioning complete but unable to disable firstboot service."
    else
        note "Root resize remains deferred; firstboot will retry it on the next boot."
    fi
    printf 'Wi-Fi: wlan0  MAC: %s  IPv4: %s\n' "${mac:-unavailable}" "${ip:-NONE}" \
        >/dev/tty1 2>/dev/null || true
    note "Provisioning complete."
}

write_status running pending NONE
stage "01 FIRSTBOOT"
date -Is 2>/dev/null || date

# Completed provisioning only returns here to retry a deferred root resize.
if [ -e "$MARKER" ]; then
    if [ ! -e "$RESIZE_MARKER" ]; then
        stage "02 RETRY ROOT RESIZE"
        attempt_root_resize || { note "Root resize remains deferred."; exit 0; }
    fi
    systemctl disable bpi-zero-wbuild-firstboot.service >/dev/null 2>&1 || \
        fail "unable to disable completed firstboot service."
    exit 0
fi

# All substantive provisioning completed before the previous boot stopped.
if [ -e "$READY_MARKER" ]; then
    stage "02 FINALIZE INTERRUPTED FIRSTBOOT"
    finish_provisioning
    exit 0
fi

stage "02 ROOT FILESYSTEM CAPACITY"
# Storage preparation is independent of credentials. Always attempt it before
# validating CONFIG.TXT so a configuration mistake cannot leave the card at
# the seed-image size. Failure remains non-fatal and is retried on later boots.
attempt_root_resize || true

stage "03 CONFIG + ROOT LOGIN"
mount_config ro
CONFIG="$CFG_MNT/CONFIG.TXT"
[ -f "$CONFIG" ] || fail "CONFIG.TXT not found on BPIWBUILD partition."
config_value() { grep -E "^${1}=" "$CONFIG" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
SSID="$(config_value SSID | tr -d '\r')"
PSK="$(config_value PSK | tr -d '\r')"
COUNTRY="$(config_value COUNTRY | tr -d '\r' | tr '[:lower:]' '[:upper:]')"
HIDDEN="$(config_value HIDDEN | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
TIMEZONE="$(config_value TIMEZONE | tr -d '\r')"
ROOT_PASSWORD="$(config_value ROOT_PASSWORD | tr -d '\r')"
cleanup_config_mount

ROOT_PASSWORD_LEN=${#ROOT_PASSWORD}
[ "$ROOT_PASSWORD_LEN" -ge 8 ] && [ "$ROOT_PASSWORD_LEN" -le 64 ] || \
    fail "ROOT_PASSWORD must be 8-64 characters (got $ROOT_PASSWORD_LEN)."
printf '%s' "$ROOT_PASSWORD" | grep -q ':' && fail "ROOT_PASSWORD cannot contain a colon."
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd || fail "unable to set root password."
unset ROOT_PASSWORD ROOT_PASSWORD_LEN
ROOT_HASH="$(awk -F: '$1 == "root" {print $2}' /etc/shadow)"
case "$ROOT_HASH" in ''|'!'*|'*'*) fail "root account remained locked after password update." ;; esac
unset ROOT_HASH

SSID="$(printf '%s' "$SSID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
COUNTRY="$(printf '%s' "$COUNTRY" | tr -d '[:space:]')"
HIDDEN="$(printf '%s' "$HIDDEN" | tr -d '[:space:]')"
TIMEZONE="$(printf '%s' "$TIMEZONE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$SSID" ] || fail "SSID is empty in CONFIG.TXT."
[ ${#PSK} -ge 8 ] && [ ${#PSK} -le 63 ] || fail "PSK must be 8-63 characters."
printf '%s' "$COUNTRY" | grep -Eq '^[A-Z]{2}$' || fail "COUNTRY must be a two-letter code such as CA."
case "$HIDDEN" in true|false) ;; *) HIDDEN=false ;; esac
[ -n "$TIMEZONE" ] || TIMEZONE=America/Edmonton

mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/20-bpi-zero-root.conf <<'EOF_SSH'
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no

Match User root
    PasswordAuthentication yes
EOF_SSH
chmod 600 /etc/ssh/sshd_config.d/20-bpi-zero-root.conf
ssh-keygen -A || fail "unable to generate SSH host keys."
sshd -t || fail "generated SSH configuration is invalid."
systemctl enable ssh.service >/dev/null 2>&1 || fail "unable to enable SSH."

stage "04 DEVICE IDENTITY + TIME"
systemd-machine-id-setup
MACHINE_ID="$(tr -d '[:space:]' </etc/machine-id)"
[ ${#MACHINE_ID} -ge 6 ] || fail "machine-id generation failed."
CURRENT_HOST="bpi-zero-${MACHINE_ID:0:6}"
printf '%s\n' "$CURRENT_HOST" >/etc/hostname
hostnamectl set-hostname "$CURRENT_HOST" || true
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1\t$CURRENT_HOST/" /etc/hosts
else
    printf '127.0.1.1\t%s\n' "$CURRENT_HOST" >>/etc/hosts
fi
if timedatectl list-timezones 2>/dev/null | grep -qxF "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE" || true
else
    timedatectl set-timezone America/Edmonton || true
fi
timedatectl set-ntp true || true

stage "05 INSTALL WIFI USERSPACE"
for package in "${PACKAGES[@]}"; do [ -f "$package" ] || fail "package missing: $package"; done
for reg in /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s; do
    [ ! -e "$reg" ] || [ -L "$reg" ] || rm -f "$reg"
done
: >"$PKG_LOG"
timeout --signal=TERM --kill-after=10s 300s env DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true dpkg --unpack "${PACKAGES[@]}" >>"$PKG_LOG" 2>&1 || {
    tail -80 "$PKG_LOG" || true; fail "runtime package unpack failed."; }
timeout --signal=TERM --kill-after=10s 300s env DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true dpkg --configure -a >>"$PKG_LOG" 2>&1 || {
    tail -80 "$PKG_LOG" || true; fail "runtime package configuration failed."; }

stage "06 WIFI + DHCP"
mkdir -p /etc/iwd /var/lib/iwd /etc/systemd/network
printf '[General]\nCountry=%s\n' "$COUNTRY" >/etc/iwd/main.conf
if printf '%s' "$SSID" | grep -Eq '^[A-Za-z0-9 _-]+$'; then
    IWD_NAME="${SSID}.psk"
else
    IWD_NAME="=$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n').psk"
fi
PROFILE="/var/lib/iwd/$IWD_NAME"
install -m 0600 /dev/null "$PROFILE"
IWD_PSK="${PSK//\\/\\\\}"
{
    echo '[Security]'
    printf 'Passphrase=%s\n' "$IWD_PSK"
    echo
    echo '[Settings]'
    echo 'AutoConnect=true'
    printf 'Hidden=%s\n' "$HIDDEN"
} >"$PROFILE"
cat >/etc/systemd/network/25-wlan0.network <<'EOF_NET'
[Match]
Name=wlan0

[Network]
DHCP=ipv4
IPv6AcceptRA=no
EOF_NET
systemctl enable iwd.service systemd-networkd.service systemd-resolved.service >/dev/null
systemctl restart systemd-resolved.service || fail "unable to start systemd-resolved."
systemctl restart iwd.service || fail "unable to start iwd."
systemctl restart systemd-networkd.service || fail "unable to start systemd-networkd."
[ -e /run/systemd/resolve/stub-resolv.conf ] || fail "systemd-resolved did not provide stub-resolv.conf."
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

IPV4_ADDR=""
for _ in $(seq 1 90); do
    IPV4_ADDR="$(ipv4_for_wlan0)"
    [ -n "$IPV4_ADDR" ] && break
    sleep 1
done
if [ -z "$IPV4_ADDR" ]; then
    SYSTEMD_COLORS=0 networkctl status wlan0 --no-pager || true
    iwctl station wlan0 show || true
    journalctl -b -u iwd --no-pager -n 80 || true
    dmesg | grep -Ei 'brcmfmac|brcm|firmware|mmc|sdio' | tail -n 120 || true
    fail "wlan0 did not receive an IPv4 DHCP address within 90 seconds."
fi
WIFI_MAC="$(cat /sys/class/net/wlan0/address 2>/dev/null || true)"
[ -n "$WIFI_MAC" ] || fail "wlan0 MAC address is unavailable."
write_status running connected "$IPV4_ADDR"
note "Wi-Fi: wlan0  MAC: $WIFI_MAC  IPv4: $IPV4_ADDR"

# DHCP is confirmed. Bring up remote administration before credential scrub or
# any other finalization work so a non-network finalization fault cannot leave
# an otherwise reachable headless board without SSH.
start_ssh
note "SSH ready: $IPV4_ADDR"

stage "07 FINALIZE"
printf '%s\n' 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
touch "$READY_MARKER"
sync
finish_provisioning
exit 0
