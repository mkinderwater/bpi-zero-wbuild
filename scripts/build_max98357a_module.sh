#!/usr/bin/env bash
# Build only the MAX98357A codec module for Debian 13 armhf 6.12.101+deb13-armmp.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ABI="6.12.101+deb13-armmp"
DEBIAN_VERSION="6.12.101-1"
COMMON_NAME="linux-headers-6.12.101+deb13-common"
KBUILD_NAME="linux-kbuild-6.12.101+deb13"
SEC_BASE="https://security.debian.org/debian-security/pool/updates/main/l/linux"
SEC_SNAPSHOT="https://snapshot.debian.org/archive/debian-security/20260810T000000Z/pool/updates/main/l/linux"
WORK_DIR="${MK_MAX98357A_BUILD_WORK:-$HERE/build/max98357a-source}"
OUT_DIR="${MK_MAX98357A_BUILD_OUT:-$HERE/build/max98357a-module}"
SOURCE="$HERE/clock/playback/max98357a.c"
SOURCE_SHA256="75b251c2eaa9aa03ae18bea9a1d134308ab8e882bde3f08523ca9f1d55797d54"

[ "$(sha256sum "$SOURCE" | awk '{print $1}')" = "$SOURCE_SHA256" ] || {
    echo "ERROR: MAX98357A source hash mismatch." >&2
    exit 1
}

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$HOST_ARCH" in
    amd64)
        KBUILD_ARCH=amd64
        CC_BIN=arm-linux-gnueabihf-gcc
        CROSS_COMPILE_PREFIX=arm-linux-gnueabihf-
        COMPILER_PACKAGE=gcc-arm-linux-gnueabihf
        ;;
    armhf)
        KBUILD_ARCH=armhf
        CC_BIN=gcc
        CROSS_COMPILE_PREFIX=
        COMPILER_PACKAGE=gcc
        ;;
    *)
        echo "ERROR: supported build hosts are Debian amd64 or armhf; found '$HOST_ARCH'." >&2
        exit 1
        ;;
esac

need=()
command -v curl >/dev/null 2>&1 || need+=(curl)
[ -s /etc/ssl/certs/ca-certificates.crt ] || need+=(ca-certificates)
command -v dpkg-deb >/dev/null 2>&1 || need+=(dpkg)
command -v make >/dev/null 2>&1 || need+=(make)
command -v python3 >/dev/null 2>&1 || need+=(python3)
command -v "$CC_BIN" >/dev/null 2>&1 || need+=("$COMPILER_PACKAGE")
command -v modinfo >/dev/null 2>&1 || need+=(kmod)
if [ "${#need[@]}" -gt 0 ]; then
    [ "$(id -u)" -eq 0 ] || {
        echo "ERROR: missing host packages: ${need[*]}; rerun as root." >&2
        exit 1
    }
    apt-get update
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        apt-get install -y --no-install-recommends "${need[@]}"
fi

if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    update-ca-certificates >/dev/null
fi
[ -s /etc/ssl/certs/ca-certificates.crt ] || {
    echo "ERROR: HTTPS CA certificate bundle unavailable." >&2
    exit 1
}

CC_MAJOR="$("$CC_BIN" -dumpversion | cut -d. -f1)"
[ "$CC_MAJOR" = "14" ] || {
    echo "ERROR: target kernel was built with GCC 14; $CC_BIN reports major $CC_MAJOR." >&2
    exit 1
}

echo ">> MAX98357A build host: $HOST_ARCH ($CC_BIN, kbuild $KBUILD_ARCH)"
rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sdk" "$WORK_DIR/module" "$OUT_DIR"

fetch() {
    local url="$1" out="$2" fallback="${3:-}"
    echo ">> downloading $(basename "$out")"
    if ! curl -fL --retry 3 --retry-delay 1 -o "$out.tmp" "$url"; then
        rm -f "$out.tmp"
        [ -n "$fallback" ] || return 1
        echo ">> primary archive unavailable; using pinned Debian snapshot"
        curl -fL --retry 3 --retry-delay 1 -o "$out.tmp" "$fallback"
    fi
    mv "$out.tmp" "$out"
}

HDR_ARM="$WORK_DIR/downloads/linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb"
HDR_COMMON="$WORK_DIR/downloads/${COMMON_NAME}_${DEBIAN_VERSION}_all.deb"
KBUILD="$WORK_DIR/downloads/${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb"

fetch "$SEC_BASE/linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb" "$HDR_ARM" \
      "$SEC_SNAPSHOT/linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb"
fetch "$SEC_BASE/${COMMON_NAME}_${DEBIAN_VERSION}_all.deb" "$HDR_COMMON" \
      "$SEC_SNAPSHOT/${COMMON_NAME}_${DEBIAN_VERSION}_all.deb"
fetch "$SEC_BASE/${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb" "$KBUILD" \
      "$SEC_SNAPSHOT/${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb"

check_deb() {
    local deb="$1" pkg="$2" ver="$3" arch="$4"
    [ "$(dpkg-deb -f "$deb" Package)" = "$pkg" ]
    [ "$(dpkg-deb -f "$deb" Version)" = "$ver" ]
    [ "$(dpkg-deb -f "$deb" Architecture)" = "$arch" ]
}
check_deb "$HDR_ARM" "linux-headers-$ABI" "$DEBIAN_VERSION" armhf
check_deb "$HDR_COMMON" "$COMMON_NAME" "$DEBIAN_VERSION" all
check_deb "$KBUILD" "$KBUILD_NAME" "$DEBIAN_VERSION" "$KBUILD_ARCH"

dpkg-deb -x "$HDR_COMMON" "$WORK_DIR/sdk"
dpkg-deb -x "$HDR_ARM" "$WORK_DIR/sdk"
dpkg-deb -x "$KBUILD" "$WORK_DIR/sdk"
python3 "$HERE/scripts/relocate_debian_header_sdk.py" \
    --sdk-root "$WORK_DIR/sdk" \
    --abi "$ABI" \
    --common-name "$COMMON_NAME" \
    --kbuild-name "$KBUILD_NAME"

HDR_DIR="$WORK_DIR/sdk/usr/src/linux-headers-$ABI"
[ -s "$HDR_DIR/Module.symvers" ] || { echo "ERROR: Module.symvers missing." >&2; exit 1; }
[ -s "$HDR_DIR/include/config/auto.conf" ] || { echo "ERROR: generated kernel config missing." >&2; exit 1; }

cp "$SOURCE" "$WORK_DIR/module/max98357a.c"
cp "$HERE/clock/playback/Makefile" "$WORK_DIR/module/Makefile"

export ARCH=arm
export CROSS_COMPILE="$CROSS_COMPILE_PREFIX"
export KBUILD_BUILD_USER=icubedev
export KBUILD_BUILD_HOST=bpi-zero-clock
export KBUILD_BUILD_TIMESTAMP='2026-08-17 00:00:00 +0000'
export SOURCE_DATE_EPOCH=1786924800
make -C "$HDR_DIR" M="$WORK_DIR/module" modules

KO="$WORK_DIR/module/snd-soc-max98357a.ko"
[ -s "$KO" ] || { echo "ERROR: MAX98357A module was not built." >&2; exit 1; }
VM="$(modinfo -F vermagic "$KO" | awk '{print $1}')"
[ "$VM" = "$ABI" ] || { echo "ERROR: MAX98357A vermagic '$VM' != '$ABI'." >&2; exit 1; }
[ "$(modinfo -F name "$KO")" = "snd_soc_max98357a" ] || { echo "ERROR: unexpected module name." >&2; exit 1; }
modinfo -F alias "$KO" | grep -q 'maxim,max98357a' || { echo "ERROR: MAX98357A OF alias missing." >&2; exit 1; }
[ -z "$(modinfo -F signer "$KO" 2>/dev/null || true)" ] || { echo "ERROR: unexpected module signer." >&2; exit 1; }
install -m 0644 "$KO" "$OUT_DIR/snd-soc-max98357a.ko"

{
    echo "KERNEL_ABI=$ABI"
    echo "DEBIAN_LINUX_VERSION=$DEBIAN_VERSION"
    echo "SOURCE_SHA256=$SOURCE_SHA256"
    echo "SOURCE_POLICY=hardware-validated-max98357a-source-rebuilt-for-exact-kernel"
    sha256sum "$OUT_DIR/snd-soc-max98357a.ko"
} > "$OUT_DIR/BUILD-MANIFEST.txt"
cat "$OUT_DIR/BUILD-MANIFEST.txt"
