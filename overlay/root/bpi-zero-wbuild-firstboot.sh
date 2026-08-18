#!/bin/bash
set -euo pipefail

LOG=/var/log/bpi-zero-wbuild-firstboot.log
PKG_LOG=/var/log/bpi-zero-wbuild-packages.log
MARKER=/var/lib/bpi-zero-wbuild-firstboot.done
STATE_DIR=/var/lib/bpi-zero-wbuild-firstboot
RESIZE_MARKER=/var/lib/bpi-zero-wbuild-resize.done
IDENTITY_MARKER="$STATE_DIR/identity.done"
SSH_MARKER="$STATE_DIR/ssh.done"
FIRMWARE_MARKER="$STATE_DIR/firmware.done"
PACKAGES_MARKER="$STATE_DIR/packages.done"
IWD_PROFILE_STATE="$STATE_DIR/iwd-profile"

mkdir -p "$STATE_DIR"
touch "$LOG"
exec >>"$LOG" 2>&1

console_line() {
    # Stage-level appliance progress belongs on the physical console. Full
    # command/package chatter remains in the persistent firstboot/package logs.
    printf '%s\n' "$*" 2>/dev/null >/dev/console || true
}

stage() {
    echo
    echo "[BPI-ZERO-WBUILD] $*"
    console_line "[BPI-ZERO-WBUILD] $*"
}

note() {
    echo "$*"
    console_line "  $*"
}

fail() {
    echo "ERROR: $*"
    console_line "  ERROR: $*"
    exit 1
}

cleanup_completed_state() {
    # Once the final completion marker exists, intermediate resume checkpoints
    # are dead state. Keep the final marker and logs for provenance.
    rm -rf "$STATE_DIR"
    rm -f "$RESIZE_MARKER"
}

stage "01 FIRSTBOOT SERVICE STARTED"
date -Is 2>/dev/null || date
echo "Clock may be unsynchronized until networking is available."

if [ -e "$MARKER" ]; then
    # A completed marker is authoritative. If power was lost between marker
    # commit and service disable, finish that harmless cleanup on this boot.
    systemctl disable bpi-zero-wbuild-firstboot.service >/dev/null 2>&1 || \
        fail "provisioning is complete but firstboot service could not be disabled."
    cleanup_completed_state
    note "Provisioning already complete; firstboot service disabled; intermediate checkpoints removed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Root partition/filesystem growth. Once verified, never repeat it merely
# because a later network stage failed.
# ---------------------------------------------------------------------------
stage "02 ROOT FILESYSTEM CAPACITY"
if [ -e "$RESIZE_MARKER" ]; then
    note "Root resize already complete; checkpoint reused."
    df -h /
else
    ROOT_DEV="$(readlink -f "$(findmnt -n -o SOURCE /)")"
    PARTNUM="$(lsblk -no PARTN "$ROOT_DEV" | tr -d '[:space:]')"
    PKNAME="$(lsblk -no PKNAME "$ROOT_DEV" | tr -d '[:space:]')"

    [ -n "$ROOT_DEV" ] || fail "unable to determine root device."
    [ -n "$PARTNUM" ] || fail "unable to determine root partition number for $ROOT_DEV."
    [ -n "$PKNAME" ] || fail "unable to determine parent disk for $ROOT_DEV."
    command -v partx >/dev/null 2>&1 || fail "partx is unavailable."
    command -v resize2fs >/dev/null 2>&1 || fail "resize2fs is unavailable."

    DISK="/dev/$PKNAME"
    TOTAL_SECTORS="$(blockdev --getsz "$DISK")"
    ROOT_BASENAME="$(basename "$ROOT_DEV")"
    PART_START="$(cat "/sys/class/block/$ROOT_BASENAME/start")"
    KERNEL_BEFORE="$(blockdev --getsz "$ROOT_DEV")"

    printf '%s' "$TOTAL_SECTORS" | grep -Eq '^[0-9]+$' || fail "invalid disk sector geometry."
    printf '%s' "$PART_START" | grep -Eq '^[0-9]+$' || fail "invalid partition start geometry."
    EXPECTED_SECTORS=$((TOTAL_SECTORS - PART_START))
    [ "$EXPECTED_SECTORS" -gt 0 ] || fail "invalid expected root partition size."

    cat <<EOF_GEOMETRY
Root partition:        $ROOT_DEV
Parent disk:           $DISK
Partition no.:         $PARTNUM
Partition start:       $PART_START
Disk sectors:          $TOTAL_SECTORS
Kernel sectors before: $KERNEL_BEFORE
Expected root sectors: $EXPECTED_SECTORS
EOF_GEOMETRY

    timeout 20s perl - "$DISK" "$PARTNUM" "$TOTAL_SECTORS" <<'PERL'
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
print "Partition start=$start old_size=$old new_size=$new\n";
if ($new != $old) {
    seek($fh, $off + 12, 0) or die "seek size field: $!\n";
    print $fh pack('V', $new) or die "write size field: $!\n";
}
close($fh) or die "close $disk: $!\n";
open(my $verify, '<', $disk) or die "reopen $disk: $!\n";
binmode($verify);
seek($verify, $off + 8, 0) or die "verify seek: $!\n";
read($verify, my $check, 8) == 8 or die "verify read: $!\n";
my ($vstart, $vsize) = unpack('VV', $check);
close($verify);
die "partition verification failed\n" unless $vstart == $start && $vsize == $new;
print "Verified partition start=$vstart size=$vsize\n";
PERL

    sync
    stage "03 UPDATING LIVE ROOT PARTITION SIZE"
    partx --update --nr "$PARTNUM" "$DISK"
    udevadm settle --timeout=5 2>/dev/null || true

    KERNEL_UPDATED=0
    KERNEL_AFTER=""
    for attempt in $(seq 1 10); do
        KERNEL_AFTER="$(blockdev --getsz "$ROOT_DEV" 2>/dev/null || true)"
        if [ "$KERNEL_AFTER" = "$EXPECTED_SECTORS" ]; then
            KERNEL_UPDATED=1
            break
        fi
        sleep 1
    done
    echo "Kernel sectors after:  ${KERNEL_AFTER:-unknown}"
    if [ "$KERNEL_UPDATED" -ne 1 ]; then
        fail "kernel did not expose expanded partition size (expected $EXPECTED_SECTORS, observed ${KERNEL_AFTER:-unknown})."
    fi

    stage "04 GROWING ROOT FILESYSTEM ONLINE"
    BEFORE_ROOT="$(df -h / | awk 'NR==2 {print $2}')"
    echo "Before:"
    df -h /
    if ! resize2fs "$ROOT_DEV"; then
        echo "This image does not attempt filesystem repair on the target."
        fail "online root filesystem expansion failed."
    fi
    echo "After:"
    df -h /
    AFTER_ROOT="$(df -h / | awk 'NR==2 {print $2}')"
    touch "$RESIZE_MARKER"
    sync
    note "Root filesystem: ${BEFORE_ROOT:-unknown} -> ${AFTER_ROOT:-unknown}"
fi

# ---------------------------------------------------------------------------
# Stable appliance identity. If a prior attempt already wrote a valid random
# hostname, reuse it even if the identity checkpoint itself was not reached.
# ---------------------------------------------------------------------------
stage "05 DEVICE IDENTITY + ACCOUNTS"
CURRENT_HOST="$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]' || true)"
if printf '%s' "$CURRENT_HOST" | grep -Eq '^bpi-zero-wbuild-[0-9a-z]{3}$'; then
    HOSTNAME_NEW="$CURRENT_HOST"
else
    HOST_ALPHABET='0123456789abcdefghijklmnopqrstuvwxyz'
    HOST_RANDOM="$(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]')"
    [ -n "$HOST_RANDOM" ] || fail "unable to generate hostname suffix."
    HOST_RANDOM=$((HOST_RANDOM % 46656))
    HOST_SUFFIX="${HOST_ALPHABET:$((HOST_RANDOM / 1296)):1}${HOST_ALPHABET:$(((HOST_RANDOM / 36) % 36)):1}${HOST_ALPHABET:$((HOST_RANDOM % 36)):1}"
    HOSTNAME_NEW="bpi-zero-wbuild-$HOST_SUFFIX"
    printf '%s\n' "$HOSTNAME_NEW" >/etc/hostname
    sync
fi

hostnamectl set-hostname "$HOSTNAME_NEW" || true
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts
else
    printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >>/etc/hosts
fi

if [ ! -e "$IDENTITY_MARKER" ]; then
    echo 'root:bpi-zero-wbuild' | chpasswd
    if ! id bpi-zero-wbuild >/dev/null 2>&1; then
        useradd -m -s /bin/bash bpi-zero-wbuild
    fi
    echo 'bpi-zero-wbuild:bpi-zero-wbuild' | chpasswd
    touch "$IDENTITY_MARKER"
    sync
else
    echo "Identity/account checkpoint reused."
fi
note "Hostname: $HOSTNAME_NEW"
timedatectl set-ntp true || true

stage "06 SSH HOST KEYS"
if [ -e "$SSH_MARKER" ]; then
    note "SSH host-key checkpoint reused."
else
    ssh-keygen -A
    touch "$SSH_MARKER"
    sync
    note "SSH host keys ready."
fi

stage "07 REGULATORY + BCM43430 WIFI FIRMWARE"
ROOT_FW=/root/brcmfmac43430-sdio.bin
ROOT_FW_BOARD='/root/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin'
ROOT_CLM=/root/brcmfmac43430-sdio.clm_blob
ROOT_CLM_BOARD='/root/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob'
ROOT_NVRAM='/root/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt'
ROOT_REGDB=/root/regulatory.db
ROOT_REGSIG=/root/regulatory.db.p7s
FIRMWARE_STAGE=("$ROOT_FW" "$ROOT_FW_BOARD" "$ROOT_CLM" "$ROOT_CLM_BOARD" "$ROOT_NVRAM" "$ROOT_REGDB" "$ROOT_REGSIG")
cleanup_staged_firmware() {
    rm -f "${FIRMWARE_STAGE[@]}" || note "WARNING: unable to remove all staged firmware payloads."
}
if [ -e "$FIRMWARE_MARKER" ]; then
    cleanup_staged_firmware
    note "Wi-Fi firmware checkpoint reused; staged firmware cleanup verified."
else
    for fw in "${FIRMWARE_STAGE[@]}"; do
        [ -s "$fw" ] || fail "staged Wi-Fi firmware missing: $fw"
    done
    mkdir -p /usr/lib/firmware/brcm
    cp -f "$ROOT_REGDB" /usr/lib/firmware/regulatory.db
    cp -f "$ROOT_REGSIG" /usr/lib/firmware/regulatory.db.p7s
    cp -f "$ROOT_FW" /usr/lib/firmware/brcm/brcmfmac43430-sdio.bin
    cp -f "$ROOT_FW_BOARD" '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin'
    cp -f "$ROOT_CLM" /usr/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob
    cp -f "$ROOT_CLM_BOARD" '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob'
    cp -f "$ROOT_NVRAM" '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt'
    chmod 644 /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s \
      /usr/lib/firmware/brcm/brcmfmac43430-sdio.bin \
      '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin' \
      /usr/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob \
      '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob' \
      '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt'
    modprobe -r brcmfmac 2>/dev/null || true
    modprobe -r brcmutil 2>/dev/null || true
    modprobe brcmfmac
    # Commit the checkpoint before removing installation payloads. If power is
    # lost during cleanup, the next firstboot retry safely finishes cleanup.
    touch "$FIRMWARE_MARKER"
    sync
    cleanup_staged_firmware
    sync
    note "BCM43430 firmware + board NVRAM ready; staged firmware removed."
fi

stage "08 RUNTIME USERSPACE + CLI TOOLS"
PACKAGES=(
  /root/readline-common_8.2-6_all.deb
  /root/libreadline8t64_8.2-6_armhf.deb
  /root/libell0_0.77-1_armhf.deb
  /root/wireless-regdb_2026.05.30-1~deb13u1_all.deb
  /root/iwd_3.8-2_armhf.deb
  /root/libelf1t64_0.192-4_armhf.deb
  /root/libbpf1_1.5.0-3_armhf.deb
  /root/libmnl0_1.0.5-3_armhf.deb
  /root/libdb5.3t64_5.3.28+dfsg2-9_armhf.deb
  /root/libtirpc-common_1.3.6+ds-1_all.deb
  /root/libtirpc3t64_1.3.6+ds-1_armhf.deb
  /root/libxtables12_1.8.11-2_armhf.deb
  /root/libcap2-bin_2.75-10+deb13u1+b1_armhf.deb
  /root/iproute2_6.15.0-1_armhf.deb
  /root/libnl-3-200_3.7.0-2_armhf.deb
  /root/libnl-genl-3-200_3.7.0-2_armhf.deb
  /root/iw_6.9-1_armhf.deb
  /root/libasound2-data_1.2.14-1_all.deb
  /root/libasound2t64_1.2.14-1_armhf.deb
  /root/libatopology2t64_1.2.14-1_armhf.deb
  /root/gcc-14-base_14.2.0-19_armhf.deb
  /root/libgomp1_14.2.0-19_armhf.deb
  /root/libfftw3-single3_3.3.10-2+b1_armhf.deb
  /root/libtinfo6_6.5+20250216-2_armhf.deb
  /root/libncursesw6_6.5+20250216-2_armhf.deb
  /root/libsamplerate0_0.2.2-4+b2_armhf.deb
  /root/alsa-utils_1.2.14-1_armhf.deb
)
cleanup_staged_packages() {
    rm -f "${PACKAGES[@]}" || note "WARNING: unable to remove all staged package archives."
}
if [ -e "$PACKAGES_MARKER" ]; then
    cleanup_staged_packages
    note "Package checkpoint reused (iwd + iproute2 + iw + alsa-utils); staged package cleanup verified."
else
    for package in "${PACKAGES[@]}"; do
        [ -f "$package" ] || fail "package missing: $package"
    done
    : >"$PKG_LOG"
    # Automated provisioning must never select debconf's interactive Readline
    # frontend. Keep this policy scoped to these dpkg commands only so later
    # manual administration retains Debian's normal debconf behavior.
    if ! DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
            dpkg --unpack "${PACKAGES[@]}" >>"$PKG_LOG" 2>&1; then
        echo "Package unpack failed; last 80 lines from $PKG_LOG:"
        tail -80 "$PKG_LOG" || true
        fail "runtime package unpack failed."
    fi
    if ! DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
            dpkg --configure -a >>"$PKG_LOG" 2>&1; then
        echo "Package configuration failed; last 80 lines from $PKG_LOG:"
        tail -80 "$PKG_LOG" || true
        fail "runtime package configuration failed."
    fi
    # alsa-utils is included for diagnostics only. Prevent Debian's automatic
    # state restore/save units from owning appliance audio state at boot. This
    # is required appliance policy, so masking and verification are fail-closed.
    if ! systemctl mask alsa-restore.service alsa-state.service alsa-utils.service >>"$PKG_LOG" 2>&1; then
        fail "unable to mask ALSA state restore/save services."
    fi
    for unit in alsa-restore.service alsa-state.service alsa-utils.service; do
        unit_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        [ "$unit_state" = "masked" ] || fail "$unit is not masked (state: ${unit_state:-unknown})."
    done
    command -v ip >/dev/null 2>&1 || fail "iproute2 installed but 'ip' is unavailable."
    command -v iw >/dev/null 2>&1 || fail "iw installed but the CLI tool is unavailable."
    command -v arecord >/dev/null 2>&1 || fail "alsa-utils installed but 'arecord' is unavailable."
    command -v aplay >/dev/null 2>&1 || fail "alsa-utils installed but 'aplay' is unavailable."
    # Commit the successful package state before removing the offline payload.
    # A power loss during cleanup therefore cannot strand firstboot without .debs.
    touch "$PACKAGES_MARKER"
    sync
    cleanup_staged_packages
    sync
    note "iwd + regulatory support + iproute2 + iw + alsa-utils ready; staged packages removed."
    echo "Detailed dpkg output: $PKG_LOG"
fi

stage "09 READING BPIWBUILD CONFIG"
modprobe vfat 2>/dev/null || true
CFG_MNT=/mnt/bpi-zero-wbuild-config
CFG_MOUNTED=0
mkdir -p "$CFG_MNT"
cleanup_config_mount() {
    if [ "$CFG_MOUNTED" -eq 1 ]; then
        umount "$CFG_MNT" 2>/dev/null || true
        CFG_MOUNTED=0
    fi
}
trap cleanup_config_mount EXIT
CFG_DEV=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    CFG_DEV="$(blkid -L BPIWBUILD 2>/dev/null || true)"
    [ -n "$CFG_DEV" ] && break
    udevadm settle --timeout=2 2>/dev/null || true
    sleep 1
done
[ -n "$CFG_DEV" ] || fail "could not find a partition labeled BPIWBUILD."
mount -t vfat -o ro "$CFG_DEV" "$CFG_MNT"
CFG_MOUNTED=1
CONFIG="$CFG_MNT/CONFIG.TXT"
[ -f "$CONFIG" ] || fail "CONFIG.TXT not found on BPIWBUILD partition."
config_value() {
    local key="$1"
    grep -E "^${key}=" "$CONFIG" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}
SSID="$(config_value SSID)"
PSK="$(config_value PSK)"
COUNTRY="$(config_value COUNTRY)"
HIDDEN="$(config_value HIDDEN)"
TIMEZONE="$(config_value TIMEZONE)"
cleanup_config_mount
trap - EXIT
trim() { printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
SSID="$(trim "$SSID")"
PSK="$(trim "$PSK")"
COUNTRY="$(trim "$COUNTRY" | tr '[:lower:]' '[:upper:]')"
HIDDEN="$(trim "$HIDDEN" | tr '[:upper:]' '[:lower:]')"
TIMEZONE="$(trim "$TIMEZONE")"
[ -n "$SSID" ] || fail "SSID is empty in CONFIG.TXT."
PSK_LEN=${#PSK}
[ "$PSK_LEN" -ge 8 ] && [ "$PSK_LEN" -le 63 ] || fail "PSK must be 8-63 characters (got $PSK_LEN)."
printf '%s' "$COUNTRY" | grep -Eq '^[A-Z]{2}$' || fail "COUNTRY must be a two-letter code such as CA, got '$COUNTRY'."
case "$HIDDEN" in true|false) ;; *) HIDDEN="false" ;; esac
[ -n "$TIMEZONE" ] || TIMEZONE="America/Edmonton"
note "Config: SSID='$SSID' country=$COUNTRY hidden=$HIDDEN timezone=$TIMEZONE"

stage "10 TIME ZONE"
if timedatectl list-timezones 2>/dev/null | grep -qxF "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE" || true
else
    echo "WARNING: invalid timezone '$TIMEZONE'; using America/Edmonton."
    timedatectl set-timezone "America/Edmonton" || true
fi
note "Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo "$TIMEZONE")"

stage "11 CONFIGURING WIFI + DHCP"
mkdir -p /etc/iwd /var/lib/iwd /etc/systemd/network
cat >/etc/iwd/main.conf <<EOF2
[General]
Country=$COUNTRY

[DriverQuirks]
PowerSaveDisable=brcmfmac
EOF2
note "Wi-Fi power-save policy: OFF for brcmfmac (persistent via iwd DriverQuirks)."
if printf '%s' "$SSID" | grep -Eq '^[A-Za-z0-9 _-]+$'; then
    IWD_NAME="${SSID}.psk"
else
    IWD_HEX="$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n')"
    IWD_NAME="=${IWD_HEX}.psk"
fi
PROFILE="/var/lib/iwd/$IWD_NAME"
# If a prior failed firstboot used a different SSID, remove only the profile
# that firstboot itself recorded as owned. Never sweep unrelated iwd profiles.
if [ -f "$IWD_PROFILE_STATE" ]; then
    OLD_IWD_NAME="$(tr -d '\r\n' <"$IWD_PROFILE_STATE")"
    case "$OLD_IWD_NAME" in
        ''|.|..|*/*) ;;
        *)
            if [ "$OLD_IWD_NAME" != "$IWD_NAME" ]; then
                rm -f "/var/lib/iwd/$OLD_IWD_NAME"
                note "Removed stale firstboot Wi-Fi profile '$OLD_IWD_NAME'."
            fi
            ;;
    esac
fi
{
    echo '[Security]'
    printf 'Passphrase=%s\n' "$PSK"
    echo
    echo '[Settings]'
    echo 'AutoConnect=true'
    printf 'Hidden=%s\n' "$HIDDEN"
} >"$PROFILE"
chmod 600 "$PROFILE"
printf '%s\n' "$IWD_NAME" >"$IWD_PROFILE_STATE"
cat >/etc/systemd/network/25-wlan0.network <<'EOF2'
[Match]
Name=wlan0

[Network]
DHCP=ipv4
IPv6AcceptRA=no
EOF2
systemctl daemon-reload
for unit in iwd.service systemd-networkd.service ssh.service; do
    systemctl enable "$unit" >/dev/null 2>&1 || fail "unable to enable $unit."
    unit_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    [ "$unit_state" = "enabled" ] || fail "$unit is not enabled (state: ${unit_state:-unknown})."
done
systemctl restart iwd.service
systemctl restart systemd-networkd.service
systemctl restart systemd-resolved.service || true
note "Wi-Fi services started; waiting for '$SSID'."

has_ipv4() {
    ip -4 -o addr show dev wlan0 scope global 2>/dev/null | grep -q 'inet '
}

show_ipv4() {
    ip -4 -br addr show wlan0 || true
    ip -4 route show default || true
}

wifi_power_save_state() {
    local state=""
    state="$(iw dev wlan0 get power_save 2>/dev/null || true)"
    if printf '%s' "$state" | grep -qi 'power save: off'; then
        printf '%s\n' "OFF"
    elif printf '%s' "$state" | grep -qi 'power save: on'; then
        printf '%s\n' "ON"
    elif [ -n "$state" ]; then
        printf '%s\n' "$state"
    else
        printf '%s\n' "UNKNOWN"
    fi
}

report_wifi_power_save() {
    local state
    state="$(wifi_power_save_state)"
    if [ "$state" = "OFF" ]; then
        note "Wi-Fi power save effective: OFF"
    else
        echo "WARNING: effective Wi-Fi power-save state is not OFF: $state"
        console_line "  WARNING: Wi-Fi power-save verification returned: $state"
    fi
}

ssid_visible_now() {
    local scan line found=1
    scan="$(timeout 12s iw dev wlan0 scan 2>/dev/null || true)"
    [ -n "$scan" ] || return 2
    while IFS= read -r line; do
        line="${line#${line%%[![:space:]]*}}"
        case "$line" in
            SSID:*)
                if [ "${line#SSID: }" = "$SSID" ] || [ "${line#SSID:}" = "$SSID" ]; then
                    found=0
                    break
                fi
                ;;
        esac
    done <<<"$scan"
    return "$found"
}

wifi_diag_snapshot() {
    local label="$1" driver="unknown" mac="unknown" link="" associated="NO"
    local bssid="-" signal="-" visible="UNKNOWN" power ipv4="NONE"

    if [ -e /sys/class/net/wlan0/device/driver ]; then
        driver="$(basename "$(readlink -f /sys/class/net/wlan0/device/driver)" 2>/dev/null || echo unknown)"
    fi
    [ -r /sys/class/net/wlan0/address ] && mac="$(cat /sys/class/net/wlan0/address)"

    link="$(iw dev wlan0 link 2>/dev/null || true)"
    if printf '%s\n' "$link" | grep -q '^Connected to '; then
        associated="YES"
        bssid="$(printf '%s\n' "$link" | awk '/^Connected to / {print $3; exit}')"
        signal="$(printf '%s\n' "$link" | awk '/^[[:space:]]*signal:/ {print $2 " " $3; exit}')"
        visible="YES"
    else
        if ssid_visible_now; then
            visible="YES"
        else
            case $? in
                1) visible="NO" ;;
                *) visible="UNKNOWN" ;;
            esac
        fi
    fi

    power="$(wifi_power_save_state)"
    ipv4="$(ip -4 -o addr show dev wlan0 scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)"
    [ -n "$ipv4" ] || ipv4="NONE"

    echo "Wi-Fi state ($label):"
    echo "  Interface:       wlan0"
    echo "  Driver:          $driver"
    echo "  MAC:             $mac"
    echo "  SSID configured: $SSID"
    echo "  SSID visible:    $visible"
    echo "  Associated:      $associated"
    [ "$associated" = "YES" ] && echo "  BSSID:           $bssid"
    [ "$associated" = "YES" ] && echo "  Signal:          $signal"
    echo "  Power save:      $power"
    echo "  IPv4:            $ipv4"

    console_line "  Wi-Fi: visible=$visible associated=$associated power_save=$power ipv4=$ipv4"
}

wait_ipv4() {
    local seconds="$1"
    local attempt
    for attempt in $(seq 1 "$seconds"); do
        if has_ipv4; then
            return 0
        fi
        sleep 1
    done
    return 1
}

stage "12 VERIFYING WIFI + IPV4 (ATTEMPT 1/2)"
DHCP_OK=0
if wait_ipv4 60; then
    DHCP_OK=1
    wifi_diag_snapshot "attempt 1 success"
else
    wifi_diag_snapshot "attempt 1 failed"
    stage "13 WIFI RECOVERY RETRY"
    note "No IPv4 after 60 seconds; restarting radio/userspace once."
    systemctl stop iwd.service || true
    modprobe -r brcmfmac 2>/dev/null || true
    modprobe -r brcmutil 2>/dev/null || true
    modprobe brcmfmac || true
    sleep 2
    systemctl restart systemd-networkd.service || true
    systemctl restart iwd.service || true
    systemctl restart systemd-resolved.service || true
    stage "14 VERIFYING WIFI + IPV4 (ATTEMPT 2/2)"
    if wait_ipv4 60; then
        DHCP_OK=1
        wifi_diag_snapshot "attempt 2 success"
    else
        wifi_diag_snapshot "attempt 2 failed"
    fi
fi

if [ "$DHCP_OK" -ne 1 ]; then
    echo "ERROR: wlan0 did not receive an IPv4 DHCP address after two attempts."
    echo "Useful diagnostics:"
    echo "  ip -br addr"
    echo "  ip route"
    echo "  networkctl status wlan0 --no-pager"
    echo "  journalctl -b -u iwd --no-pager"
    echo "  journalctl -b -u systemd-networkd --no-pager"
    echo "  dmesg | grep -Ei 'brcmfmac|firmware|mmc|sdio'"
    console_line "  Wi-Fi failed after one automatic recovery retry; see $LOG"
    exit 1
fi

show_ipv4
report_wifi_power_save
IPV4_ADDR="$(ip -4 -o addr show dev wlan0 scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)"
note "IPv4 ready: ${IPV4_ADDR:-configured}"
systemctl restart ssh.service || true

stage "15 FIRSTBOOT COMPLETE"
# Commit completion before disabling this service. If power is lost after the
# marker but before disable finishes, the marker branch retries the disable.
touch "$MARKER"
sync
systemctl disable bpi-zero-wbuild-firstboot.service >/dev/null 2>&1 || \
    fail "provisioning complete but unable to disable firstboot service."
cleanup_completed_state
note "Provisioning complete: storage, identity, Wi-Fi, DHCP, SSH and network diagnostics ready."
note "No reboot required."
exit 0
