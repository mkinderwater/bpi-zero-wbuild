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
VERSION="${BPI_ZERO_CLOCK_VERSION:-1.0.4-preview25}"

: "${BOOT_URL:=https://dl.sd-card-images.johang.se/boots/2026-08-01/boot-banana_pi_m2_zero.bin.gz}"
: "${DEBIAN_URL:=https://dl.sd-card-images.johang.se/debians/2026-08-03/debian-trixie-armhf-ner4uz.bin.gz}"
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
: "${ALSA_UTILS_DEB_URL:=https://deb.debian.org/debian/pool/main/a/alsa-utils/alsa-utils_1.2.14-1_armhf.deb}"
: "${LIBASOUND2_DATA_DEB_URL:=https://deb.debian.org/debian/pool/main/a/alsa-lib/libasound2-data_1.2.14-1_all.deb}"
: "${LIBASOUND2_DEB_URL:=https://deb.debian.org/debian/pool/main/a/alsa-lib/libasound2t64_1.2.14-1_armhf.deb}"
: "${LIBATOPOLOGY2_DEB_URL:=https://deb.debian.org/debian/pool/main/a/alsa-lib/libatopology2t64_1.2.14-1_armhf.deb}"
: "${LIBFFTW3_SINGLE_DEB_URL:=https://deb.debian.org/debian/pool/main/f/fftw3/libfftw3-single3_3.3.10-2+b1_armhf.deb}"
: "${GCC14_BASE_DEB_URL:=https://deb.debian.org/debian/pool/main/g/gcc-14/gcc-14-base_14.2.0-19_armhf.deb}"
: "${LIBGOMP1_DEB_URL:=https://deb.debian.org/debian/pool/main/g/gcc-14/libgomp1_14.2.0-19_armhf.deb}"
: "${LIBNCURSESW6_DEB_URL:=https://deb.debian.org/debian/pool/main/n/ncurses/libncursesw6_6.5+20250216-2_armhf.deb}"
: "${LIBTINFO6_DEB_URL:=https://deb.debian.org/debian/pool/main/n/ncurses/libtinfo6_6.5+20250216-2_armhf.deb}"
: "${LIBSAMPLERATE_DEB_URL:=https://deb.debian.org/debian/pool/main/libs/libsamplerate/libsamplerate0_0.2.2-4+b2_armhf.deb}"
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
command -v ar >/dev/null 2>&1 || MISSING_HOST_PKGS+=(binutils)
command -v tar >/dev/null 2>&1 || MISSING_HOST_PKGS+=(tar)
command -v gzip >/dev/null 2>&1 || MISSING_HOST_PKGS+=(gzip)
command -v xz >/dev/null 2>&1 || MISSING_HOST_PKGS+=(xz-utils)
command -v dtc >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v fdtget >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v depmod >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v modinfo >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v e2fsck >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v tune2fs >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v mkimage >/dev/null 2>&1 || MISSING_HOST_PKGS+=(u-boot-tools)
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    MISSING_HOST_PKGS+=(curl)
fi

if [ "${#MISSING_HOST_PKGS[@]}" -gt 0 ]; then
    log "installing missing host dependencies: ${MISSING_HOST_PKGS[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        apt-get install -y --no-install-recommends "${MISSING_HOST_PKGS[@]}"
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

# Fetch a gzip payload and verify the entire compressed stream before it is
# accepted. curl/wget can successfully return a truncated/corrupt HTTP 200
# payload, and the URL cache alone cannot detect that. A failed integrity check
# invalidates both the payload and its source-url marker so the next attempt is
# guaranteed to perform a fresh download rather than reusing poisoned cache.
fetch_gzip() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        fetch "$url" "$dest"
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
fetch "$LIBASOUND2_DATA_DEB_URL" pkgroot/libasound2-data_1.2.14-1_all.deb
fetch "$LIBASOUND2_DEB_URL" pkgroot/libasound2t64_1.2.14-1_armhf.deb
fetch "$LIBATOPOLOGY2_DEB_URL" pkgroot/libatopology2t64_1.2.14-1_armhf.deb
fetch "$GCC14_BASE_DEB_URL" pkgroot/gcc-14-base_14.2.0-19_armhf.deb
fetch "$LIBGOMP1_DEB_URL" pkgroot/libgomp1_14.2.0-19_armhf.deb
fetch "$LIBFFTW3_SINGLE_DEB_URL" 'pkgroot/libfftw3-single3_3.3.10-2+b1_armhf.deb'
fetch "$LIBTINFO6_DEB_URL" 'pkgroot/libtinfo6_6.5+20250216-2_armhf.deb'
fetch "$LIBNCURSESW6_DEB_URL" 'pkgroot/libncursesw6_6.5+20250216-2_armhf.deb'
fetch "$LIBSAMPLERATE_DEB_URL" 'pkgroot/libsamplerate0_0.2.2-4+b2_armhf.deb'
fetch "$ALSA_UTILS_DEB_URL" pkgroot/alsa-utils_1.2.14-1_armhf.deb

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
# 3. Stage the overlay into pkgroot
# ------------------------------------------------------------
# Stage the one-shot firstboot helper, explicitly excluding obsolete runtime
# Bluetooth and historical resize-repair helpers from older source trees.
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
# Clock hardware layer: immutable preview audio artifacts for the exact
# Debian kernel ABI. MAX98357A playback remains the physically validated
# 1.0.3 path; this preview DTB adds PA21 I2S DIN and an ICS-43434 capture
# endpoint for target validation. Deployed clocks never patch Device Tree.
# ------------------------------------------------------------
VALIDATED_ABI="6.12.100+deb13-armmp"
VALIDATED_MODULE_SHA256="906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6"
VALIDATED_DTB_SHA256="0ff283cc75acd93a43722769e3d9771dcb5d629825348593fdd4da605e4b1452"
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
[ "$(fdtget -t s "$VALIDATED_DTB" /dmic-codec compatible)" = "dmic-codec" ]
[ "$(fdtget -t x "$VALIDATED_DTB" /dmic-codec num-channels)" = "2" ]
[ "$(fdtget -t x "$VALIDATED_DTB" /sound-max98357a icubedev,capture-rate-hz)" = "5dc0" ]
[ "$(fdtget -t x "$VALIDATED_DTB" '/sound-max98357a/simple-audio-card,dai-link@0' mclk-fs)" = "100" ]
[ "$(fdtget -t x "$VALIDATED_DTB" '/sound-max98357a/simple-audio-card,dai-link@1' mclk-fs)" = "100" ]
[ "$(fdtget -t x "$VALIDATED_DTB" '/sound-max98357a/simple-audio-card,dai-link@0' reg)" = "0" ]
[ "$(fdtget -t x "$VALIDATED_DTB" '/sound-max98357a/simple-audio-card,dai-link@1' reg)" = "1" ]
I2S_PINS="$(fdtget -t s "$VALIDATED_DTB" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins pins)"
[ "$I2S_PINS" = "PA18 PA19 PA20 PA21" ] || {
    echo "ERROR: preview I2S pin set is '$I2S_PINS', expected PA18 PA19 PA20 PA21." >&2
    exit 1
}
! dtc -I dtb -O dts "$VALIDATED_DTB" 2>/dev/null | grep -q 'linux,spdif-dit'
! dtc -I dtb -O dts "$VALIDATED_DTB" 2>/dev/null | grep -q 'mk-piclock-max98357a-enable-hog'

CLOCK_DTB_OUT="$MNT/usr/lib/firmware/$KERNEL_ABI/device-tree/$CLOCK_DTB_NAME"
mkdir -p "$(dirname "$CLOCK_DTB_OUT")" \
             "$MNT/lib/modules/$KERNEL_ABI/extra" \
             "$MNT/etc/modules-load.d" \
             "$MNT/usr/local/sbin" \
             "$MNT/etc/systemd/system/multi-user.target.wants" \
             "$MNT/etc/systemd/system/local-fs.target.wants" \
             "$MNT/etc/systemd/journald.conf.d" \
             "$MNT/etc/systemd/system.conf.d" \
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

install -m 0644 "$HERE/clock/hardware/bpi-zero-clock.modules" \
    "$MNT/etc/modules-load.d/bpi-zero-clock.conf"

install -m 0755 "$HERE/clock/hardware/mk-piclock-bind-spidev" \
    "$MNT/usr/local/sbin/mk-piclock-bind-spidev"
install -m 0644 "$HERE/clock/hardware/mk-piclock-spidev.service" \
    "$MNT/etc/systemd/system/mk-piclock-spidev.service"
ln -sfn ../mk-piclock-spidev.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/mk-piclock-spidev.service"

# Native ALSA default routing for the two-link sound card. The asym plugin
# selects hardware PCMs only; no plug/rate conversion is introduced.
install -m 0644 "$HERE/clock/hardware/asound.conf" "$MNT/etc/asound.conf"

# 24/7 appliance endurance/recovery policy. Journald is explicitly volatile and
# bounded; /tmp is a bounded tmpfs. /var/log itself remains persistent for the
# small number of explicit one-shot/service logs that are useful after reboot.
install -m 0644 "$HERE/clock/hardware/journald-volatile.conf" \
    "$MNT/etc/systemd/journald.conf.d/20-mk-clock-volatile.conf"
install -m 0644 "$HERE/clock/hardware/system-watchdog.conf" \
    "$MNT/etc/systemd/system.conf.d/20-mk-clock-watchdog.conf"
install -m 0644 "$HERE/clock/hardware/tmp.mount" \
    "$MNT/etc/systemd/system/tmp.mount"
ln -sfn ../tmp.mount "$MNT/etc/systemd/system/local-fs.target.wants/tmp.mount"
# Never ship a stale persistent journal copied from the Debian build root.
rm -rf "$MNT/var/log/journal"

install -m 0644 "$HERE/clock/kernel-pin.pref" \
    "$MNT/etc/apt/preferences.d/bpi-zero-clock-kernel.pref"

# Lean SSH locale policy. Debian's stock sshd_config accepts LANG/LC_* from
# clients. This minimal appliance intentionally does not install generated locale
# data, so remove only those AcceptEnv patterns at image-build time. TERM remains
# protocol-managed by OpenSSH and unrelated AcceptEnv entries are preserved.
python3 "$HERE/scripts/disable_ssh_locale_forwarding.py" --root "$MNT"

# Appliance boot-console policy. The upstream Debian rootfs boots through
# /boot/boot.scr generated from /boot/boot.cmd. Patch the active command and
# its initramfs post-update generator so future kernel updates retain the same
# quiet kernel policy, then rebuild boot.scr immediately for this image.
BOOT_CMD="$MNT/boot/boot.cmd"
BOOT_SCR="$MNT/boot/boot.scr"
BOOT_UPDATE_HOOK="$MNT/etc/initramfs/post-update.d/zz-update-uimg"
for f in "$BOOT_CMD" "$BOOT_UPDATE_HOOK"; do
    [ -s "$f" ] || { echo "ERROR: required boot policy file missing: ${f#$MNT}" >&2; exit 1; }
done
python3 "$HERE/scripts/set_boot_loglevel.py" "$BOOT_CMD" "$BOOT_UPDATE_HOOK"
mkimage -A arm -T script -C none -d "$BOOT_CMD" "$BOOT_SCR" >/dev/null
chmod 0644 "$BOOT_SCR"
grep -Eq '^setenv[[:space:]]+bootargs[[:space:]]+quiet[[:space:]]+loglevel=3([[:space:]]|$)' "$BOOT_CMD" || {
    echo "ERROR: quiet loglevel=3 not present in active boot command." >&2
    exit 1
}

# Build the capture stack from exact Debian 6.12.100-1 source and headers.
# There is no binary module editing in this release. The source patch set:
#   1. adds the already-supported 24 kHz bit to sun4i-i2s capture only;
#   2. keeps generic dmic.c unmodified;
#   3. adds a local simple-card capture constraint keyed by the DT property.
AUDIO_MODULE_OUT="$WORK_DIR/audio-modules"
MK_AUDIO_BUILD_WORK="$WORK_DIR/audio-source" \
MK_AUDIO_BUILD_OUT="$AUDIO_MODULE_OUT" \
    "$HERE/scripts/build_audio_modules.sh"

I2S_KO="$(find "$MNT/lib/modules/$KERNEL_ABI" -type f -name 'sun4i-i2s.ko.xz' -print -quit)"
SIMPLE_CARD_KO="$(find "$MNT/lib/modules/$KERNEL_ABI" -type f -name 'snd-soc-simple-card.ko.xz' -print -quit)"
for f in "$I2S_KO" "$SIMPLE_CARD_KO"; do
    [ -s "$f" ] || { echo "ERROR: required stock ASoC module missing: $f" >&2; exit 1; }
done

KERNEL_CONFIG="$MNT/boot/config-$KERNEL_ABI"
[ -s "$KERNEL_CONFIG" ] || { echo "ERROR: target kernel config missing: $KERNEL_CONFIG" >&2; exit 1; }
grep -qx '# CONFIG_MODULE_SIG_FORCE is not set' "$KERNEL_CONFIG" || {
    echo "ERROR: target kernel enforces signed modules; local source-built modules cannot be used." >&2
    exit 1
}

# Source-built replacements are unsigned and use the exact target Module.symvers.
# Replace the two existing modules in place so modprobe cannot resolve a stale copy.
install -m 0644 "$AUDIO_MODULE_OUT/sun4i-i2s.ko.xz" "$I2S_KO"
install -m 0644 "$AUDIO_MODULE_OUT/snd-soc-simple-card.ko.xz" "$SIMPLE_CARD_KO"
DMIC_KO="$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-dmic.ko.xz"
install -m 0644 "$AUDIO_MODULE_OUT/snd-soc-dmic.ko.xz" "$DMIC_KO"

I2S_MODULE_SHA256="$(sha256sum "$I2S_KO" | awk '{print $1}')"
DMIC_MODULE_SHA256="$(sha256sum "$DMIC_KO" | awk '{print $1}')"
SIMPLE_CARD_MODULE_SHA256="$(sha256sum "$SIMPLE_CARD_KO" | awk '{print $1}')"

depmod -b "$MNT" "$KERNEL_ABI"

# Validate the depmod index resolves each appliance module to the exact file we
# installed, then ask modprobe to validate that the module plus its dependencies
# are resolvable. Do not parse `modprobe -n` stdout: it is intentionally silent
# unless verbose mode is requested.
validate_module_resolution() {
    local mod="$1"
    local expected="$2"
    local resolved

    resolved="$(modinfo -b "$MNT" -k "$KERNEL_ABI" -n "$mod" 2>/dev/null || true)"
    if [ "$resolved" != "$expected" ]; then
        echo "ERROR: depmod index resolved $mod to '${resolved:-<none>}', expected '$expected'." >&2
        exit 1
    fi

    if ! modprobe -d "$MNT" -S "$KERNEL_ABI" -n "$mod" >/dev/null 2>&1; then
        echo "ERROR: target kernel cannot resolve $mod or one of its dependencies." >&2
        exit 1
    fi

    echo ">> module resolution OK: $mod -> ${expected#$MNT}"
}

validate_module_resolution snd-soc-max98357a     "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"
validate_module_resolution sun4i-i2s "$I2S_KO"
validate_module_resolution snd-soc-dmic "$DMIC_KO"
validate_module_resolution snd-soc-simple-card "$SIMPLE_CARD_KO"

[ "$(sha256sum "$CLOCK_DTB_OUT" | awk '{print $1}')" = "$VALIDATED_DTB_SHA256" ]
[ "$(sha256sum "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko" | awk '{print $1}')" = "$VALIDATED_MODULE_SHA256" ]

cat >"$MNT/etc/bpi-zero-clock-release" <<EOF_RELEASE
PRODUCT=bpi-zero-clock
VERSION=$VERSION
BASE_PRODUCT=bpi-zero-wbuild
BASE_VERSION=1.2.6
TARGET=bpi-m2-zero
SSH_CLIENT_LOCALE_FORWARDING=disabled
LOCALE_PACKAGES=not-installed
KERNEL_ABI=$KERNEL_ABI
CLOCK_HARDWARE=bpi-m2-zero-r1
CLOCK_DTB=$CLOCK_DTB_NAME
AUDIO_ENDPOINT=MAX98357A
AUDIO_CODEC_DRIVER=snd-soc-max98357a
AUDIO_CODEC_COMPATIBLE=maxim,max98357a
AUDIO_DRIVER_SOURCE=playback-validated-capture-source-built-clock-dma-hardware-confirmed
MAX98357A_MODULE=/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko
MAX98357A_MODULE_SHA256=$VALIDATED_MODULE_SHA256
MAX98357A_DTB_SHA256=$VALIDATED_DTB_SHA256
MAX98357A_VERMAGIC=$MODULE_VERMAGIC
MAX98357A_SD_CONTROL=codec-driver-pcm-trigger
MAX98357A_SD_GPIO=PA1
MAX98357A_SD_IDLE=low
MAX98357A_SD_DELAY_MS=5
MAX98357A_MCLK_FS=256
AUDIO_CAPTURE_ENDPOINT=ICS-43434
AUDIO_CAPTURE_CODEC=dmic-codec
AUDIO_CAPTURE_DRIVER=snd-soc-dmic
AUDIO_CAPTURE_DRIVER_SOURCE=debian-6.12.100-1-unmodified-dmic-source
AUDIO_CAPTURE_MODULE=${DMIC_KO#$MNT}
AUDIO_CAPTURE_MODULE_SHA256=$DMIC_MODULE_SHA256
AUDIO_CAPTURE_FORMAT=S32_LE
AUDIO_CAPTURE_RATE_HZ=24000
AUDIO_CAPTURE_CHANNELS=2
AUDIO_CAPTURE_SLOT_WIDTH_BITS=32
AUDIO_CAPTURE_MCLK_FS=256
AUDIO_CAPTURE_SOFT_RESAMPLE=disabled
AUDIO_CAPTURE_DEFAULT_PCM=default-asym-to-hw-MAX98357A-device1
I2S_DRIVER=sun4i-i2s
I2S_DRIVER_SOURCE=debian-6.12.100-1-plus-capture-24khz-capability-patch
I2S_MODULE=${I2S_KO#$MNT}
I2S_MODULE_SHA256=$I2S_MODULE_SHA256
MACHINE_AUDIO_DRIVER=snd-soc-simple-card
MACHINE_AUDIO_DRIVER_SOURCE=debian-6.12.100-1-plus-local-capture-rate-policy-patch
MACHINE_AUDIO_MODULE=${SIMPLE_CARD_KO#$MNT}
MACHINE_AUDIO_MODULE_SHA256=$SIMPLE_CARD_MODULE_SHA256
MACHINE_CAPTURE_POLICY=snd_pcm_hw_constraint_list
MACHINE_CAPTURE_RATE_HZ=24000
MACHINE_CAPTURE_DT_PROPERTY=icubedev,capture-rate-hz
APPLICATION_AUDIO_BASELINE=mk-clock-adult-2.3.50-preview25
I2S_LRCLK_GPIO=PA18
I2S_BCLK_GPIO=PA19
I2S_TX_GPIO=PA20
I2S_RX_GPIO=PA21
MIC_DATA_GPIO=PA21
MIC_HEADER_PIN=38
TOUCH_GPIO=PA17
TOUCH_HEADER_PIN=37
AUDIO_CAPTURE_VALIDATION=clock-dma-hardware-confirmed-24khz-mic-signal-pending
AUDIO_VALIDATION=silence-tone-silence-clean-no-pop-no-tail-hiss
LEGACY_SPDIF_CODEC=removed
LEGACY_AMP_GATE=removed
LEGACY_AMP_GATE_FILES=absent-verified
KERNEL_BOOT_QUIET=yes
KERNEL_CONSOLE_LOGLEVEL=3
JOURNAL_STORAGE=volatile
JOURNAL_RUNTIME_MAX_USE=16M
TMP_MOUNT=tmpfs-64M
SYSTEMD_RUNTIME_WATCHDOG_SEC=30s
SYSTEMD_REBOOT_WATCHDOG_SEC=2min
SPI_DEVICE=/dev/spidev0.0
I2C_DEVICE=/dev/i2c-0
HARDWARE_CONFIGURATION=image-owned
KERNEL_UPDATE_POLICY=image-release-owned-exact-abi-pinned
CLI_NETWORK_TOOL=iproute2-6.15.0-1
CLI_WIFI_TOOL=iw-6.9-1
ALSA_UTILS=alsa-utils-1.2.14-1
ALSA_FIELD_TOOLS=aplay-arecord-amixer-alsactl-speaker-test
ALSA_STATE_RESTORE=disabled-image-policy
WIFI_POWER_SAVE_POLICY=iwd-DriverQuirks-PowerSaveDisable-brcmfmac
FIRSTBOOT_RESUME=checkpointed
WIFI_RECOVERY_RETRY=one-controlled-radio-userspace-restart
FIRSTBOOT_CONSOLE_LOGGING=stage-summary
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
NETWORK_IPV4_VERIFIER=iproute2
CLI_NETWORK_TOOL=iproute2-6.15.0-1
CLI_WIFI_TOOL=iw-6.9-1
WIFI_POWER_SAVE_POLICY=iwd-DriverQuirks-PowerSaveDisable-brcmfmac
FIRSTBOOT_RESUME=checkpointed
WIFI_RECOVERY_RETRY=one-controlled-radio-userspace-restart
ROOT_RESIZE_MODE=firstboot-online-resize2fs-fail-closed
ROOT_RESIZE_ORDER=before-network
ROOT_FS_BUILD_VALIDATION=e2fsck-read-only-clean-required
ROOT_FS_REPAIR=none
FIRSTBOOT_REBOOT=none
EOF_BASE_RELEASE
chmod 0644 "$MNT/etc/bpi-zero-wbuild-release"

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
