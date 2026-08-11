# MAX98357A driver source

`max98357a.c` is the Linux v6.12 upstream MAX98357A ASoC codec driver, retained under its original SPDX/GPL licensing header.

Source path:

```text
sound/soc/codecs/max98357a.c
```

Upstream reference:

```text
https://github.com/torvalds/linux/blob/v6.12/sound/soc/codecs/max98357a.c
```

The image builder compiles this as an external module only because Debian's selected armmp kernel configuration does not ship the codec module. The resulting `.ko` is accepted only when its vermagic exactly matches the image kernel ABI.
