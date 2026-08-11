#!/bin/bash
set -euo pipefail

LOG=/var/log/bpi-zero-wbuild-firstboot.log
MARKER=/var/lib/bpi-zero-wbuild-firstboot.done
RESIZE_FAILED=/var/lib/bpi-zero-wbuild-partition-resize.failed

exec >>"$LOG" 2>&1

stage() {
    echo
    echo "[BPI-ZERO-WBUILD] $*"
}

stage "01 FIRSTBOOT SERVICE STARTED"
date -Is 2>/dev/null || date

if [ -e "$MARKER" ]; then
    echo "Already complete."
    exit 0
fi

stage "02 GROWING ROOT PARTITION AND FILESYSTEM"

ROOT_DEV="$(findmnt -n -o SOURCE /)"
ROOT_DEV="$(readlink -f "$ROOT_DEV")"
PARTNUM="$(lsblk -no PARTN "$ROOT_DEV" | tr -d '[:space:]')"
PKNAME="$(lsblk -no PKNAME "$ROOT_DEV" | tr -d '[:space:]')"

RESIZE_OK=0
if [ -n "$ROOT_DEV" ] && [ -n "$PARTNUM" ] && [ -n "$PKNAME" ]; then
    DISK="/dev/$PKNAME"
    TOTAL_SECTORS="$(blockdev --getsz "$DISK" 2>/dev/null || true)"
    ROOT_BASENAME="$(basename "$ROOT_DEV")"
    PART_START="$(cat "/sys/class/block/$ROOT_BASENAME/start" 2>/dev/null || true)"
    KERNEL_BEFORE="$(blockdev --getsz "$ROOT_DEV" 2>/dev/null || true)"

    echo "Root partition:        $ROOT_DEV"
    echo "Parent disk:           $DISK"
    echo "Partition no.:         $PARTNUM"
    echo "Partition start:       $PART_START"
    echo "Disk sectors:          $TOTAL_SECTORS"
    echo "Kernel sectors before: $KERNEL_BEFORE"

    if ! command -v partx >/dev/null 2>&1; then
        echo "ERROR: partx is unavailable; online partition refresh cannot continue."
    elif ! command -v resize2fs >/dev/null 2>&1; then
        echo "ERROR: resize2fs is unavailable; online filesystem grow cannot continue."
    elif ! printf '%s' "$TOTAL_SECTORS" | grep -Eq '^[0-9]+$' || \
         ! printf '%s' "$PART_START" | grep -Eq '^[0-9]+$'; then
        echo "ERROR: unable to determine valid disk/partition sector geometry."
    else
        EXPECTED_SECTORS=$((TOTAL_SECTORS - PART_START))
        echo "Expected root sectors: $EXPECTED_SECTORS"

        set +e
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
        PARTITION_RC=$?
        set -e

        if [ "$PARTITION_RC" -eq 0 ]; then
            rm -f "$RESIZE_FAILED"
            sync
            echo "Partition table update verified."

            stage "03 UPDATING LIVE ROOT PARTITION SIZE"
            set +e
            partx --update --nr "$PARTNUM" "$DISK"
            PARTX_RC=$?
            set -e

            if [ "$PARTX_RC" -eq 0 ]; then
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

                if [ "$KERNEL_UPDATED" -eq 1 ]; then
                    stage "04 GROWING ROOT FILESYSTEM ONLINE"
                    echo "Before:"
                    df -h /
                    set +e
                    resize2fs "$ROOT_DEV"
                    FS_RC=$?
                    set -e
                    if [ "$FS_RC" -eq 0 ]; then
                        echo "After:"
                        df -h /
                        RESIZE_OK=1
                        rm -f "$RESIZE_FAILED"
                        touch /var/lib/bpi-zero-wbuild-resize.done
                        sync
                        echo "Online root expansion completed without reboot."
                    else
                        echo "ERROR: resize2fs failed with rc=$FS_RC."
                    fi
                else
                    echo "ERROR: kernel did not expose the expanded partition size after partx."
                    echo "Expected sectors: $EXPECTED_SECTORS"
                    echo "Observed sectors: ${KERNEL_AFTER:-unknown}"
                fi
            else
                echo "ERROR: partx failed to update the live partition with rc=$PARTX_RC."
            fi
        else
            echo "ERROR: partition resize failed with rc=$PARTITION_RC."
        fi
    fi
else
    echo "ERROR: unable to determine root disk/partition; resize skipped."
fi


stage "05 SETTING HOSTNAME AND ACCOUNTS"

echo 'bpi-zero-wbuild' >/etc/hostname
hostnamectl set-hostname bpi-zero-wbuild || true

if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E 's/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1\tbpi-zero-wbuild/' /etc/hosts
else
    printf '127.0.1.1\tbpi-zero-wbuild\n' >>/etc/hosts
fi

echo 'root:bpi-zero-wbuild' | chpasswd

if ! id bpi-zero-wbuild >/dev/null 2>&1; then
    useradd -m -s /bin/bash bpi-zero-wbuild
fi
echo 'bpi-zero-wbuild:bpi-zero-wbuild' | chpasswd

timedatectl set-ntp true || true

stage "06 GENERATING SSH HOST KEYS"
ssh-keygen -A

stage "07 INSTALLING REGULATORY + BCM43430 WIFI FIRMWARE"

ROOT_FW=/root/brcmfmac43430-sdio.bin
ROOT_FW_BOARD='/root/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin'
ROOT_CLM=/root/brcmfmac43430-sdio.clm_blob
ROOT_CLM_BOARD='/root/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob'
ROOT_NVRAM='/root/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt'
ROOT_REGDB=/root/regulatory.db
ROOT_REGSIG=/root/regulatory.db.p7s

for fw in "$ROOT_FW" "$ROOT_FW_BOARD" "$ROOT_CLM" "$ROOT_CLM_BOARD" "$ROOT_NVRAM" "$ROOT_REGDB" "$ROOT_REGSIG"; do
    if [ ! -s "$fw" ]; then
        echo "ERROR: staged Wi-Fi firmware missing: $fw"
        exit 1
    fi
done

mkdir -p /usr/lib/firmware/brcm

cp -f "$ROOT_REGDB" /usr/lib/firmware/regulatory.db
cp -f "$ROOT_REGSIG" /usr/lib/firmware/regulatory.db.p7s
cp -f "$ROOT_FW" /usr/lib/firmware/brcm/brcmfmac43430-sdio.bin
cp -f "$ROOT_FW_BOARD" '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin'
cp -f "$ROOT_CLM" /usr/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob
cp -f "$ROOT_CLM_BOARD" '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob'
cp -f "$ROOT_NVRAM" '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt'

chmod 644 \
  /usr/lib/firmware/regulatory.db \
  /usr/lib/firmware/regulatory.db.p7s \
  /usr/lib/firmware/brcm/brcmfmac43430-sdio.bin \
  '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin' \
  /usr/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob \
  '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob' \
  '/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt'

modprobe -r brcmfmac 2>/dev/null || true
modprobe -r brcmutil 2>/dev/null || true
modprobe brcmfmac

stage "08 INSTALLING IWD + REGULATORY SUPPORT"

PACKAGES=(
  /root/readline-common_8.2-6_all.deb
  /root/libreadline8t64_8.2-6_armhf.deb
  /root/libell0_0.77-1_armhf.deb
  /root/wireless-regdb_2026.05.30-1~deb13u1_all.deb
  /root/iwd_3.8-2_armhf.deb
)

for package in "${PACKAGES[@]}"; do
    if [ ! -f "$package" ]; then
        echo "ERROR: package missing: $package"
        exit 1
    fi
done

dpkg --unpack "${PACKAGES[@]}"
dpkg --configure -a

stage "09 READING CONFIG FROM BPIWBUILD PARTITION"

modprobe vfat 2>/dev/null || true
CFG_MNT=/mnt/bpi-zero-wbuild-config
mkdir -p "$CFG_MNT"

CFG_DEV=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    CFG_DEV="$(blkid -L BPIWBUILD 2>/dev/null || true)"
    if [ -n "$CFG_DEV" ]; then
        break
    fi
    udevadm settle --timeout=2 2>/dev/null || true
    sleep 1
done

if [ -z "$CFG_DEV" ]; then
    echo "ERROR: could not find a partition labeled BPIWBUILD."
    exit 1
fi

mount -t vfat -o ro "$CFG_DEV" "$CFG_MNT"
CONFIG="$CFG_MNT/CONFIG.TXT"
if [ ! -f "$CONFIG" ]; then
    umount "$CFG_MNT"
    echo "ERROR: CONFIG.TXT not found on BPIWBUILD partition."
    exit 1
fi

SSID="$(grep -E '^SSID=' "$CONFIG" | tail -n1 | cut -d= -f2-)"
PSK="$(grep -E '^PSK=' "$CONFIG" | tail -n1 | cut -d= -f2-)"
COUNTRY="$(grep -E '^COUNTRY=' "$CONFIG" | tail -n1 | cut -d= -f2-)"
HIDDEN="$(grep -E '^HIDDEN=' "$CONFIG" | tail -n1 | cut -d= -f2-)"
TIMEZONE="$(grep -E '^TIMEZONE=' "$CONFIG" | tail -n1 | cut -d= -f2-)"
umount "$CFG_MNT"

trim() { printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
SSID="$(trim "$SSID")"
PSK="$(trim "$PSK")"
COUNTRY="$(trim "$COUNTRY" | tr '[:lower:]' '[:upper:]')"
HIDDEN="$(trim "$HIDDEN" | tr '[:upper:]' '[:lower:]')"
TIMEZONE="$(trim "$TIMEZONE")"

if [ -z "$SSID" ]; then
    echo "ERROR: SSID is empty in CONFIG.TXT."
    exit 1
fi

PSK_LEN=${#PSK}
if [ "$PSK_LEN" -lt 8 ] || [ "$PSK_LEN" -gt 63 ]; then
    echo "ERROR: PSK must be 8-63 characters (got $PSK_LEN)."
    exit 1
fi

if ! printf '%s' "$COUNTRY" | grep -Eq '^[A-Z]{2}$'; then
    echo "ERROR: COUNTRY must be a two-letter code such as CA, got '$COUNTRY'."
    exit 1
fi

case "$HIDDEN" in
    true|false) ;;
    *) HIDDEN="false" ;;
esac

if [ -z "$TIMEZONE" ]; then
    TIMEZONE="America/Edmonton"
fi

stage "10 SETTING TIME ZONE"
if timedatectl list-timezones 2>/dev/null | grep -qxF "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE" || true
else
    echo "WARNING: invalid timezone '$TIMEZONE'; using America/Edmonton."
    timedatectl set-timezone "America/Edmonton" || true
fi

stage "11 CONFIGURING WIFI + DHCP"

mkdir -p /etc/iwd /var/lib/iwd /etc/systemd/network
cat >/etc/iwd/main.conf <<EOF2
[General]
Country=$COUNTRY
EOF2

if printf '%s' "$SSID" | grep -Eq '^[A-Za-z0-9 _-]+$'; then
    IWD_NAME="${SSID}.psk"
else
    IWD_HEX="$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n')"
    IWD_NAME="=${IWD_HEX}.psk"
fi

PROFILE="/var/lib/iwd/$IWD_NAME"
{
    echo '[Security]'
    printf 'Passphrase=%s\n' "$PSK"
    echo
    echo '[Settings]'
    echo 'AutoConnect=true'
    printf 'Hidden=%s\n' "$HIDDEN"
} >"$PROFILE"
chmod 600 "$PROFILE"

cat >/etc/systemd/network/25-wlan0.network <<'EOF2'
[Match]
Name=wlan0

[Network]
DHCP=ipv4
IPv6AcceptRA=no
EOF2

systemctl daemon-reload
systemctl enable iwd.service
systemctl enable systemd-networkd.service || true
systemctl enable ssh.service || true
systemctl restart iwd.service
systemctl restart systemd-networkd.service
systemctl restart systemd-resolved.service || true

stage "12 VERIFYING IPV4"

has_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show dev wlan0 scope global 2>/dev/null | grep -q 'inet '
        return $?
    fi

    SYSTEMD_COLORS=0 networkctl status wlan0 --no-pager 2>/dev/null |
        grep -Eq 'Address:[[:space:]]+[0-9]{1,3}(\.[0-9]{1,3}){3}([/[:space:]]|$)'
}

show_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -br addr show wlan0 || true
    else
        SYSTEMD_COLORS=0 networkctl status wlan0 --no-pager 2>/dev/null |
            grep -E 'State:|Address:|Gateway:|DNS:' || true
    fi
}

if ! command -v networkctl >/dev/null 2>&1 && ! command -v ip >/dev/null 2>&1; then
    echo "ERROR: neither networkctl nor ip is available to verify IPv4."
    exit 1
fi

DHCP_OK=0
for attempt in $(seq 1 90); do
    if has_ipv4; then
        DHCP_OK=1
        break
    fi
    sleep 1
done

if [ "$DHCP_OK" -ne 1 ]; then
    echo "ERROR: wlan0 did not receive an IPv4 DHCP address within 90 seconds."
    echo "Useful diagnostics:"
    echo "  networkctl status wlan0 --no-pager"
    echo "  journalctl -b -u iwd --no-pager"
    echo "  journalctl -b -u systemd-networkd --no-pager"
    echo "  dmesg | grep -Ei 'brcmfmac|firmware|mmc|sdio'"
    exit 1
fi

show_ipv4
systemctl restart ssh.service || true


mkdir -p /var/lib
if [ "$RESIZE_OK" -eq 1 ]; then
    stage "13 FIRSTBOOT COMPLETE"
    touch "$MARKER"
    systemctl disable bpi-zero-wbuild-firstboot.service || true
    echo "Provisioning completed with full root filesystem, networking, and SSH available."
    echo "No reboot is required."
else
    touch "$RESIZE_FAILED"
    echo "Provisioning has network and SSH available, but automatic root expansion is incomplete."
    echo "The firstboot service remains enabled so the resize path can retry on the next boot."
fi

exit 0
