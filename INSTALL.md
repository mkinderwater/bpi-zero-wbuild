# bpi-zero-clock 1.0.3 installation

1. Build the image on Linux with `sudo ./build.sh`, or use the released compressed image.
2. Flash `bpi-zero-clock-1.0.3-bpi-m2-zero.img` to the microSD card.
3. Edit `CONFIG.TXT` on the `BPIWBUILD` partition for Wi-Fi and timezone settings.
4. Boot the Banana Pi M2 Zero and allow first-boot provisioning to finish.
5. Install `mk-clock-adult` as the application layer.

The image already contains the clock hardware layer: SPI0, I2C0, I2S0, the hardware-validated MAX98357A codec module and final DTB. No application-side kernel module compilation or Device Tree patch is required.

Verify audio after boot:

```bash
cat /etc/bpi-zero-clock-release
lsmod | grep snd_soc_max98357a
cat /proc/asound/cards
cat /proc/asound/pcm
```

Expected PCM endpoint:

```text
1c22000.i2s-HiFi HiFi-0
```
