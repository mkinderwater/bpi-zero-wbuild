Place kernel-matched modules here as:
  <KERNEL_ABI>/snd-soc-max98357a.ko

The image builder validates module vermagic against the exact kernel ABI in the root filesystem and fails closed on mismatch.
