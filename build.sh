#!/usr/bin/env bash
# ============================================================
#  bpi-zero-wbuild - minimal BPI M2 Zero Trixie image builder
# ============================================================
#
# Builds a minimal application-ready image for the Banana Pi M2 Zero running Debian
# Trixie, with:
#   - partition 1: FAT32 "BPIWBUILD" - editable CONFIG.TXT
#                  (Wi-Fi + timezone + root password)
#   - partition 2: ext4 root filesystem, with Wi-Fi/Bluetooth firmware,
#                  first-boot resize/provisioning, SPI0, I2C0 and
#                  playback-only I2S0/MAX98357A hardware support
#
# The upstream boot image ships a small placeholder partition
# (its own file identifies it: PARTITION_INTENTIONALLY_EMPTY.TXT)
# that the SoC's boot process does not use. This build drops it
# entirely rather than carrying it forward -- see scripts/patch_mbr.py.
#
# Requirements: bash, python3, dpkg-deb, curl or wget, gzip, dtc/fdt tools,
# kmod, e2fsprogs and ca-certificates (usable CA trust bundle).
# No mkfs.vfat/mtools/fdisk/parted required -- the FAT32
# partition and MBR partition table are built by hand in
# scripts/make_fat32.py and this script.
#
# Usage:
#   ./build.sh
#
# Override any of these via environment variables before running:
#   BOOT_URL, DEBIAN_URL, OUT_DIR, WORK_DIR, CONFIG_PART_MB,
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: build.sh must run as root (mount, apt, depmod)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${BPI_ZERO_WBUILD_VERSION:-$(tr -d '\r\n' < "$HERE/VERSION")}"

: "${BOOT_URL:=https://dl.sd-card-images.johang.se/boots/2026-08-01/boot-banana_pi_m2_zero.bin.gz}"
: "${DEBIAN_URL:=https://dl.sd-card-images.johang.se/debians/2026-09-07/debian-trixie-armhf-pheiz3.bin.gz}"

DEBIAN_BASE_NAME="$(basename "$DEBIAN_URL")"
DEBIAN_BASE_NAME="${DEBIAN_BASE_NAME%.gz}"
DEBIAN_BASE_NAME="${DEBIAN_BASE_NAME%.bin}"
DEBIAN_IMAGE_DATE="$(printf '%s\n' "$DEBIAN_URL" | sed -nE 's#^.*/debians/([0-9]{4}-[0-9]{2}-[0-9]{2})/.*#\1#p')"
[ -n "$DEBIAN_BASE_NAME" ] || { echo "ERROR: could not derive Debian base name from DEBIAN_URL." >&2; exit 1; }
BOOT_GZIP_SHA256="e106b4cb5efdb9d3a559cd8ca192a2102807c8b80ce451e0333f770eb3fb2979"
: "${FIRMWARE_DEB_URL:=https://ftp.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/firmware-brcm80211_20250410-2_all.deb}"
: "${IWD_DEB_URL:=https://deb.debian.org/debian/pool/main/i/iwd/iwd_3.8-2_armhf.deb}"
: "${LIBELL_DEB_URL:=https://deb.debian.org/debian/pool/main/e/ell/libell0_0.77-1_armhf.deb}"
: "${LIBREADLINE_DEB_URL:=https://deb.debian.org/debian/pool/main/r/readline/libreadline8t64_8.2-6_armhf.deb}"
: "${READLINE_COMMON_DEB_URL:=https://deb.debian.org/debian/pool/main/r/readline/readline-common_8.2-6_all.deb}"
: "${WIRELESS_REGDB_DEB_URL:=https://deb.debian.org/debian/pool/main/w/wireless-regdb/wireless-regdb_2026.05.30-1~deb13u1_all.deb}"
: "${LIBELF_DEB_URL:=https://deb.debian.org/debian/pool/main/e/elfutils/libelf1t64_0.192-4_armhf.deb}"
: "${LIBBPF_DEB_URL:=https://deb.debian.org/debian/pool/main/libb/libbpf/libbpf1_1.5.0-3_armhf.deb}"
: "${LIBMNL_DEB_URL:=https://deb.debian.org/debian/pool/main/libm/libmnl/libmnl0_1.0.5-3_armhf.deb}"
: "${LIBDB_DEB_URL:=https://deb.debian.org/debian/pool/main/d/db5.3/libdb5.3t64_5.3.28+dfsg2-9_armhf.deb}"
: "${LIBTIRPC_COMMON_DEB_URL:=https://deb.debian.org/debian/pool/main/libt/libtirpc/libtirpc-common_1.3.6+ds-1_all.deb}"
: "${LIBTIRPC_DEB_URL:=https://deb.debian.org/debian/pool/main/libt/libtirpc/libtirpc3t64_1.3.6+ds-1_armhf.deb}"
: "${LIBXTABLES_DEB_URL:=https://deb.debian.org/debian/pool/main/i/iptables/libxtables12_1.8.11-2_armhf.deb}"
: "${LIBCAP2_BIN_DEB_URL:=https://deb.debian.org/debian/pool/main/libc/libcap2/libcap2-bin_2.75-10+deb13u1+b1_armhf.deb}"
: "${IPROUTE2_DEB_URL:=https://deb.debian.org/debian/pool/main/i/iproute2/iproute2_6.15.0-1_armhf.deb}"
: "${LIBNL3_DEB_URL:=https://deb.debian.org/debian/pool/main/libn/libnl3/libnl-3-200_3.7.0-2_armhf.deb}"
: "${LIBNLGENL_DEB_URL:=https://deb.debian.org/debian/pool/main/libn/libnl3/libnl-genl-3-200_3.7.0-2_armhf.deb}"
: "${IW_DEB_URL:=https://deb.debian.org/debian/pool/main/i/iw/iw_6.9-1_armhf.deb}"
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
# Keep this list aligned with the documented host requirements above.
command -v python3 >/dev/null 2>&1 || MISSING_HOST_PKGS+=(python3)
command -v dpkg-deb >/dev/null 2>&1 || MISSING_HOST_PKGS+=(dpkg)
command -v gzip >/dev/null 2>&1 || MISSING_HOST_PKGS+=(gzip)
command -v dtc >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v fdtget >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v fdtput >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v depmod >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v modinfo >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v e2fsck >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v tune2fs >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    MISSING_HOST_PKGS+=(curl)
fi
# HTTPS downloads require a usable CA trust bundle. Do not weaken TLS with -k.
[ -s /etc/ssl/certs/ca-certificates.crt ] || MISSING_HOST_PKGS+=(ca-certificates)

if [ "${#MISSING_HOST_PKGS[@]}" -gt 0 ]; then
    log "installing missing host dependencies: ${MISSING_HOST_PKGS[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        apt-get install -y --no-install-recommends "${MISSING_HOST_PKGS[@]}"
fi

# A package may already be installed while its generated bundle is missing.
# Rebuild it once, then fail closed before any HTTPS fetch if trust is unusable.
if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    command -v update-ca-certificates >/dev/null 2>&1 || {
        echo "ERROR: ca-certificates is unavailable; HTTPS downloads cannot be verified." >&2
        exit 1
    }
    log "regenerating HTTPS CA certificate bundle"
    update-ca-certificates >/dev/null
fi
[ -s /etc/ssl/certs/ca-certificates.crt ] || {
    echo "ERROR: HTTPS CA certificate bundle unavailable: /etc/ssl/certs/ca-certificates.crt" >&2
    exit 1
}

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

# Fetch a gzip payload and verify the entire compressed stream before it is
# accepted. curl/wget can successfully return a truncated/corrupt HTTP 200
# payload, and the URL cache alone cannot detect that. A failed integrity check
# invalidates both the payload and its source-url marker so the next attempt is
# guaranteed to perform a fresh download rather than reusing poisoned cache.
fetch_gzip() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        if ! fetch "$url" "$dest"; then
            echo "WARNING: download failed for $(basename "$dest") (attempt $attempt/3)." >&2
            rm -f "$dest" "${dest}.source-url"
            continue
        fi
        if gzip -t "$dest" >/dev/null 2>&1; then
            log "gzip verified: $(basename "$dest")"
            return 0
        fi

        echo "WARNING: gzip integrity check failed for $(basename "$dest") (attempt $attempt/3)." >&2
        rm -f "$dest" "${dest}.source-url"
    done

    echo "ERROR: $(basename "$dest") failed gzip integrity verification after 3 fresh downloads." >&2
    return 1
}

# ------------------------------------------------------------
# 1. Download boot + root images, verify compressed streams, decompress
# ------------------------------------------------------------
fetch_gzip "$BOOT_URL" boot.bin.gz
fetch_gzip "$DEBIAN_URL" debian.bin.gz
[ "$(sha256sum boot.bin.gz | awk '{print $1}')" = "$BOOT_GZIP_SHA256" ] || {
    echo "ERROR: boot image SHA256 mismatch." >&2
    echo "       Expected: $BOOT_GZIP_SHA256" >&2
    echo "       Actual:   $(sha256sum boot.bin.gz | awk '{print $1}')" >&2
    exit 1
}
log "Debian root image accepted from configured trusted URL: $DEBIAN_URL"

log "decompressing boot/root images"
gunzip -k -f boot.bin.gz
gunzip -k -f debian.bin.gz
CONFIG_PART_SECTORS=$(( CONFIG_PART_MB * 1024 * 1024 / 512 ))
log "building final MBR layout early for PARTUUID/fstab/extlinux policy"
python3 "$HERE/scripts/patch_mbr.py" \
    --boot-in boot.bin \
    --boot-out boot_patched.bin \
    --debian-in debian.bin \
    --config-sectors "$CONFIG_PART_SECTORS"
ROOT_PARTUUID="$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --partition 2)"
CONFIG_START_SECTOR="$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --partition 1 --field start)"
CONFIG_VOLID_HEX="$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --field disk-signature)"

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
fetch "$LIBELF_DEB_URL" pkgroot/libelf1t64_0.192-4_armhf.deb
fetch "$LIBBPF_DEB_URL" pkgroot/libbpf1_1.5.0-3_armhf.deb
fetch "$LIBMNL_DEB_URL" pkgroot/libmnl0_1.0.5-3_armhf.deb
fetch "$LIBDB_DEB_URL" 'pkgroot/libdb5.3t64_5.3.28+dfsg2-9_armhf.deb'
fetch "$LIBTIRPC_COMMON_DEB_URL" 'pkgroot/libtirpc-common_1.3.6+ds-1_all.deb'
fetch "$LIBTIRPC_DEB_URL" 'pkgroot/libtirpc3t64_1.3.6+ds-1_armhf.deb'
fetch "$LIBXTABLES_DEB_URL" pkgroot/libxtables12_1.8.11-2_armhf.deb
fetch "$LIBCAP2_BIN_DEB_URL" 'pkgroot/libcap2-bin_2.75-10+deb13u1+b1_armhf.deb'
fetch "$IPROUTE2_DEB_URL" pkgroot/iproute2_6.15.0-1_armhf.deb
fetch "$LIBNL3_DEB_URL" pkgroot/libnl-3-200_3.7.0-2_armhf.deb
fetch "$LIBNLGENL_DEB_URL" pkgroot/libnl-genl-3-200_3.7.0-2_armhf.deb
fetch "$IW_DEB_URL" pkgroot/iw_6.9-1_armhf.deb

extract_deb_data() {
    local deb="$1" dest="$2"
    rm -rf "$dest" && mkdir -p "$dest"
    dpkg-deb -x "$deb" "$dest"
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
log "extracting regulatory.db from wireless-regdb"
extract_deb_data pkgroot/wireless-regdb_2026.05.30-1~deb13u1_all.deb _regdb_extract
REGDB="_regdb_extract/usr/lib/firmware/regulatory.db-upstream"
REGSIG="_regdb_extract/usr/lib/firmware/regulatory.db.p7s-upstream"
for f in "$REGDB" "$REGSIG"; do
    [ -s "$f" ] || { echo "ERROR: missing regulatory payload $f"; exit 1; }
done
log "fetching hardware-validated Banana Pi AP6212 Bluetooth HCD"
fetch "$BT_HCD_URL" bpi-ap6212-bcm43438a1.hcd
[ "$(stat -c %s bpi-ap6212-bcm43438a1.hcd)" -eq 33376 ] || {
    echo "ERROR: unexpected Banana Pi AP6212 Bluetooth HCD size" >&2
    exit 1
}
BT_FIRMWARE_SOURCE="BananaPi-AP6212-${BPI_WIFI_COMMIT}-board-specific"

# ------------------------------------------------------------
# 3. Stage the overlay into pkgroot
# ------------------------------------------------------------
# Stage only the one-shot firstboot script into /root. The systemd unit is
# installed directly under /etc/systemd/system below, so a duplicate /root copy
# has no runtime purpose. Build-cache *.source-url metadata is also build-host
# state and must never enter the appliance rootfs.
for src in "$HERE"/overlay/root/*.sh; do
    [ -e "$src" ] || continue
    case "$(basename "$src")" in
        bpi-zero-wbuild-btfirmware.sh) continue ;;
    esac
    cp -f "$src" pkgroot/
done
find pkgroot -maxdepth 1 -type f -name '*.source-url' -delete

chmod 755 pkgroot/*.sh
chmod 644 pkgroot/*.deb

# ------------------------------------------------------------
# 4. Inject pkgroot into /root and install the first-boot unit.
#    Root partition/filesystem expansion is the first operation performed by
#    firstboot. It is fail-closed: no fsck/repair/reboot fallback is installed.
# ------------------------------------------------------------
log "injecting files into root filesystem (requires loop mount + root)"
MNT="$WORK_DIR/_mnt_root"
mkdir -p "$MNT"
if mountpoint -q "$MNT"; then umount "$MNT"; fi
mount -o loop,rw debian.bin "$MNT"
trap 'umount "$MNT" 2>/dev/null || true' EXIT
ROOT_FS_TYPE="$(findmnt -n -o FSTYPE --target "$MNT" 2>/dev/null || true)"
[ "$ROOT_FS_TYPE" = "ext4" ] || {
    echo "ERROR: configured Debian root image mounted as ${ROOT_FS_TYPE:-unknown}, expected ext4." >&2
    exit 1
}
[ -f "$MNT/etc/fstab" ] || { echo "ERROR: target /etc/fstab is missing." >&2; exit 1; }
python3 "$HERE/scripts/set_fstab_policy.py" "$MNT/etc/fstab" --partuuid "$ROOT_PARTUUID"

cp -f pkgroot/* "$MNT/root/"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/etc"

cp -f "$HERE/overlay/root/bpi-zero-wbuild-firstboot.service" \
    "$MNT/etc/systemd/system/bpi-zero-wbuild-firstboot.service"

# Never ship host keys inherited from the pinned Debian root image. The
# ExecStartPre pre-login barrier generates unique keys before ssh/getty proceed.
rm -f "$MNT"/etc/ssh/ssh_host_*

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

# Wi-Fi firmware is image-owned. Install the exact extracted payloads directly
# into the rootfs so firstboot never stages/copies firmware or reloads brcmfmac
# merely to make image contents available.
mkdir -p "$MNT/usr/lib/firmware/brcm"
install -m 0644 "$REGDB" "$MNT/usr/lib/firmware/regulatory.db"
install -m 0644 "$REGSIG" "$MNT/usr/lib/firmware/regulatory.db.p7s"
install -m 0644 "$CYPRESS_BIN" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.bin"
install -m 0644 "$CYPRESS_BIN" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin"
install -m 0644 "$CYPRESS_CLM" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob"
install -m 0644 "$CYPRESS_CLM" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob"
install -m 0644 "$BOARD_TXT" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt"

# Install ONLY the board-qualified AP6212 HCD name validated on BPI-M2-Zero.
# Do not install a generic BCM43430A1.hcd fallback: the Debian generic payload
# produced UART baud/reset timeouts on this hardware.
rm -f "$MNT/usr/lib/firmware/brcm/BCM43430A1.hcd"
install -m 0644 bpi-ap6212-bcm43438a1.hcd \
    "$MNT/usr/lib/firmware/brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd"
rm -rf _fw_extract _regdb_extract

ln -sfn ../bpi-zero-wbuild-firstboot.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-wbuild-firstboot.service"

mapfile -t KERNEL_ABIS < <(find "$MNT/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
if [ "${#KERNEL_ABIS[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one kernel ABI in target rootfs; found ${#KERNEL_ABIS[@]}." >&2
    printf '       %s\n' "${KERNEL_ABIS[@]:-none}" >&2
    exit 1
fi
KERNEL_ABI="${KERNEL_ABIS[0]}"
KERNEL_PACKAGE="linux-image-$KERNEL_ABI"
KERNEL_DEBIAN_VERSION="$(python3 "$HERE/scripts/dpkg_status_field.py" "$MNT/var/lib/dpkg/status" --package "$KERNEL_PACKAGE" --field Version)"
KERNEL_PACKAGE_ARCH="$(python3 "$HERE/scripts/dpkg_status_field.py" "$MNT/var/lib/dpkg/status" --package "$KERNEL_PACKAGE" --field Architecture)"
[ "$KERNEL_PACKAGE_ARCH" = armhf ] || { echo "ERROR: target kernel package architecture is $KERNEL_PACKAGE_ARCH, expected armhf." >&2; exit 1; }
log "target kernel package: $KERNEL_PACKAGE $KERNEL_DEBIAN_VERSION ($KERNEL_PACKAGE_ARCH)"

# ------------------------------------------------------------
# Required hardware interfaces only: SPI0, I2C0 and playback-only MAX98357A.
# GPIO remains the stock kernel interface; application lines are not claimed.
# ------------------------------------------------------------
DTB_NAME="sun8i-h2-plus-bananapi-m2-zero.dtb"
STOCK_DTB="$MNT/usr/lib/linux-image-$KERNEL_ABI/$DTB_NAME"
HW_BUILD_DIR="$WORK_DIR/required-hardware"
HW_DTB_BUILD="$HW_BUILD_DIR/$DTB_NAME"
MAX98357A_BUILD_DIR="$HW_BUILD_DIR/max98357a"

[ -s "$STOCK_DTB" ] || { echo "ERROR: stock Banana Pi DTB missing: ${STOCK_DTB#$MNT}" >&2; exit 1; }
rm -rf "$HW_BUILD_DIR"
mkdir -p "$HW_BUILD_DIR" "$MAX98357A_BUILD_DIR"

log "enabling required SPI0 + I2C0 + MAX98357A hardware"
bash "$HERE/scripts/patch_required_hardware_dtb.sh" "$STOCK_DTB" "$HW_DTB_BUILD"
DTB_SHA256="$(sha256sum "$HW_DTB_BUILD" | awk '{print $1}')"

log "building MAX98357A codec module for $KERNEL_ABI"
MK_KERNEL_ABI="$KERNEL_ABI" MK_DEBIAN_LINUX_VERSION="$KERNEL_DEBIAN_VERSION" MK_DEBIAN_IMAGE_DATE="$DEBIAN_IMAGE_DATE" MK_MAX98357A_BUILD_OUT="$MAX98357A_BUILD_DIR" bash "$HERE/scripts/build_max98357a_module.sh"
MAX98357A_KO="$MAX98357A_BUILD_DIR/snd-soc-max98357a.ko"
[ -s "$MAX98357A_KO" ] || { echo "ERROR: MAX98357A build output missing." >&2; exit 1; }
MODULE_SHA256="$(sha256sum "$MAX98357A_KO" | awk '{print $1}')"
MODULE_VERMAGIC="$(modinfo -F vermagic "$MAX98357A_KO" 2>/dev/null | awk '{print $1}')"
[ "$MODULE_VERMAGIC" = "$KERNEL_ABI" ] || { echo "ERROR: MAX98357A vermagic mismatch." >&2; exit 1; }
[ "$(modinfo -F name "$MAX98357A_KO" 2>/dev/null)" = snd_soc_max98357a ] || { echo "ERROR: unexpected MAX98357A module name." >&2; exit 1; }
modinfo -F alias "$MAX98357A_KO" 2>/dev/null | grep -q 'maxim,max98357a' || { echo "ERROR: MAX98357A OF alias missing." >&2; exit 1; }
[ "$(fdtget -t s "$HW_DTB_BUILD" /max98357a compatible)" = maxim,max98357a ]
[ "$(fdtget -t x "$HW_DTB_BUILD" /max98357a sdmode-delay)" = 5 ]
[ "$(fdtget -t x "$HW_DTB_BUILD" /sound-max98357a simple-audio-card,mclk-fs)" = 100 ]
[ "$(fdtget -t s "$HW_DTB_BUILD" /soc/pinctrl@1c20800/bpi-zero-i2s0-pins pins)" = 'PA18 PA19 PA20' ]
[ "$(fdtget -t s "$HW_DTB_BUILD" /soc/i2c@1c2ac00 status)" = okay ]
python3 "$HERE/scripts/check_gpio_ownership.py" "$HW_DTB_BUILD"
python3 "$HERE/scripts/check_platform_aliases.py" "$HW_DTB_BUILD"
python3 "$HERE/scripts/check_platform_pins.py" "$HW_DTB_BUILD"
python3 "$HERE/scripts/check_bluetooth_topology.py" "$HW_DTB_BUILD"

DTB_BOOT="$MNT/usr/lib/linux-image-$KERNEL_ABI/$DTB_NAME"
DTB_FIRMWARE="$MNT/usr/lib/firmware/$KERNEL_ABI/device-tree/$DTB_NAME"
mkdir -p "$(dirname "$DTB_FIRMWARE")" "$MNT/lib/modules/$KERNEL_ABI/extra" "$MNT/etc/modules-load.d" "$MNT/usr/local/sbin" "$MNT/etc/systemd/system/multi-user.target.wants"
install -m 0644 "$HW_DTB_BUILD" "$DTB_BOOT"
install -m 0644 "$HW_DTB_BUILD" "$DTB_FIRMWARE"
install -m 0644 "$MAX98357A_KO" "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"
install -m 0644 "$HERE/hardware/modules-load.conf" "$MNT/etc/modules-load.d/bpi-zero-required-hardware.conf"
install -m 0755 "$HERE/hardware/bind-spidev" "$MNT/usr/local/sbin/bpi-zero-bind-spidev"
install -m 0644 "$HERE/hardware/spidev.service" "$MNT/etc/systemd/system/bpi-zero-spidev.service"
ln -sfn ../bpi-zero-spidev.service "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-spidev.service"

# Keep only the boot changes required by the assembled two-partition image.
EXTLINUX_CONF="$MNT/boot/extlinux/extlinux.conf"
U_BOOT_DEFAULTS="$MNT/etc/default/u-boot"
[ -s "$EXTLINUX_CONF" ] || { echo "ERROR: extlinux.conf missing from Debian rootfs." >&2; exit 1; }
python3 "$HERE/scripts/set_extlinux_policy.py" "$EXTLINUX_CONF" "$U_BOOT_DEFAULTS" --partuuid "$ROOT_PARTUUID"
grep -Fxq 'prompt 0' "$EXTLINUX_CONF" || { echo "ERROR: extlinux prompt policy verification failed." >&2; exit 1; }
grep -Fxq 'timeout 10' "$EXTLINUX_CONF" || { echo "ERROR: extlinux timeout policy verification failed." >&2; exit 1; }
grep -Eq "^[[:space:]]*append root=PARTUUID=${ROOT_PARTUUID} rw rootwait quiet loglevel=4$" "$EXTLINUX_CONF" || { echo "ERROR: extlinux append policy verification failed." >&2; exit 1; }
grep -Fqx "U_BOOT_ROOT=\"root=PARTUUID=${ROOT_PARTUUID}\"" "$U_BOOT_DEFAULTS" || { echo "ERROR: u-boot root policy verification failed." >&2; exit 1; }
grep -Fqx 'U_BOOT_PARAMETERS="rw rootwait quiet loglevel=4"' "$U_BOOT_DEFAULTS" || { echo "ERROR: u-boot parameter policy verification failed." >&2; exit 1; }

depmod -b "$MNT" "$KERNEL_ABI"
validate_module_resolution() {
    local mod="$1" expected="${2:-}" resolved
    resolved="$(modinfo -b "$MNT" -k "$KERNEL_ABI" -n "$mod" 2>/dev/null || true)"
    [ -n "$resolved" ] || { echo "ERROR: target kernel cannot resolve $mod." >&2; exit 1; }
    if [ -n "$expected" ] && [ "$resolved" != "$expected" ]; then
        echo "ERROR: $mod resolved to '$resolved', expected '$expected'." >&2; exit 1
    fi
    modprobe -d "$MNT" -S "$KERNEL_ABI" -n "$mod" >/dev/null 2>&1 || { echo "ERROR: unresolved module/dependency: $mod" >&2; exit 1; }
}
validate_module_resolution snd-soc-max98357a "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"
validate_module_resolution sun4i-i2s
validate_module_resolution snd-soc-simple-card
validate_module_resolution spidev
validate_module_resolution i2c-dev
validate_module_resolution hci_uart
validate_module_resolution btbcm
[ "$(sha256sum "$DTB_BOOT" | awk '{print $1}')" = "$DTB_SHA256" ]
[ "$(sha256sum "$DTB_FIRMWARE" | awk '{print $1}')" = "$DTB_SHA256" ]
[ "$(sha256sum "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko" | awk '{print $1}')" = "$MODULE_SHA256" ]

# Appliance SD-card safety: do not ship the builder's persistent journal.
rm -rf "$MNT/var/log/journal"
mkdir -p "$MNT/etc/systemd/journald.conf.d"
cat >"$MNT/etc/systemd/journald.conf.d/20-bpi-zero-volatile.conf" <<'EOF_JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF_JOURNAL
chmod 0644 "$MNT/etc/systemd/journald.conf.d/20-bpi-zero-volatile.conf"

cat >"$MNT/etc/bpi-zero-wbuild-release" <<EOF_BASE_RELEASE
PRODUCT=bpi-zero-wbuild
VERSION=$VERSION
TARGET=bpi-m2-zero
BASE=$DEBIAN_BASE_NAME
DEBIAN_SOURCE_URL=$DEBIAN_URL
DEBIAN_IMAGE_DATE=${DEBIAN_IMAGE_DATE:-unknown}
KERNEL_ABI=$KERNEL_ABI
KERNEL_DEBIAN_VERSION=$KERNEL_DEBIAN_VERSION
BOOT_GZIP_SHA256=$BOOT_GZIP_SHA256
DEBIAN_SOURCE_TRUST=configured-https-url-no-pinned-hash
WIFI_FIRMWARE_SOURCE=Debian-firmware-brcm80211-20250410-2
WIFI_FIRMWARE_INSTALL=image-build-direct
BLUETOOTH_FIRMWARE_SOURCE=$BT_FIRMWARE_SOURCE
BLUETOOTH_FIRMWARE_PATH=brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd
BLUETOOTH_USERSPACE=application-owned
ROOT_RESIZE_MODE=firstboot-online-resize2fs-fail-closed
SPI_ALIAS=spi0
SPI_DEVICE=/dev/spidev0.0
I2C_ALIAS=i2c0
I2C_DEVICE=/dev/i2c-0
GPIO_DEVICE=/dev/gpiochip0
AUDIO_ENDPOINT=MAX98357A
AUDIO_CODEC_DRIVER=snd-soc-max98357a
MAX98357A_MODULE_SHA256=$MODULE_SHA256
MAX98357A_DTB_SHA256=$DTB_SHA256
MAX98357A_VERMAGIC=$MODULE_VERMAGIC
MAX98357A_SD_GPIO=PA1
MAX98357A_SD_DELAY_MS=5
MAX98357A_MCLK_FS=256
I2S_LRCLK_GPIO=PA18
I2S_BCLK_GPIO=PA19
I2S_TX_GPIO=PA20
APPLICATION_GPIO_OWNERSHIP=PA0,PA2,PA7,PA8,PA9,PA17-unclaimed-by-image
CONFIG_SECRET_POLICY=PSK-and-ROOT_PASSWORD-blanked-after-successful-firstboot
PRELOGIN_SECURITY=root-password-account-prune-and-ssh-host-keys-before-getty-or-ssh
LOGIN_POLICY=root-only
LOGIN_ACCOUNT=root-only
HARDWARE_SCOPE=wifi-bluetooth-resize-spi-i2c-gpio-i2s-max98357a
EOF_BASE_RELEASE
chmod 0644 "$MNT/etc/bpi-zero-wbuild-release"

# Clone-safe machine identity. Normalize the upstream rootfs regardless of
# whether it ships /etc/machine-id absent, empty, or populated. Every flashed
# clock must generate its own persistent identity. Leave /etc/machine-id
# present but empty. Firstboot Stage 05 explicitly runs
# systemd-machine-id-setup, and the legacy D-Bus path references that same ID.
log "resetting image machine-id for first-boot generation"
mkdir -p "$MNT/var/lib/dbus"
truncate -s 0 "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$MNT/var/lib/dbus/machine-id"

sync
umount "$MNT"
trap - EXIT

# The deployment image must leave the builder with a clean ext4 rootfs.
# Validate read-only and fail the release if consistency is not perfect.
# Do not repair it here: an unexpected dirty/corrupt image is a build failure.
log "validating clean root filesystem (read-only; no repair)"
set +e
e2fsck -f -n debian.bin
ROOTFS_CHECK_RC=$?
set -e
if [ "$ROOTFS_CHECK_RC" -ne 0 ]; then
    echo "ERROR: release root filesystem failed read-only e2fsck (rc=$ROOTFS_CHECK_RC)." >&2
    echo "       Refusing to package an image that would require target-side repair." >&2
    exit 1
fi
ROOTFS_STATE="$(tune2fs -l debian.bin 2>/dev/null | awk -F: '/Filesystem state:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
if [ "$ROOTFS_STATE" != "clean" ]; then
    echo "ERROR: release root filesystem state is '$ROOTFS_STATE', expected 'clean'." >&2
    exit 1
fi
log "root filesystem state: clean"


# ------------------------------------------------------------
# 5. Build the BPIWBUILD FAT32 config partition
# ------------------------------------------------------------
log "building BPIWBUILD FAT32 partition ($CONFIG_PART_MB MiB)"
python3 "$HERE/scripts/make_fat32.py" bpiwbuild-config.fat32 "$CONFIG_PART_SECTORS" \
    "$HERE/config/CONFIG.TXT.template" \
    --hidden-sectors "$CONFIG_START_SECTOR" \
    --volume-id "0x$CONFIG_VOLID_HEX"

# ------------------------------------------------------------
# 6. Revalidate the already-built final MBR layout before assembly.
# ------------------------------------------------------------
[ "$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --partition 2)" = "$ROOT_PARTUUID" ] || { echo "ERROR: patched MBR PARTUUID changed unexpectedly." >&2; exit 1; }
[ "$(stat -c %s boot_patched.bin)" -eq $((CONFIG_START_SECTOR * 512)) ] || { echo "ERROR: patched boot area length does not equal partition-1 start." >&2; exit 1; }

# ------------------------------------------------------------
# 7. Stream the final card layout directly to gzip.
#    The root filesystem must remain a seekable debian.bin while it is mounted
#    and modified above, but there is no reason to write an assembled raw .img
#    only to read it again for compression.
# ------------------------------------------------------------
OUT_GZ="$OUT_DIR/bpi-zero-wbuild-$VERSION-bpi-m2-zero.img.gz"
TMP_GZ="$OUT_GZ.tmp.$$"
RAW_IMAGE_BYTES=$(( $(stat -c %s boot_patched.bin) + $(stat -c %s bpiwbuild-config.fat32) + $(stat -c %s debian.bin) ))
log "streaming final card image directly to $(basename "$OUT_GZ")"
log "logical uncompressed image size: $RAW_IMAGE_BYTES bytes"
rm -f "$TMP_GZ"
trap 'rm -f "$TMP_GZ"' EXIT
cat boot_patched.bin bpiwbuild-config.fat32 debian.bin | gzip -6 > "$TMP_GZ"
gzip -t "$TMP_GZ"
mv -f "$TMP_GZ" "$OUT_GZ"
trap - EXIT
(
    cd "$OUT_DIR"
    sha256sum "$(basename "$OUT_GZ")" > "$(basename "$OUT_GZ").sha256"
)

log "done"
ls -la "$OUT_DIR"
cat "$OUT_GZ.sha256"
