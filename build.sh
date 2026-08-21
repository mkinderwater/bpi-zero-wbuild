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
# Requirements: bash, python3, ar, tar, curl or wget, gzip, unzip,
# ca-certificates (usable /etc/ssl/certs/ca-certificates.crt).
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
VERSION="${BPI_ZERO_CLOCK_VERSION:-1.0.4-preview36}"

: "${BOOT_URL:=https://dl.sd-card-images.johang.se/boots/2026-08-01/boot-banana_pi_m2_zero.bin.gz}"
: "${DEBIAN_URL:=https://dl.sd-card-images.johang.se/debians/2026-08-17/debian-trixie-armhf-eiy3bo.bin.gz}"
DEBIAN_GZIP_SHA256="8cca0fed789a76fef8fb7c8c18bf46ed4d362f9e84d91ffecfe6674e9713c94f"
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
command -v fdtput >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v depmod >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v modinfo >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v e2fsck >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v tune2fs >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v unzip >/dev/null 2>&1 || MISSING_HOST_PKGS+=(unzip)
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
[ "$(sha256sum debian.bin.gz | awk '{print $1}')" = "$DEBIAN_GZIP_SHA256" ] || {
    echo "ERROR: Debian root image SHA256 mismatch." >&2
    echo "       Expected: $DEBIAN_GZIP_SHA256" >&2
    echo "       Actual:   $(sha256sum debian.bin.gz | awk '{print $1}')" >&2
    exit 1
}
log "Debian root image SHA256 verified"

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

cp -f pkgroot/* "$MNT/root/"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/etc"

cp -f "$HERE/overlay/root/bpi-zero-wbuild-firstboot.service" \
    "$MNT/etc/systemd/system/bpi-zero-wbuild-firstboot.service"

# Field diagnostics are image-owned and remain available even if firstboot fails.
mkdir -p "$MNT/usr/local/sbin" "$MNT/etc/issue.d"
install -m 0755 "$HERE/overlay/usr/local/sbin/bpi-zero-diag" \
    "$MNT/usr/local/sbin/bpi-zero-diag"
printf '%s\n' 'bpi-zero-clock \n' 'wlan0 IPv4: \4{wlan0}' \
    >"$MNT/etc/issue.d/90-bpi-zero-clock.conf"

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

# ------------------------------------------------------------
# Clock hardware layer: playback-only MAX98357A on Debian 6.12.101.
# The codec source and hardware topology are the proven 1.0.3 playback path,
# rebuilt for the exact new kernel ABI. The DTB is patched from the stock
# 6.12.101 Banana Pi DTB so unrelated upstream DT changes are retained.
# ------------------------------------------------------------
EXPECTED_ABI="6.12.101+deb13-armmp"
CLOCK_DTB_NAME="sun8i-h2-plus-bananapi-m2-zero.dtb"
STOCK_DTB="$MNT/usr/lib/linux-image-$KERNEL_ABI/$CLOCK_DTB_NAME"
CLOCK_BUILD_DIR="$WORK_DIR/clock-playback"
CLOCK_DTB_BUILD="$CLOCK_BUILD_DIR/$CLOCK_DTB_NAME"
MAX98357A_BUILD_DIR="$CLOCK_BUILD_DIR/max98357a"

[ "$KERNEL_ABI" = "$EXPECTED_ABI" ] || {
    echo "ERROR: bpi-zero-clock $VERSION requires kernel ABI $EXPECTED_ABI." >&2
    echo "       Image kernel ABI is $KERNEL_ABI." >&2
    exit 1
}
[ -s "$STOCK_DTB" ] || {
    echo "ERROR: stock 6.12.101 Banana Pi DTB missing: ${STOCK_DTB#$MNT}" >&2
    exit 1
}

rm -rf "$CLOCK_BUILD_DIR"
mkdir -p "$CLOCK_BUILD_DIR" "$MAX98357A_BUILD_DIR"

log "patching stock 6.12.101 DTB for playback-only clock hardware"
"$HERE/scripts/patch_playback_dtb.sh" "$STOCK_DTB" "$CLOCK_DTB_BUILD"
DTB_SHA256="$(sha256sum "$CLOCK_DTB_BUILD" | awk '{print $1}')"

log "building MAX98357A codec module for $KERNEL_ABI"
MK_MAX98357A_BUILD_OUT="$MAX98357A_BUILD_DIR" \
    "$HERE/scripts/build_max98357a_module.sh"
MAX98357A_KO="$MAX98357A_BUILD_DIR/snd-soc-max98357a.ko"
[ -s "$MAX98357A_KO" ] || { echo "ERROR: MAX98357A build output missing." >&2; exit 1; }
MODULE_SHA256="$(sha256sum "$MAX98357A_KO" | awk '{print $1}')"
MODULE_VERMAGIC="$(modinfo -F vermagic "$MAX98357A_KO" 2>/dev/null | awk '{print $1}')"
[ "$MODULE_VERMAGIC" = "$KERNEL_ABI" ] || {
    echo "ERROR: MAX98357A vermagic '$MODULE_VERMAGIC' != '$KERNEL_ABI'." >&2
    exit 1
}
[ "$(modinfo -F name "$MAX98357A_KO" 2>/dev/null)" = "snd_soc_max98357a" ] || {
    echo "ERROR: unexpected MAX98357A module name." >&2
    exit 1
}
modinfo -F alias "$MAX98357A_KO" 2>/dev/null | grep -q 'maxim,max98357a' || {
    echo "ERROR: MAX98357A module lacks maxim,max98357a OF alias." >&2
    exit 1
}

[ "$(fdtget -t s "$CLOCK_DTB_BUILD" /max98357a compatible)" = "maxim,max98357a" ]
[ "$(fdtget -t x "$CLOCK_DTB_BUILD" /max98357a sdmode-delay)" = "5" ]
[ "$(fdtget -t s "$CLOCK_DTB_BUILD" /sound-max98357a simple-audio-card,name)" = "MAX98357A" ]
[ "$(fdtget -t x "$CLOCK_DTB_BUILD" /sound-max98357a simple-audio-card,mclk-fs)" = "100" ]
I2S_PINS="$(fdtget -t s "$CLOCK_DTB_BUILD" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins pins)"
[ "$I2S_PINS" = "PA18 PA19 PA20" ] || {
    echo "ERROR: playback I2S pin set is '$I2S_PINS', expected PA18 PA19 PA20." >&2
    exit 1
}
DT_DTS="$(dtc -I dtb -O dts "$CLOCK_DTB_BUILD" 2>/dev/null)"
printf '%s\n' "$DT_DTS" | grep -q 'maxim,max98357a'
! printf '%s\n' "$DT_DTS" | grep -q 'dmic-codec'
! printf '%s\n' "$DT_DTS" | grep -q 'icubedev,capture-rate-hz'
! printf '%s\n' "$DT_DTS" | grep -q 'PA21'
! printf '%s\n' "$DT_DTS" | grep -q 'linux,spdif-dit'

CLOCK_DTB_OUT="$MNT/usr/lib/firmware/$KERNEL_ABI/device-tree/$CLOCK_DTB_NAME"
CLOCK_DTB_BOOT="$MNT/usr/lib/linux-image-$KERNEL_ABI/$CLOCK_DTB_NAME"
mkdir -p "$(dirname "$CLOCK_DTB_OUT")" \
             "$MNT/lib/modules/$KERNEL_ABI/extra" \
             "$MNT/etc/modules-load.d" \
             "$MNT/usr/local/sbin" \
             "$MNT/etc/systemd/system/multi-user.target.wants" \
             "$MNT/etc/systemd/system/local-fs.target.wants" \
             "$MNT/etc/systemd/journald.conf.d" \
             "$MNT/etc/systemd/system.conf.d" \
             "$MNT/etc/apt/preferences.d"

# extlinux loads the DTB from /usr/lib/linux-image-$ABI; keep the firmware copy
# too because diagnostics and the application verifier use it as a stable path.
install -m 0644 "$CLOCK_DTB_BUILD" "$CLOCK_DTB_BOOT"
install -m 0644 "$CLOCK_DTB_BUILD" "$CLOCK_DTB_OUT"
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

# Native ALSA default routing for playback only. No capture PCM, plug, rate
# conversion, dmix or dsnoop is introduced.
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

# Appliance boot policy. The 2026-08-17 Debian rootfs uses U-Boot extlinux,
# not the old boot.cmd/boot.scr path. Pin root to our final MBR partition 2,
# keep the console quiet, and eliminate the interactive five-second boot menu.
EXTLINUX_CONF="$MNT/boot/extlinux/extlinux.conf"
U_BOOT_DEFAULTS="$MNT/etc/default/u-boot"
[ -s "$EXTLINUX_CONF" ] || { echo "ERROR: extlinux.conf missing from new Debian rootfs." >&2; exit 1; }
ROOT_PARTUUID="$(python3 "$HERE/scripts/mbr_partuuid.py" boot.bin --partition 2)"
python3 "$HERE/scripts/set_extlinux_policy.py" \
    "$EXTLINUX_CONF" "$U_BOOT_DEFAULTS" --partuuid "$ROOT_PARTUUID"
grep -Eq "^[[:space:]]*append root=PARTUUID=${ROOT_PARTUUID}[[:space:]]+rw[[:space:]]+rootwait[[:space:]]+quiet[[:space:]]+loglevel=4$" "$EXTLINUX_CONF" || {
    echo "ERROR: extlinux root/quiet policy was not applied." >&2
    exit 1
}
grep -Eq '^prompt[[:space:]]+0$' "$EXTLINUX_CONF"
grep -Eq '^timeout[[:space:]]+10$' "$EXTLINUX_CONF"

# Playback-only release: retain Debian stock I2S/simple-card and install only
# the MAX98357A codec rebuilt for this exact kernel ABI.
depmod -b "$MNT" "$KERNEL_ABI"

validate_module_resolution() {
    local mod="$1"
    local expected="${2:-}"
    local resolved
    resolved="$(modinfo -b "$MNT" -k "$KERNEL_ABI" -n "$mod" 2>/dev/null || true)"
    [ -n "$resolved" ] || { echo "ERROR: target kernel cannot resolve $mod." >&2; exit 1; }
    if [ -n "$expected" ] && [ "$resolved" != "$expected" ]; then
        echo "ERROR: depmod index resolved $mod to '$resolved', expected '$expected'." >&2
        exit 1
    fi
    modprobe -d "$MNT" -S "$KERNEL_ABI" -n "$mod" >/dev/null 2>&1 || {
        echo "ERROR: target kernel cannot resolve $mod or dependencies." >&2
        exit 1
    }
    echo ">> module resolution OK: $mod -> ${resolved#$MNT}"
}

validate_module_resolution snd-soc-max98357a "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"
validate_module_resolution sun4i-i2s
validate_module_resolution snd-soc-simple-card

# Capture must not be preloaded or image-owned in the playback-only release.
! grep -q '^snd-soc-dmic$' "$MNT/etc/modules-load.d/bpi-zero-clock.conf"
[ "$(sha256sum "$CLOCK_DTB_OUT" | awk '{print $1}')" = "$DTB_SHA256" ]
[ "$(sha256sum "$CLOCK_DTB_BOOT" | awk '{print $1}')" = "$DTB_SHA256" ]
[ "$(sha256sum "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko" | awk '{print $1}')" = "$MODULE_SHA256" ]

cat >"$MNT/etc/bpi-zero-clock-release" <<EOF_RELEASE
PRODUCT=bpi-zero-clock
VERSION=$VERSION
BASE_PRODUCT=bpi-zero-wbuild
BASE_VERSION=1.2.7
TARGET=bpi-m2-zero
SSH_CLIENT_LOCALE_FORWARDING=disabled
LOCALE_PACKAGES=not-installed
KERNEL_ABI=$KERNEL_ABI
CLOCK_HARDWARE=bpi-m2-zero-r1
CLOCK_DTB=$CLOCK_DTB_NAME
AUDIO_ENDPOINT=MAX98357A
AUDIO_MODE=playback-only
AUDIO_CODEC_DRIVER=snd-soc-max98357a
AUDIO_CODEC_COMPATIBLE=maxim,max98357a
AUDIO_DRIVER_SOURCE=hardware-validated-source-rebuilt-for-6.12.101
MAX98357A_MODULE=/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko
MAX98357A_MODULE_SHA256=$MODULE_SHA256
MAX98357A_DTB_SHA256=$DTB_SHA256
MAX98357A_VERMAGIC=$MODULE_VERMAGIC
MAX98357A_SD_CONTROL=codec-driver-pcm-trigger
MAX98357A_SD_GPIO=PA1
MAX98357A_SD_IDLE=low
MAX98357A_SD_DELAY_MS=5
MAX98357A_MCLK_FS=256
AUDIO_CAPTURE=removed
APPLICATION_AUDIO_BASELINE=mk-clock-adult-2.3.50-preview34
I2S_LRCLK_GPIO=PA18
I2S_BCLK_GPIO=PA19
I2S_TX_GPIO=PA20
I2S_RX_GPIO=unassigned
I2S_RX_HEADER_PIN=38-free
TOUCH_GPIO=PA17
TOUCH_HEADER_PIN=37
AUDIO_VALIDATION=playback-topology-hardware-confirmed-on-6.12.100-kernel-6.12.101-target-validation-required
LEGACY_SPDIF_CODEC=removed
LEGACY_AMP_GATE=removed
LEGACY_AMP_GATE_FILES=absent-verified
KERNEL_BOOT_QUIET=yes
KERNEL_CONSOLE_LOGLEVEL=4
JOURNAL_STORAGE=volatile
JOURNAL_RUNTIME_MAX_USE=16M
TMP_MOUNT=tmpfs-64M
SYSTEMD_RUNTIME_WATCHDOG_SEC=16s
SYSTEMD_REBOOT_WATCHDOG_SEC=16s
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
FIELD_DIAGNOSTICS=bpi-zero-diag
LOGIN_IPV4_DISPLAY=agetty-issue-wlan0
CPU_DIAGNOSTIC_POLICY=observe-no-governor-or-opp-change
MACHINE_ID_POLICY=firstboot-systemd-machine-id-setup
DEBCONF_FRONTEND_POLICY=persistent-Noninteractive-after-DHCP
EOF_RELEASE
chmod 0644 "$MNT/etc/bpi-zero-clock-release"

cat >"$MNT/etc/bpi-zero-wbuild-release" <<EOF_BASE_RELEASE
PRODUCT=bpi-zero-wbuild
VERSION=1.2.7
TARGET=bpi-m2-zero
BASE=debian-trixie-armhf-eiy3bo
KERNEL_ABI=$KERNEL_ABI
WIFI_FIRMWARE_SOURCE=Debian-firmware-brcm80211-20250410-2
WIFI_FIRMWARE_INSTALL=image-build-direct
BLUETOOTH_FIRMWARE_SOURCE=$BT_FIRMWARE_SOURCE
BLUETOOTH_FIRMWARE_PATH=brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd
BLUETOOTH_USERSPACE=application-owned
HARDWARE_CONFIGURATION=clock-image-owned
NETWORK_IPV4_VERIFIER=iproute2
FIELD_DIAGNOSTICS=bpi-zero-diag
LOGIN_IPV4_DISPLAY=agetty-issue-wlan0
CPU_DIAGNOSTIC_POLICY=observe-no-governor-or-opp-change
CLI_NETWORK_TOOL=iproute2-6.15.0-1
CLI_WIFI_TOOL=iw-6.9-1
WIFI_POWER_SAVE_POLICY=iwd-DriverQuirks-PowerSaveDisable-brcmfmac
FIRSTBOOT_RESUME=checkpointed
WIFI_RECOVERY_RETRY=one-controlled-radio-userspace-restart
ROOT_RESIZE_MODE=firstboot-online-resize2fs-fail-closed
ROOT_RESIZE_ORDER=before-network
ROOT_FS_BUILD_VALIDATION=e2fsck-read-only-clean-required
MACHINE_ID_POLICY=firstboot-systemd-machine-id-setup
DEBCONF_FRONTEND_POLICY=persistent-Noninteractive-after-DHCP
ROOT_FS_REPAIR=none
FIRSTBOOT_REBOOT=none
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
