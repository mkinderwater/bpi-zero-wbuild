# bpi-zero-clock 1.0.0 build procedure

1. Build or provide the MAX98357A module for the exact kernel ABI in the base image.
2. Place it at `clock/prebuilt/<ABI>/snd-soc-max98357a.ko`.
3. Run `sudo ./build.sh` on Linux.
4. Flash `out/bpi-zero-clock.img` or `out/bpi-zero-clock.img.gz`.
5. Allow firstboot to expand root storage before Wi-Fi provisioning.
6. Install `mk-clock-adult` as an application. The application installer should not modify Device Tree or build kernel modules on this image.

The builder requires `device-tree-compiler`, `kmod` (`depmod`/`modinfo`) and the normal bpi-zero-wbuild build requirements.
