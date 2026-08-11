#!/usr/bin/env bash
# ============================================================
#  bpi-zero-clock - image builder (Linux)
# ============================================================
#
# Builds a clock-ready image for the Banana Pi M2 Zero running Debian
# Trixie, with:
#   - partition 1: FAT32 "BPIWBUILD" - editable CONFIG.TXT
#                  (Wi-Fi SSID/PSK/COUNTRY/HIDDEN + TIMEZONE)
#   - partition 2: ext4 root filesystem, with Wi-Fi firmware,
#                  iwd, first-boot provisioning, and the clock
#                  hardware layer staged into the image
#
# The upstream boot image ships a small placeholder partition
# (its own file identifies it: PARTITION_INTENTIONALLY_EMPTY.TXT)
# that the SoC's boot process does not use. This build drops it
# entirely rather than carrying it forward -- see scripts/patch_mbr.py.
#
# Requirements: bash, python3, ar, tar, curl or wget, gzip.
# No mkfs.vfat/mtools/fdisk/parted required -- the FAT32
# partition and MBR partition table are built by hand in
# scripts/make_fat32.py and this script.
#
# Usage:
#   ./build.sh
#
# Override any of these via environment variables before running:
#   BOOT_URL, DEBIAN_URL, OUT_DIR, WORK_DIR, CONFIG_PART_MB,
# #
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: build.sh must run as root (mount, apt, depmod)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${BPI_ZERO_CLOCK_VERSION:-1.0.3}"

: "${BOOT_URL:=https://dl.sd-card-images.johang.se/boots/2026-08-01/boot-banana_pi_m2_zero.bin.gz}"
: "${DEBIAN_URL:=https://dl.sd-card-images.johang.se/debians/2026-08-03/debian-trixie-armhf-ner4uz.bin.gz}"
: "${FIRMWARE_DEB_URL:=https://ftp.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/firmware-brcm80211_20250410-2_all.deb}"
: "${IWD_DEB_URL:=https://deb.debian.org/debian/pool/main/i/iwd/iwd_3.8-2_armhf.deb}"
: "${LIBELL_DEB_URL:=https://deb.debian.org/debian/pool/main/e/ell/libell0_0.77-1_armhf.deb}"
: "${LIBREADLINE_DEB_URL:=https://deb.debian.org/debian/pool/main/r/readline/libreadline8t64_8.2-6_armhf.deb}"
: "${READLINE_COMMON_DEB_URL:=https://deb.debian.org/debian/pool/main/r/readline/readline-common_8.2-6_all.deb}"
: "${WIRELESS_REGDB_DEB_URL:=https://deb.debian.org/debian/pool/main/w/wireless-regdb/wireless-regdb_2026.05.30-1~deb13u1_all.deb}"
# AP6212 Bluetooth firmware is board firmware and is owned by the generalized
# base image. Use the exact Banana Pi vendor payload validated on BPI-M2-Zero.
# BlueZ userspace remains application-owned and is not installed here.
BPI_WIFI_COMMIT=6dee7aabad92112e548b551c5acb9611d15e5b33
: "${BT_HCD_URL:=https://raw.githubusercontent.com/BPI-SINOVOIP/BPI_WiFi_Firmware/${BPI_WIFI_COMMIT}/ap6212/bcm43438a1.hcd}"
: "${WORK_DIR:=$HERE/build}"
: "${OUT_DIR:=$HERE/out}"
: "${CONFIG_PART_MB:=64}"   # size of the BPIWBUILD FAT32 partition

mkdir -p "$WORK_DIR" "$OUT_DIR"
cd "$WORK_DIR"

log() { echo ">> $*"; }

# ------------------------------------------------------------
# 0. Host dependency check.
# ------------------------------------------------------------
MISSING_HOST_PKGS=()
command -v ar >/dev/null 2>&1 || MISSING_HOST_PKGS+=(binutils)
command -v xz >/dev/null 2>&1 || MISSING_HOST_PKGS+=(xz-utils)
command -v dtc >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v depmod >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v modinfo >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    MISSING_HOST_PKGS+=(curl)
fi

if [ "${#MISSING_HOST_PKGS[@]}" -gt 0 ]; then
    log "installing missing host dependencies: ${MISSING_HOST_PKGS[*]}"
    apt-get update
    apt-get install -y "${MISSING_HOST_PKGS[@]}"
fi

fetch() {
    local url="$1" dest="$2"
    local meta tmp meta_tmp cached_url=""
    meta="${dest}.source-url"
    tmp="${dest}.tmp.$$"
    meta_tmp="${meta}.tmp.$$"

    if [ -s "$dest" ] && [ -s "$meta" ]; then
        cached_url="$(head -n1 "$meta" 2>/dev/null || true)"
        if [ "$cached_url" = "$url" ]; then
            log "present: $(basename "$dest")"
            return 0
        fi
    fi

    if [ -s "$dest" ]; then
        log "source changed or cache metadata missing; refreshing: $(basename "$dest")"
    else
        log "downloading: $(basename "$dest")"
    fi

    rm -f "$tmp" "$meta_tmp"
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fL --retry 3 -o "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -O "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    else
        echo "ERROR: neither curl nor wget is available." >&2
        return 1
    fi

    mv -f "$tmp" "$dest"
    printf '%s\n' "$url" > "$meta_tmp"
    mv -f "$meta_tmp" "$meta"
}

# ------------------------------------------------------------
# 1. Download boot + root images, decompress
# ------------------------------------------------------------
fetch "$BOOT_URL" boot.bin.gz
fetch "$DEBIAN_URL" debian.bin.gz

log "decompressing boot/root images"
gunzip -k -f boot.bin.gz
gunzip -k -f debian.bin.gz

# ------------------------------------------------------------
# 2. Download runtime packages (staged into /root, installed by
#    the firstboot service on first boot). Recreate pkgroot on each
#    build so removed features cannot survive as stale staged files.
# ------------------------------------------------------------
rm -rf pkgroot
mkdir -p pkgroot
fetch "$FIRMWARE_DEB_URL" firmware-brcm80211.deb
fetch "$IWD_DEB_URL" pkgroot/iwd_3.8-2_armhf.deb
fetch "$LIBELL_DEB_URL" pkgroot/libell0_0.77-1_armhf.deb
fetch "$LIBREADLINE_DEB_URL" pkgroot/libreadline8t64_8.2-6_armhf.deb
fetch "$READLINE_COMMON_DEB_URL" pkgroot/readline-common_8.2-6_all.deb
fetch "$WIRELESS_REGDB_DEB_URL" pkgroot/wireless-regdb_2026.05.30-1~deb13u1_all.deb

extract_deb_data() {
    # $1 = .deb path, $2 = extraction dir
    # Resolve deb to an absolute path BEFORE the cd below -- otherwise a
    # relative path (the normal case here) silently resolves against the
    # wrong directory once we've already cd'd into $dest.
    local deb dest
    deb="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    dest="$2"
    rm -rf "$dest" && mkdir -p "$dest"
    (cd "$dest" && ar x "$deb")
    local data
    data="$(ls "$dest"/data.tar.* | head -n1)"
    tar -xf "$data" -C "$dest"
}

log "extracting BCM43430 firmware from firmware-brcm80211"
extract_deb_data firmware-brcm80211.deb _fw_extract
FW_DIR=_fw_extract/usr/lib/firmware
CYPRESS_BIN="$FW_DIR/cypress/cyfmac43430-sdio.bin"
CYPRESS_CLM="$FW_DIR/cypress/cyfmac43430-sdio.clm_blob"
BOARD_TXT="$FW_DIR/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt"
for f in "$CYPRESS_BIN" "$CYPRESS_CLM" "$BOARD_TXT"; do
    [ -s "$f" ] || { echo "ERROR: missing firmware payload $f"; exit 1; }
done
mkdir -p pkgroot
cp -f "$CYPRESS_BIN" "pkgroot/brcmfmac43430-sdio.bin"
cp -f "$CYPRESS_BIN" "pkgroot/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin"
cp -f "$CYPRESS_CLM" "pkgroot/brcmfmac43430-sdio.clm_blob"
cp -f "$CYPRESS_CLM" "pkgroot/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob"
cp -f "$BOARD_TXT" "pkgroot/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt"

log "extracting regulatory.db from wireless-regdb"
extract_deb_data pkgroot/wireless-regdb_2026.05.30-1~deb13u1_all.deb _regdb_extract
REGDB="_regdb_extract/usr/lib/firmware/regulatory.db-upstream"
REGSIG="_regdb_extract/usr/lib/firmware/regulatory.db.p7s-upstream"
for f in "$REGDB" "$REGSIG"; do
    [ -s "$f" ] || { echo "ERROR: missing regulatory payload $f"; exit 1; }
done
cp -f "$REGDB" pkgroot/regulatory.db
cp -f "$REGSIG" pkgroot/regulatory.db.p7s

log "fetching hardware-validated Banana Pi AP6212 Bluetooth HCD"
fetch "$BT_HCD_URL" bpi-ap6212-bcm43438a1.hcd
[ "$(stat -c %s bpi-ap6212-bcm43438a1.hcd)" -eq 33376 ] || {
    echo "ERROR: unexpected Banana Pi AP6212 Bluetooth HCD size" >&2
    exit 1
}
BT_FIRMWARE_SOURCE="BananaPi-AP6212-${BPI_WIFI_COMMIT}-board-specific"

rm -rf _fw_extract _regdb_extract

# ------------------------------------------------------------
# 3. Stage the overlay (renamed scripts/services) into pkgroot
# ------------------------------------------------------------
# Stage firstboot/resize helpers, explicitly excluding the obsolete runtime
# Bluetooth firmware provisioner from older source trees.
for src in "$HERE"/overlay/root/*.sh "$HERE"/overlay/root/*.service; do
    [ -e "$src" ] || continue
    case "$(basename "$src")" in
        bpi-zero-wbuild-btfirmware.sh|bpi-zero-wbuild-btfirmware.service) continue ;;
    esac
    cp -f "$src" pkgroot/
done

chmod 755 pkgroot/*.sh
chmod 644 pkgroot/*.service pkgroot/regulatory.db* \
    pkgroot/brcmfmac43430-sdio* pkgroot/*.deb

# ------------------------------------------------------------
# 4. Inject pkgroot into /root and install first-boot units.
#    systemd-networkd is left completely stock. Provisioning is
#    an independent service, so resize failures cannot block DHCP.
# ------------------------------------------------------------
log "injecting files into root filesystem (requires loop mount + root)"
MNT="$WORK_DIR/_mnt_root"
mkdir -p "$MNT"
if mountpoint -q "$MNT"; then umount "$MNT"; fi
mount -o loop,rw debian.bin "$MNT"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

cp -f pkgroot/* "$MNT/root/"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/etc"

cp -f "$HERE/overlay/root/bpi-zero-wbuild-firstboot.service" \
    "$MNT/etc/systemd/system/bpi-zero-wbuild-firstboot.service"

# Keep the base image on a single first-boot provisioning path.
# Bluetooth firmware is embedded directly, and root growth completes online.
rm -f \
    "$MNT/etc/systemd/system/bpi-zero-wbuild-btfirmware.service" \
    "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-wbuild-btfirmware.service" \
    "$MNT/root/bpi-zero-wbuild-btfirmware.service" \
    "$MNT/root/bpi-zero-wbuild-btfirmware.sh" \
    "$MNT/etc/systemd/system/bpi-zero-wbuild-resizefs.service" \
    "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-wbuild-resizefs.service" \
    "$MNT/root/bpi-zero-wbuild-resizefs.service" \
    "$MNT/root/bpi-zero-wbuild-resizefs.sh"

# Install ONLY the board-qualified AP6212 HCD name validated on BPI-M2-Zero.
# Do not install a generic BCM43430A1.hcd fallback: the Debian generic payload
# produced UART baud/reset timeouts on this hardware.
mkdir -p "$MNT/usr/lib/firmware/brcm"
rm -f "$MNT/usr/lib/firmware/brcm/BCM43430A1.hcd"
install -m 0644 bpi-ap6212-bcm43438a1.hcd \
    "$MNT/usr/lib/firmware/brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd"

ln -sfn ../bpi-zero-wbuild-firstboot.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-wbuild-firstboot.service"

mapfile -t KERNEL_ABIS < <(find "$MNT/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
if [ "${#KERNEL_ABIS[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one kernel ABI in target rootfs; found ${#KERNEL_ABIS[@]}." >&2
    printf '       %s\n' "${KERNEL_ABIS[@]:-none}" >&2
    exit 1
fi
KERNEL_ABI="${KERNEL_ABIS[0]}"

# ------------------------------------------------------------
# Clock hardware layer: immutable hardware-validated MAX98357A
# release artifacts for the exact Debian kernel ABI. Production
# clocks never compile the codec module or patch Device Tree.
# ------------------------------------------------------------
VALIDATED_ABI="6.12.100+deb13-armmp"
VALIDATED_MODULE_SHA256="906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6"
VALIDATED_DTB_SHA256="7d54132d9b707ec62d5b72e08cd329b557a92940664e48164b5b8a8cfd5fcaff"
VALIDATED_DIR="$HERE/clock/validated/$VALIDATED_ABI"
CLOCK_DTB_NAME="sun8i-h2-plus-bananapi-m2-zero.dtb"
MAX98357A_KO="$VALIDATED_DIR/snd-soc-max98357a.ko"
VALIDATED_DTB="$VALIDATED_DIR/$CLOCK_DTB_NAME"

[ "$KERNEL_ABI" = "$VALIDATED_ABI" ] || {
    echo "ERROR: bpi-zero-clock $VERSION is validated only for kernel ABI $VALIDATED_ABI." >&2
    echo "       Image kernel ABI is $KERNEL_ABI." >&2
    exit 1
}

for f in "$MAX98357A_KO" "$VALIDATED_DTB"; do
    [ -s "$f" ] || { echo "ERROR: missing validated release artifact: $f" >&2; exit 1; }
done

MODULE_SHA256="$(sha256sum "$MAX98357A_KO" | awk '{print $1}')"
DTB_SHA256="$(sha256sum "$VALIDATED_DTB" | awk '{print $1}')"
[ "$MODULE_SHA256" = "$VALIDATED_MODULE_SHA256" ] || {
    echo "ERROR: validated MAX98357A module hash mismatch." >&2
    echo "       Expected: $VALIDATED_MODULE_SHA256" >&2
    echo "       Actual:   $MODULE_SHA256" >&2
    exit 1
}
[ "$DTB_SHA256" = "$VALIDATED_DTB_SHA256" ] || {
    echo "ERROR: validated clock DTB hash mismatch." >&2
    echo "       Expected: $VALIDATED_DTB_SHA256" >&2
    echo "       Actual:   $DTB_SHA256" >&2
    exit 1
}

MODULE_VERMAGIC="$(modinfo -F vermagic "$MAX98357A_KO" 2>/dev/null | awk '{print $1}')"
[ "$MODULE_VERMAGIC" = "$VALIDATED_ABI" ] || {
    echo "ERROR: MAX98357A vermagic '$MODULE_VERMAGIC' != '$VALIDATED_ABI'." >&2
    exit 1
}
MODULE_NAME="$(modinfo -F name "$MAX98357A_KO" 2>/dev/null || true)"
[ "$MODULE_NAME" = "snd_soc_max98357a" ] || {
    echo "ERROR: unexpected validated module name: ${MODULE_NAME:-unknown}" >&2
    exit 1
}
modinfo -F alias "$MAX98357A_KO" 2>/dev/null | grep -q 'maxim,max98357a' || {
    echo "ERROR: validated module lacks maxim,max98357a OF alias." >&2
    exit 1
}

dtc -I dtb -O dtb -o /dev/null "$VALIDATED_DTB"
[ "$(fdtget -t s "$VALIDATED_DTB" /max98357a compatible)" = "maxim,max98357a" ]
[ "$(fdtget -t x "$VALIDATED_DTB" /max98357a sdmode-delay)" = "5" ]
[ "$(fdtget -t x "$VALIDATED_DTB" /sound-max98357a simple-audio-card,mclk-fs)" = "100" ]
! dtc -I dtb -O dts "$VALIDATED_DTB" 2>/dev/null | grep -q 'linux,spdif-dit'
! dtc -I dtb -O dts "$VALIDATED_DTB" 2>/dev/null | grep -q 'mk-piclock-max98357a-enable-hog'

CLOCK_DTB_OUT="$MNT/usr/lib/firmware/$KERNEL_ABI/device-tree/$CLOCK_DTB_NAME"
mkdir -p "$(dirname "$CLOCK_DTB_OUT")" \
             "$MNT/lib/modules/$KERNEL_ABI/extra" \
             "$MNT/etc/modules-load.d" \
             "$MNT/usr/local/sbin" \
             "$MNT/etc/systemd/system/multi-user.target.wants" \
             "$MNT/etc/apt/preferences.d"

install -m 0644 "$VALIDATED_DTB" "$CLOCK_DTB_OUT"
install -m 0644 "$MAX98357A_KO" \
    "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"

# PA1 is owned only by the MAX98357A codec driver. Remove every artifact
# from the retired SPDIF dummy-codec/userspace amp-gate implementation.
# Keep this as an explicit list so a stale source/image cannot silently carry
# the old PA1 owner into production.
LEGACY_AMP_GATE_PATHS=(
    "$MNT/etc/systemd/system/mk-clock-amp-gate.service"
    "$MNT/etc/systemd/system/multi-user.target.wants/mk-clock-amp-gate.service"
    "$MNT/usr/lib/systemd/system/mk-clock-amp-gate.service"
    "$MNT/lib/systemd/system/mk-clock-amp-gate.service"
    "$MNT/usr/local/sbin/mk-clock-amp-gate"
    "$MNT/usr/local/bin/mk-clock-amp-gate"
    "$MNT/root/mk-clock-amp-gate"
    "$MNT/etc/modules-load.d/mk-clock-amp-gate.conf"
)
rm -f "${LEGACY_AMP_GATE_PATHS[@]}"

# Build invariant: no legacy amp-gate file or symlink may survive. Test both
# -e and -L so dangling systemd wants symlinks are caught as well.
for legacy_path in "${LEGACY_AMP_GATE_PATHS[@]}"; do
    if [ -e "$legacy_path" ] || [ -L "$legacy_path" ]; then
        echo "ERROR: legacy amp-gate artifact survived image cleanup: ${legacy_path#$MNT}" >&2
        exit 1
    fi
done

cat >"$MNT/etc/modules-load.d/bpi-zero-clock.conf" <<'EOF_MODULES'
spidev
i2c-dev
sun4i-i2s
snd-soc-max98357a
snd-soc-simple-card
hci_uart
btbcm
EOF_MODULES

install -m 0755 "$HERE/clock/hardware/mk-piclock-bind-spidev" \
    "$MNT/usr/local/sbin/mk-piclock-bind-spidev"
install -m 0644 "$HERE/clock/hardware/mk-piclock-spidev.service" \
    "$MNT/etc/systemd/system/mk-piclock-spidev.service"
ln -sfn ../mk-piclock-spidev.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/mk-piclock-spidev.service"
install -m 0644 "$HERE/clock/kernel-pin.pref" \
    "$MNT/etc/apt/preferences.d/bpi-zero-clock-kernel.pref"

depmod -b "$MNT" "$KERNEL_ABI"

MODPROBE_CFG="$(modprobe -d "$MNT" -S "$KERNEL_ABI" -n snd-soc-max98357a 2>/dev/null || true)"
case "$MODPROBE_CFG" in
    *"/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"*) ;;
    *)
        echo "ERROR: depmod/modprobe did not resolve the validated MAX98357A module." >&2
        echo "       $MODPROBE_CFG" >&2
        exit 1
        ;;
esac

[ "$(sha256sum "$CLOCK_DTB_OUT" | awk '{print $1}')" = "$VALIDATED_DTB_SHA256" ]
[ "$(sha256sum "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko" | awk '{print $1}')" = "$VALIDATED_MODULE_SHA256" ]

cat >"$MNT/etc/bpi-zero-clock-release" <<EOF_RELEASE
PRODUCT=bpi-zero-clock
VERSION=$VERSION
BASE_PRODUCT=bpi-zero-wbuild
BASE_VERSION=1.2.6
TARGET=bpi-m2-zero
KERNEL_ABI=$KERNEL_ABI
CLOCK_HARDWARE=bpi-m2-zero-r1
CLOCK_DTB=$CLOCK_DTB_NAME
AUDIO_ENDPOINT=MAX98357A
AUDIO_CODEC_DRIVER=snd-soc-max98357a
AUDIO_CODEC_COMPATIBLE=maxim,max98357a
AUDIO_DRIVER_SOURCE=hardware-validated-local-build
MAX98357A_MODULE=/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko
MAX98357A_MODULE_SHA256=$VALIDATED_MODULE_SHA256
MAX98357A_DTB_SHA256=$VALIDATED_DTB_SHA256
MAX98357A_VERMAGIC=$MODULE_VERMAGIC
MAX98357A_SD_CONTROL=codec-driver-pcm-trigger
MAX98357A_SD_GPIO=PA1
MAX98357A_SD_IDLE=low
MAX98357A_SD_DELAY_MS=5
MAX98357A_MCLK_FS=256
AUDIO_VALIDATION=silence-tone-silence-clean-no-pop-no-tail-hiss
LEGACY_SPDIF_CODEC=removed
LEGACY_AMP_GATE=removed
LEGACY_AMP_GATE_FILES=absent-verified
SPI_DEVICE=/dev/spidev0.0
I2C_DEVICE=/dev/i2c-0
HARDWARE_CONFIGURATION=image-owned
KERNEL_UPDATE_POLICY=image-release-owned
EOF_RELEASE
chmod 0644 "$MNT/etc/bpi-zero-clock-release"

cat >"$MNT/etc/bpi-zero-wbuild-release" <<EOF_BASE_RELEASE
PRODUCT=bpi-zero-wbuild
VERSION=1.2.6
TARGET=bpi-m2-zero
BASE=debian-trixie-armhf
KERNEL_ABI=$KERNEL_ABI
WIFI_FIRMWARE_SOURCE=Debian-firmware-brcm80211-20250410-2
BLUETOOTH_FIRMWARE_SOURCE=$BT_FIRMWARE_SOURCE
BLUETOOTH_FIRMWARE_PATH=brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd
BLUETOOTH_USERSPACE=application-owned
HARDWARE_CONFIGURATION=clock-image-owned
NETWORK_IPV4_VERIFIER=ip-or-networkctl
ROOT_RESIZE_MODE=online-partx-resize2fs
ROOT_RESIZE_ORDER=before-network
FIRSTBOOT_REBOOT=none
EOF_BASE_RELEASE
chmod 0644 "$MNT/etc/bpi-zero-wbuild-release"

sync
umount "$MNT"
trap - EXIT


# ------------------------------------------------------------
# 5. Build the BPIWBUILD FAT32 config partition
# ------------------------------------------------------------
CONFIG_PART_SECTORS=$(( CONFIG_PART_MB * 1024 * 1024 / 512 ))
log "building BPIWBUILD FAT32 partition ($CONFIG_PART_MB MiB)"
python3 "$HERE/scripts/make_fat32.py" bpiwbuild-config.fat32 "$CONFIG_PART_SECTORS" \
    "$HERE/config/CONFIG.TXT.template"

# ------------------------------------------------------------
# 6. Build the MBR + pre-partition raw area (U-Boot/SPL). The
#    upstream boot image's placeholder partition ("PARTITION_
#    INTENTIONALLY_EMPTY.TXT", unused by the boot process) is
#    dropped entirely; the config partition takes its place.
# ------------------------------------------------------------
log "building MBR + pre-partition raw area (2-partition layout)"
python3 "$HERE/scripts/patch_mbr.py" \
    --boot-in boot.bin \
    --boot-out boot_patched.bin \
    --debian-in debian.bin \
    --config-sectors "$CONFIG_PART_SECTORS"

# ------------------------------------------------------------
# 7. Assemble final image
# ------------------------------------------------------------
OUT_IMG="$OUT_DIR/bpi-zero-clock-$VERSION-bpi-m2-zero.img"
log "assembling $OUT_IMG"
cat boot_patched.bin bpiwbuild-config.fat32 debian.bin > "$OUT_IMG"

log "compressing"
gzip -kf -6 "$OUT_IMG"
(
    cd "$OUT_DIR"
    sha256sum "$(basename "$OUT_IMG")" > "$(basename "$OUT_IMG").sha256"
    sha256sum "$(basename "$OUT_IMG").gz" > "$(basename "$OUT_IMG").gz.sha256"
)

log "done"
ls -la "$OUT_DIR"
cat "$OUT_IMG.sha256"
cat "$OUT_IMG.gz.sha256"
