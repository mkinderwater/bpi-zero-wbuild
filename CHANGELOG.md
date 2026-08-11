# Changelog

## 1.0.3 - 2026-08-11

- Made retirement of `mk-clock-amp-gate` a verified image-build invariant rather than best-effort cleanup.
- Removes legacy amp-gate unit files, wants symlinks, executables, and module-load stubs from all known historical locations.
- Build fails if any listed legacy artifact remains, including dangling systemd symlinks.
- Adds `LEGACY_AMP_GATE_FILES=absent-verified` to release metadata.
- Retains the exact hardware-validated MAX98357A module and DTB from 1.0.2.

## 1.0.2 - 2026-08-11

- Replaced the `linux,spdif-dit` dummy-codec audio path with the real upstream `maxim,max98357a` codec driver.
- Embedded the hardware-validated `snd-soc-max98357a.ko` for kernel `6.12.100+deb13-armmp`.
- Embedded the exact hardware-validated BPI-M2 Zero clock DTB.
- Assigned MAX98357A SD/EN PA1 to the codec through `sdmode-gpios` with a 5 ms `sdmode-delay`.
- Retained I2S0 on PA18/PA19/PA20 and `mclk-fs=256`.
- Removed the legacy userspace `mk-clock-amp-gate` path from new builds.
- Added strict ABI, vermagic, OF-compatible and SHA256 checks for the validated audio set.
- Hardware validation passed a silence-tone-silence playback test with no startup pop and no trailing hiss.
- Retained the `bpi-zero-wbuild 1.2.6` Wi-Fi, AP6212 firmware, and root-resize behavior.

## 1.0.0

- Initial specialized clock image derived from the generalized BPI-M2 Zero builder.
