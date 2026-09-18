# Downstream project contract

`bpi-zero-wbuild` is a Banana Pi BPI-M2 Zero board baseline. Project-specific hardware and application services belong in the consuming project.

## Base guarantees

A successful 3.13 image provides:

- Debian 13 Trixie on `6.12.107+deb13-armmp`, Debian package `6.12.107-1`
- kernel package hold that prevents an ordinary upgrade from silently changing the ABI
- patched BPI-M2 Zero DTB for the fixed held kernel
- BCM43430 Wi-Fi with iwd, systemd-networkd and systemd-resolved
- AP6212 Bluetooth firmware and validated UART topology
- `/dev/gpiochip0`
- `/dev/spidev0.0`
- `/dev/i2c-0`
- playback-only MAX98357A ALSA endpoint on I2S0
- PA1 reserved for MAX98357A SD/EN with 5 ms sequencing
- PA18/PA19/PA20 reserved for I2S0 LRCLK/BCLK/TX
- root-only login/SSH provisioning
- best-effort root growth with later retry if needed
- verbose boot and tty1 network information
- `/etc/bpi-zero-wbuild-release` for provenance and policy

## Project-owned hardware

Downstream software should own additional hardware such as displays, LEDs/PWM, buttons, touch inputs and project-specific sensors. Keep those changes in the downstream installer/package/DT layer rather than expanding the board baseline.

The deliberate exception is MAX98357A playback, which is part of the base contract. A project that needs PA1 or PA18/19/20 for another purpose must explicitly replace that DT policy.

## Integration check

Before installing a downstream hardware layer:

```bash
cat /etc/bpi-zero-wbuild-release
```

At minimum verify `PRODUCT`, `VERSION`, `TARGET`, `KERNEL_ABI`, `KERNEL_DEBIAN_VERSION`, the interface paths you require and the published audio/GPIO reservations.

The base intentionally prevents automatic kernel ABI changes because its DTB and MAX98357A module are tied to the published kernel. A downstream project that intentionally upgrades the kernel must treat that as a platform migration: rebuild/revalidate the DTB, rebuild the MAX98357A module, update release metadata, then replace the kernel hold deliberately.

## Wi-Fi ownership

Leave normal Wi-Fi lifecycle with iwd and systemd-networkd. The BPI-M2 Zero onboard radio is part of the base contract as `brcmfmac` on `wlan0`; network changes should be represented as iwd profiles, not by replacing the board Wi-Fi stack unless the downstream project deliberately needs another architecture.

## Headless GPU policy

The base DT disables `/soc/gpu@1c40000`. A downstream graphics image may re-enable Mali only when it also owns the correct regulator/OPP policy for that board configuration.
