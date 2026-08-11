#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 INPUT_DTB OUTPUT_DTB" >&2
    exit 2
fi
INPUT="$1"
OUTPUT="$2"
for tool in dtc fdtget fdtput; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done
[ -f "$INPUT" ] || { echo "ERROR: base DTB not found: $INPUT" >&2; exit 1; }
MODEL="$(fdtget -t s "$INPUT" / model 2>/dev/null || true)"
case "$MODEL" in
    *"Banana Pi BPI-M2-Zero"*|*"Banana Pi BPI-M2 Zero"*) ;;
    *) echo "ERROR: unsupported Device Tree model: ${MODEL:-unknown}" >&2; exit 1 ;;
esac

PIO=/soc/pinctrl@1c20800
SPI0=/soc/spi@1c68000
I2C0=/soc/i2c@1c2ac00
I2S0=/soc/i2s@1c22000
for node in "$PIO" "$SPI0" "$I2C0" "$I2S0"; do
    fdtget -p "$INPUT" "$node" >/dev/null 2>&1 || { echo "ERROR: missing DT node: $node" >&2; exit 1; }
done
PIO_PHANDLE="$(fdtget -t x "$INPUT" "$PIO" phandle 2>/dev/null || true)"
[ -n "$PIO_PHANDLE" ] || { echo "ERROR: pin controller has no phandle." >&2; exit 1; }
for handle in 70000001 70000002 70000003 70000004; do
    if dtc -I dtb -O dts "$INPUT" 2>/dev/null | grep -qi "phandle = <0x${handle}>"; then
        echo "ERROR: reserved bpi-zero-clock phandle 0x${handle} already exists." >&2
        exit 1
    fi
done
I2S_PHANDLE="$(fdtget -t x "$INPUT" "$I2S0" phandle 2>/dev/null || true)"
[ -n "$I2S_PHANDLE" ] || I2S_PHANDLE=70000001
I2S_PINS_PHANDLE=70000002
CODEC_PHANDLE=70000003
CPU_LINK_PHANDLE=70000004
TMP="$(mktemp "${OUTPUT}.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cp "$INPUT" "$TMP"

fdtput -t s "$TMP" "$SPI0" status okay
fdtput -cp "$TMP" "$SPI0/mk-piclock-oled@0"
fdtput -t s "$TMP" "$SPI0/mk-piclock-oled@0" compatible mk,piclock-oled
fdtput -t x "$TMP" "$SPI0/mk-piclock-oled@0" reg 0
fdtput -t x "$TMP" "$SPI0/mk-piclock-oled@0" spi-max-frequency 3d0900
fdtput -t s "$TMP" "$SPI0/mk-piclock-oled@0" status okay
fdtput -t s "$TMP" "$I2C0" status okay

fdtput -cp "$TMP" "$PIO/mk-piclock-i2s0-pins"
fdtput -t s "$TMP" "$PIO/mk-piclock-i2s0-pins" pins PA18 PA19 PA20
fdtput -t s "$TMP" "$PIO/mk-piclock-i2s0-pins" function i2s0
fdtput -t x "$TMP" "$PIO/mk-piclock-i2s0-pins" phandle "$I2S_PINS_PHANDLE"
fdtput -t x "$TMP" "$PIO/mk-piclock-i2s0-pins" linux,phandle "$I2S_PINS_PHANDLE"
fdtput -t s "$TMP" "$I2S0" status okay
fdtput -t s "$TMP" "$I2S0" pinctrl-names default
fdtput -t x "$TMP" "$I2S0" pinctrl-0 "$I2S_PINS_PHANDLE"
if ! fdtget "$TMP" "$I2S0" phandle >/dev/null 2>&1; then
    fdtput -t x "$TMP" "$I2S0" phandle "$I2S_PHANDLE"
    fdtput -t x "$TMP" "$I2S0" linux,phandle "$I2S_PHANDLE"
fi

fdtput -cp "$TMP" /max98357a
fdtput -t s "$TMP" /max98357a compatible maxim,max98357a
fdtput -t x "$TMP" /max98357a '#sound-dai-cells' 0
fdtput -t x "$TMP" /max98357a sdmode-gpios "$PIO_PHANDLE" 0 1 0
fdtput -t x "$TMP" /max98357a sdmode-delay 5
fdtput -t x "$TMP" /max98357a phandle "$CODEC_PHANDLE"
fdtput -t x "$TMP" /max98357a linux,phandle "$CODEC_PHANDLE"
fdtput -t s "$TMP" /max98357a status okay

fdtput -cp "$TMP" /sound-max98357a
fdtput -t s "$TMP" /sound-max98357a compatible simple-audio-card
fdtput -t s "$TMP" /sound-max98357a simple-audio-card,name MAX98357A
fdtput -t s "$TMP" /sound-max98357a simple-audio-card,format i2s
fdtput -t x "$TMP" /sound-max98357a simple-audio-card,mclk-fs 100
fdtput -t s "$TMP" /sound-max98357a status okay
fdtput -cp "$TMP" /sound-max98357a/simple-audio-card,cpu
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,cpu sound-dai "$I2S_PHANDLE"
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,cpu phandle "$CPU_LINK_PHANDLE"
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,cpu linux,phandle "$CPU_LINK_PHANDLE"
fdtput -cp "$TMP" /sound-max98357a/simple-audio-card,codec
fdtput -t x "$TMP" /sound-max98357a/simple-audio-card,codec sound-dai "$CODEC_PHANDLE"
fdtput -t x "$TMP" /sound-max98357a simple-audio-card,bitclock-master "$CPU_LINK_PHANDLE"
fdtput -t x "$TMP" /sound-max98357a simple-audio-card,frame-master "$CPU_LINK_PHANDLE"
fdtput -t s "$TMP" / bpi-zero-clock,hardware bpi-m2-zero-r1

dtc -I dtb -O dtb -o /dev/null "$TMP"
[ "$(fdtget -t s "$TMP" "$SPI0" status)" = okay ]
[ "$(fdtget -t s "$TMP" "$I2C0" status)" = okay ]
[ "$(fdtget -t s "$TMP" "$I2S0" status)" = okay ]
[ "$(fdtget -t s "$TMP" /max98357a compatible)" = maxim,max98357a ]
[ "$(fdtget -t s "$TMP" /sound-max98357a simple-audio-card,name)" = MAX98357A ]
mkdir -p "$(dirname "$OUTPUT")"
install -m 0644 "$TMP" "$OUTPUT"
trap - EXIT
rm -f "$TMP"
echo "Installed clock-ready BPI-M2 Zero DTB: $OUTPUT"
