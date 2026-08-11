# bpi-zero-clock 1.0.0

Clock-ready Banana Pi M2 Zero image builder derived from the hardware-validated `bpi-zero-wbuild 1.2.6` baseline.

## Ownership

`bpi-zero-clock` owns the complete board hardware layer required by mk-clock applications:

- the validated BPI-M2 Zero Wi-Fi and AP6212 Bluetooth firmware inherited from 1.2.6;
- root filesystem expansion before networking, with no resize reboot;
- SPI0 and `/dev/spidev0.0` for the SSD1322 OLED;
- I2C0 for the AHT10;
- I2S0 for the MAX98357A;
- a precompiled, kernel-matched `snd-soc-max98357a.ko`;
- the final board DTB using the standard `maxim,max98357a` compatible;
- PA1 as MAX98357A SD/EN;
- the spidev binder service;
- kernel ABI pinning so the external module and DTB remain a tested set.

`mk-clock-adult` becomes application-only. It no longer needs to compile a kernel module, patch a DTB, install kernel headers, or require a hardware-preparation reboot.

## Build model

The amp module is compiled once for the exact kernel ABI in the image and placed under:

```text
clock/prebuilt/<kernel-abi>/snd-soc-max98357a.ko
```

The image builder rejects a module whose vermagic does not match the image ABI.

Build the module on an ARMv7 system with matching Debian headers, or on a cross-build host with `arm-linux-gnueabihf-gcc`:

```bash
./clock/build-max98357a.sh \
  6.12.100+deb13-armmp \
  /usr/src/linux-headers-6.12.100+deb13-armmp
```

Then build the image:

```bash
sudo ./build.sh
```

The exact ABI is derived from the rootfs and is not guessed. If the module for that ABI is missing, the image build stops.

## Release verification

The finished image must satisfy:

```text
/etc/bpi-zero-wbuild-release        base = 1.2.6
/etc/bpi-zero-clock-release         product = bpi-zero-clock 1.0.0
DTB root marker                     bpi-zero-clock,hardware = bpi-m2-zero-r1
/max98357a compatible               maxim,max98357a
snd-soc-max98357a.ko vermagic       exact image kernel ABI
/dev/spidev0.0                      created after boot
/dev/i2c-0                          present
ALSA MAX98357A card                  present
AP6212 Wi-Fi                         retained
AP6212 Bluetooth firmware            retained
```
