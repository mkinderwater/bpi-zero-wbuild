#!/usr/bin/env bash
# Enable the reusable BPI M2 Zero hardware baseline:
# SPI0/spidev, I2C0/i2c-dev, and playback-only I2S0/MAX98357A.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 STOCK.dtb OUT.dtb" >&2; exit 2; }
IN="$1"; OUT="$2"
[ -s "$IN" ] || { echo "ERROR: stock DTB missing: $IN" >&2; exit 1; }
for tool in dtc fdtget fdtput; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done
MODEL="$(fdtget -t s "$IN" / model 2>/dev/null || true)"
case "$MODEL" in
    *"Banana Pi BPI-M2-Zero"*|*"Banana Pi BPI-M2 Zero"*) ;;
    *) echo "ERROR: unsupported Device Tree model: ${MODEL:-unknown}" >&2; exit 1 ;;
esac

PIO=/soc/pinctrl@1c20800
SPI0=/soc/spi@1c68000
I2C0=/soc/i2c@1c2ac00
I2S0=/soc/i2s@1c22000
GPU=/soc/gpu@1c40000
for node in "$PIO" "$SPI0" "$I2C0" "$I2S0" "$GPU"; do
    fdtget -p "$IN" "$node" >/dev/null 2>&1 || { echo "ERROR: missing DT node: $node" >&2; exit 1; }
done
GPIO_PHANDLE="$(fdtget -t x "$IN" "$PIO" phandle 2>/dev/null || true)"
[ -n "$GPIO_PHANDLE" ] || { echo "ERROR: pin controller has no phandle." >&2; exit 1; }

for handle in 70000001 70000002 70000003 70000004; do
    if dtc -I dtb -O dts "$IN" 2>/dev/null | grep -qi "phandle = <0x${handle}>"; then
        echo "ERROR: private phandle 0x${handle} already exists." >&2; exit 1
    fi
done
I2S_PH="$(fdtget -t x "$IN" "$I2S0" phandle 2>/dev/null || true)"
[ -n "$I2S_PH" ] || I2S_PH=70000001
I2S_PINS_PH=70000002
CODEC_PH=70000003
CPU_PH=70000004

TMP="$(mktemp "${OUT}.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cp "$IN" "$TMP"

# Pin the Linux bus numbering we publish. Mainline BPI-M2-Zero DTs do not
# necessarily provide spi0/i2c0 aliases, so create/update them explicitly.
if ! fdtget -p "$TMP" /aliases >/dev/null 2>&1; then
    fdtput -cp "$TMP" /aliases
fi
fdtput -t s "$TMP" /aliases spi0 "$SPI0"
fdtput -t s "$TMP" /aliases i2c0 "$I2C0"

# SPI0. A private child is created then bound to spidev by a small boot service.
fdtput -t s "$TMP" "$SPI0" status okay
fdtput -cp "$TMP" "$SPI0/bpi-zero-userspace@0"
fdtput -t s "$TMP" "$SPI0/bpi-zero-userspace@0" compatible bpi-zero-wbuild,userspace-spi
fdtput -t x "$TMP" "$SPI0/bpi-zero-userspace@0" reg 0
fdtput -t x "$TMP" "$SPI0/bpi-zero-userspace@0" spi-max-frequency 3d0900
fdtput -t s "$TMP" "$SPI0/bpi-zero-userspace@0" status okay

# I2C0 userspace bus.
fdtput -t s "$TMP" "$I2C0" status okay

# Playback-only I2S0 on PA18/PA19/PA20. PA21 remains unassigned.
fdtput -cp "$TMP" "$PIO/bpi-zero-i2s0-pins"
fdtput -t s "$TMP" "$PIO/bpi-zero-i2s0-pins" pins PA18 PA19 PA20
fdtput -t s "$TMP" "$PIO/bpi-zero-i2s0-pins" function i2s0
fdtput -t x "$TMP" "$PIO/bpi-zero-i2s0-pins" phandle "$I2S_PINS_PH"
fdtput -t x "$TMP" "$PIO/bpi-zero-i2s0-pins" linux,phandle "$I2S_PINS_PH"
fdtput -t s "$TMP" "$I2S0" status okay
fdtput -t s "$TMP" "$I2S0" pinctrl-names default
fdtput -t x "$TMP" "$I2S0" pinctrl-0 "$I2S_PINS_PH"
if ! fdtget "$TMP" "$I2S0" phandle >/dev/null 2>&1; then
    fdtput -t x "$TMP" "$I2S0" phandle "$I2S_PH"
    fdtput -t x "$TMP" "$I2S0" linux,phandle "$I2S_PH"
fi

# MAX98357A. PA1 is SD/EN; codec-driver sequencing retains the 5 ms delay.
fdtput -cp "$TMP" /max98357a
fdtput -t s "$TMP" /max98357a compatible maxim,max98357a
fdtput -t x "$TMP" /max98357a '#sound-dai-cells' 0
fdtput -t x "$TMP" /max98357a sdmode-gpios "$GPIO_PHANDLE" 0 1 0
fdtput -t x "$TMP" /max98357a sdmode-delay 5
fdtput -t x "$TMP" /max98357a phandle "$CODEC_PH"
fdtput -t x "$TMP" /max98357a linux,phandle "$CODEC_PH"
fdtput -t s "$TMP" /max98357a status okay

fdtput -cp "$TMP" /sound-max98357a
fdtput -t s "$TMP" /sound-max98357a compatible simple-audio-card
fdtput -t s "$TMP" /sound-max98357a simple-audio-card,name MAX98357A
fdtput -t s "$TMP" /sound-max98357a simple-audio-card,format i2s
fdtput -t x "$TMP" /sound-max98357a simple-audio-card,mclk-fs 100
fdtput -t s "$TMP" /sound-max98357a status okay
fdtput -cp "$TMP" /sound-max98357a/simple-audio-card,cpu
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,cpu sound-dai "$I2S_PH"
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,cpu phandle "$CPU_PH"
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,cpu linux,phandle "$CPU_PH"
fdtput -cp "$TMP" /sound-max98357a/simple-audio-card,codec
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,codec sound-dai "$CODEC_PH"
fdtput -t x "$TMP" /sound-max98357a simple-audio-card,bitclock-master "$CPU_PH"
fdtput -t x "$TMP" /sound-max98357a simple-audio-card,frame-master "$CPU_PH"

# This is a headless jump-point. The inherited H2+/H3 GPU node has OPPs but
# the BPI-M2 Zero board DT does not describe a mali-supply regulator, causing
# Lima to emit _opp_set_regulators -ENODEV during every boot. Keep the base DT
# honest and quiet by disabling the unused GPU. Downstream graphics projects
# can deliberately re-enable it together with the correct board power policy.
fdtput -t s "$TMP" "$GPU" status disabled

# PA0/PA2/PA7/PA8/PA9/PA17 are intentionally not claimed here.
# They remain ordinary gpiochip0 lines for downstream applications.

dtc -I dtb -O dtb -o /dev/null "$TMP"
[ "$(fdtget -t s "$TMP" /max98357a compatible)" = maxim,max98357a ]
[ "$(fdtget -t x "$TMP" /max98357a sdmode-delay)" = 5 ]
[ "$(fdtget -t x "$TMP" /sound-max98357a simple-audio-card,mclk-fs)" = 100 ]
[ "$(fdtget -t s "$TMP" "$PIO/bpi-zero-i2s0-pins" pins)" = 'PA18 PA19 PA20' ]
[ "$(fdtget -t s "$TMP" "$I2C0" status)" = okay ]
[ "$(fdtget -t s "$TMP" "$GPU" status)" = disabled ] || { echo "ERROR: headless GPU policy was not applied." >&2; exit 1; }
[ "$(fdtget -t s "$TMP" /aliases spi0)" = "$SPI0" ] || { echo "ERROR: aliases:spi0 does not pin $SPI0." >&2; exit 1; }
[ "$(fdtget -t s "$TMP" /aliases i2c0)" = "$I2C0" ] || { echo "ERROR: aliases:i2c0 does not pin $I2C0." >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
install -m 0644 "$TMP" "$OUT"
trap - EXIT
rm -f "$TMP"
echo "Installed BPI-M2 Zero headless SPI0 + I2C0 + I2S0/MAX98357A Device Tree: $OUT"
