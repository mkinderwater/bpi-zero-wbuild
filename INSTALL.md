# Install / validate preview36 playback-only image

Build and flash `bpi-zero-clock-1.0.4-preview36`. Firstboot must complete before installing the paired adult application.

## First boot

Confirm the platform and provisioning state:

```bash
cat /etc/bpi-zero-clock-release
uname -r
systemctl --failed --no-pager
systemctl is-active iwd systemd-networkd ssh
ip -br addr show wlan0
```

Expected kernel:

```text
6.12.101+deb13-armmp
```

Expected audio policy: one MAX98357A playback PCM and no image-owned capture PCM. PA21 / physical pin 38 is free; touch remains PA17 / physical pin 37.

## Playback validation

```bash
cat /proc/asound/cards
cat /proc/asound/pcm
aplay -D hw:MAX98357A,0 /path/to/test.wav
```

Confirm clean startup, sustained playback and stop with no crackle, pop or trailing noise. This is the required hardware gate for the 6.12.101 migration.

The release metadata records the exact generated module and DTB hashes:

```bash
grep -E '^(KERNEL_ABI|MAX98357A_MODULE_SHA256|MAX98357A_DTB_SHA256|AUDIO_VALIDATION)=' \
  /etc/bpi-zero-clock-release
```

## Paired application

Install `mk-clock-adult 2.3.50-preview34`, which is paired to this base image and kernel ABI.
