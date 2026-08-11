# Changelog

## 1.0.0 - 2026-08-11

- Derived from validated `bpi-zero-wbuild 1.2.6`.
- Moved clock hardware ownership from `mk-clock-adult` into the image.
- Added standard upstream MAX98357A ASoC driver source and precompiled-module workflow.
- Added final BPI-M2 Zero clock DTB with SPI0, I2C0, I2S0, MAX98357A and PA1 SD/EN.
- Added strict module vermagic validation against the image kernel ABI.
- Added image-owned spidev binding.
- Added kernel ABI pinning policy so kernel/module/DTB updates ship together as a tested image release.
- Retained the validated 1.2.6 resize-first, no-reboot, Wi-Fi and AP6212 firmware behavior.
