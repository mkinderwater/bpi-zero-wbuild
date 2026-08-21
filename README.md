# bpi-zero-clock 1.0.4-preview36

Playback-only Banana Pi M2 Zero clock image based on the 2026-08-17 Debian Trixie armhf root image and pinned to kernel ABI `6.12.101+deb13-armmp`.

## Release intent

Preview36 migrates the clock to the newer Debian base while preserving the deliberately small appliance hardware contract. The clock has no microphone or voice-assistant path. Audio is MAX98357A playback only, touch remains on PA17 / physical pin 37, and PA21 / physical pin 38 is unassigned.

The Debian root payload is pinned by both URL and compressed SHA256:

```text
https://dl.sd-card-images.johang.se/debians/2026-08-17/debian-trixie-armhf-eiy3bo.bin.gz
SHA256 8cca0fed789a76fef8fb7c8c18bf46ed4d362f9e84d91ffecfe6674e9713c94f
```

The new base contains Debian kernel `6.12.101+deb13-armmp`. Its stock kernel does not provide the clock's MAX98357A codec module, so the image builder rebuilds only `snd-soc-max98357a` for the exact ABI from the same codec source used by the previously hardware-clean playback path. The I2S controller and simple-card drivers remain Debian stock modules.

The clock DTB is generated from the **stock 6.12.101 Banana Pi M2 Zero DTB** in the new rootfs. The builder applies only the clock hardware changes: SPI0 for the SSD1322, I2C0 for the AHT10, playback-only I2S0 on PA18/PA19/PA20, and MAX98357A PA1 shutdown/enable control with the existing 5 ms delay.

## Boot model

The 2026-08-17 Debian image uses U-Boot `extlinux.conf`. Preview36 therefore retires the old `boot.cmd` / `boot.scr` modification path.

The final appliance boot entry is normalized to:

```text
root=PARTUUID=<disk-signature>-02 rw rootwait quiet loglevel=4
prompt 0
timeout 10
```

The PARTUUID is derived from the preserved upstream MBR disk signature. The final root filesystem is always MBR partition 2.

## Playback hardware

```text
MAX98357A SD/EN : PA1  / physical pin 11
I2S LRCLK       : PA18 / physical pin 28
I2S BCLK        : PA19 / physical pin 27
I2S playback    : PA20 / physical pin 40
Touch           : PA17 / physical pin 37
PA21            : physical pin 38, free
```

ALSA defaults directly to `hw:MAX98357A,0`. The image does not add software resampling, `dmix`, `dsnoop`, or an asymmetric playback/capture wrapper.

## Appliance policy retained

Preview36 retains the proven firstboot flow: online root expansion before networking, clone-safe machine identity and random hostname, iwd + systemd-networkd, Wi-Fi power-save disabled for brcmfmac, board-qualified AP6212 firmware, SSH, volatile bounded journald, bounded `/tmp`, watchdog policy, field diagnostics, and read-only build-time ext4 validation.

Builder host prerequisites remain explicit, including `ca-certificates`, `unzip`, `device-tree-compiler`, and the compiler/tooling required to rebuild the one MAX98357A module.

## Build

```bash
unzip bpi-zero-clock-1.0.4-preview36-source.zip
cd bpi-zero-clock-1.0.4-preview36-source
./build.sh
```

Expected outputs:

```text
out/bpi-zero-clock-1.0.4-preview36-bpi-m2-zero.img
out/bpi-zero-clock-1.0.4-preview36-bpi-m2-zero.img.gz
```

## Validation status

The MAX98357A topology, codec source, PA1 control and 5 ms enable delay originate from the playback configuration previously proven clean on the hardware. Preview36 recompiles that codec for kernel 6.12.101 and derives its DTB from the new kernel's stock DTB.

Because this is a kernel/base migration, **physical speaker playback on 6.12.101 remains a target validation requirement** before this preview is promoted to a frozen production baseline.
