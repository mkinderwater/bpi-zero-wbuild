# bpi-zero-clock 1.0.4-preview25 installation

1. Run `sudo ./build.sh` on Debian 13 armhf or amd64.
2. Flash `out/bpi-zero-clock-1.0.4-preview25-bpi-m2-zero.img` or `.img.gz`.
3. Edit `CONFIG.TXT` on the FAT32 `BPIWBUILD` partition.
4. Boot once and allow firstboot to complete.
5. Confirm Wi-Fi reports `Power save: off`.
6. Install the matching `mk-clock-adult` release.

## Audio field check

No microphone validator is installed in the production image. Standard Debian ALSA utilities remain available.

```bash
arecord -l
arecord -D hw:0,1 --dump-hw-params \
  -t raw -f S32_LE -c 2 -r 24000 -d 1 /dev/null 2>&1
```

Expected rate capability:

```text
RATE: 24000
```

A 48000 Hz `arecord` request may warn and negotiate down to 24000 Hz; that is expected. The hardware parameter dump is authoritative.

With a microphone attached:

```bash
arecord -D hw:0,1 -t raw -f S32_LE -c 2 -r 24000 -d 5 /tmp/mic.raw
wc -c /tmp/mic.raw
```

Five seconds should produce `960000` bytes.

## Network checks

```bash
ip -br addr show wlan0
ip route
iw dev wlan0 link
iw dev wlan0 get power_save
```

Expected power state: `Power save: off`.

## Logs

```text
/var/log/bpi-zero-wbuild-firstboot.log
/var/log/bpi-zero-wbuild-packages.log
```
