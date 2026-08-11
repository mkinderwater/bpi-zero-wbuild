# bpi-zero-clock 1.0.3

Clock-ready Banana Pi M2 Zero image builder derived from `bpi-zero-wbuild 1.2.6`.

## Hardware-validated audio release

Version 1.0.3 ships the exact MAX98357A module and Device Tree that passed the physical Banana Pi M2 Zero audio test on 2026-08-11.

Validated set:

```text
Kernel ABI:              6.12.100+deb13-armmp
MAX98357A module SHA256: 906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6
Clock DTB SHA256:        7d54132d9b707ec62d5b72e08cd329b557a92940664e48164b5b8a8cfd5fcaff
I2S0:                    PA18 / PA19 / PA20
MAX98357A SD/EN:         PA1
sdmode-delay:            5 ms
mclk-fs:                 256
Codec compatible:        maxim,max98357a
```

The direct playback validation used one second of digital silence, a two-second 440 Hz tone, then one second of digital silence. Playback had no startup pop and no trailing hiss.

The earlier `linux,spdif-dit` dummy-codec path and `mk-clock-amp-gate` userspace PA1 control are retired. PA1 is owned by `snd_soc_max98357a` through `sdmode-gpios`.

## Release model

The validated module and DTB are immutable release artifacts under:

```text
clock/validated/6.12.100+deb13-armmp/
```

`build.sh` verifies the kernel ABI, module vermagic, OF alias, module SHA256 and DTB SHA256. The build stops if any part of the tested set differs.

The image continues to inherit the `bpi-zero-wbuild 1.2.6` Wi-Fi, board-qualified AP6212 Bluetooth firmware, and online root-filesystem resize behavior. Bluetooth userspace remains application-owned.

## Build

On a Linux build host:

```bash
sudo ./build.sh
```

Output:

```text
out/bpi-zero-clock-1.0.3-bpi-m2-zero.img
out/bpi-zero-clock-1.0.3-bpi-m2-zero.img.gz
```

## Expected runtime audio state

```text
snd_soc_max98357a loaded
snd_soc_spdif_tx absent
ALSA card: MAX98357A
PCM: 1c22000.i2s-HiFi HiFi-0
mk-clock-amp-gate inactive/absent
```

The clock application owns userspace application packages. The image owns the board/kernel hardware layer.
