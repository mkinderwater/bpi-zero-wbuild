# Build and first boot

## Build

```bash
unzip bpi-zero-wbuild-3.13-trixie-minimal-hw-jumppoint-source.zip
cd bpi-zero-wbuild-3.13-trixie-minimal-hw
sudo ./build.sh
```

The build targets `6.12.107+deb13-armmp` / Debian `6.12.107-1`. It also verifies and writes the final root PARTUUID into extlinux and U-Boot policy before publishing the image.

Flash the resulting `.img.gz` directly with a tool that supports gzip images.

## Configure before first boot

Edit `CONFIG.TXT` on the `BPIWBUILD` partition and set:

```text
SSID=
PSK=
COUNTRY=
HIDDEN=
TIMEZONE=
ROOT_PASSWORD=
```

`ROOT_PASSWORD` is mandatory and must be 8-64 characters. The image ships with root locked and inherited human login accounts removed. If the password is invalid or missing, local/serial gettys may still display a prompt, but there are no usable stock credentials. Correct the FAT configuration and reboot.

After successful provisioning, `PSK=` and `ROOT_PASSWORD=` are blanked automatically.

## What you should see

Boot is verbose. Kernel, systemd and firstboot events remain visible.

The image already contains the signed Debian regulatory database before first boot, so cfg80211 does not need to wait for firstboot package installation.

Firstboot attempts root filesystem growth before credential validation. It then validates and sets the root password, generates unique SSH host keys, validates the effective root/password SSH policy and starts SSH before Wi-Fi provisioning. Once Wi-Fi and DHCP succeed, firstboot writes the tty1 banner with the known `wlan0` interface, MAC and dynamic IPv4 field, rechecks SSH and announces the resolved address.

Example:

```text
Debian GNU/Linux 13 debian tty1

Wi-Fi: wlan0  MAC: 00:11:22:33:44:55  IPv4: 192.168.1.50

bpi-zero-wbuild login:
```

The Banana Pi M2 Zero base contract uses `wlan0` for the onboard brcmfmac Wi-Fi interface.

Root filesystem expansion is best effort. If online resize fails, network/SSH provisioning continues and the resize is retried on later boots until it succeeds. Firstboot otherwise uses idempotent setup instead of per-stage checkpoint files.

## Useful checks

```bash
cat /etc/bpi-zero-wbuild-release
networkctl list --no-pager
iwctl device list
resolvectl status
systemctl --failed --no-pager
cat /proc/asound/cards
journalctl -b -u bpi-zero-wbuild-firstboot --no-pager
cat /boot/extlinux/extlinux.conf
cat /etc/default/u-boot
```

The onboard BPI-M2 Zero Wi-Fi interface is `wlan0`. To inspect it:

```bash
networkctl status wlan0 --no-pager
iwctl station wlan0 show
```

The base DT disables the unused Mali GPU, so a normal headless boot should not contain the Lima `_opp_set_regulators` regulator warning.
