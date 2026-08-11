#!/usr/bin/env python3
"""Build the MBR + pre-partition raw area for the final image, producing a
2-partition layout:

  partition 1: NEW - FAT32 "BPIWBUILD" config partition
  partition 2: root ext4, same sector count as the input debian.bin

The upstream boot image ships a small placeholder partition (labeled, on
its own volume, "PARTITION_INTENTIONALLY_EMPTY.TXT") that the SoC's boot
process does not use -- confirmed by that file's own contents. We drop it
entirely rather than carrying it forward.

What we DO preserve verbatim: the raw area before the first partition
(where U-Boot/SPL actually lives, independent of the MBR partition table
-- the SoC's boot ROM reads it from a fixed offset regardless of what the
partition table says). That gap size is read from the upstream image's
own partition 1 LBA-start field, so this keeps working if a future
upstream image uses a different gap.

Only bytes 446-509 of sector 0 (the four 16-byte partition table entries)
are ever rewritten. Boot code (bytes 0-445) and the 0x55AA signature are
preserved exactly as shipped upstream.
"""
import argparse
import struct
import os


def parse_mbr(data):
    entries = []
    for i in range(4):
        off = 446 + i * 16
        status, chs1, ptype, chs2, lba, sectors = struct.unpack(
            '<B3sB3sII', data[off:off + 16]
        )
        entries.append(dict(status=status, ptype=ptype, lba=lba, sectors=sectors))
    return entries


def make_entry(status, ptype, lba_start, sectors):
    chs_dummy = bytes([0xFE, 0xFF, 0xFF])
    return struct.pack('<B3sB3sII', status, chs_dummy, ptype, chs_dummy, lba_start, sectors)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot-in", required=True,
                     help="upstream boot image (only its raw pre-partition area is used)")
    ap.add_argument("--boot-out", required=True,
                     help="output: raw pre-partition area with patched MBR")
    ap.add_argument("--debian-in", required=True)
    ap.add_argument("--config-sectors", type=int, required=True)
    ap.add_argument("--config-type", type=lambda x: int(x, 0), default=0x0c,
                     help="MBR partition type byte for the config partition (default 0x0c, FAT32 LBA)")
    args = ap.parse_args()

    with open(args.boot_in, "rb") as f:
        boot = bytearray(f.read())

    if boot[510:512] != b"\x55\xaa":
        raise SystemExit("boot-in does not look like a valid MBR (missing 55AA signature)")

    entries = parse_mbr(bytes(boot))
    p1_orig = entries[0]
    if p1_orig["ptype"] == 0:
        raise SystemExit("partition 1 is empty in boot-in; can't determine the pre-partition gap size")

    pre_partition_gap = p1_orig["lba"]  # sectors before the (discarded) placeholder partition

    debian_size = os.path.getsize(args.debian_in)
    if debian_size % 512 != 0:
        raise SystemExit("debian-in size is not a multiple of 512 bytes")
    root_sectors = debian_size // 512

    p1_start = pre_partition_gap  # config partition takes over where the placeholder used to start
    p1_sectors = args.config_sectors
    p2_start = p1_start + p1_sectors
    p2_sectors = root_sectors

    new_entries = (
        make_entry(0x00, args.config_type, p1_start, p1_sectors) +
        make_entry(0x80, 0x83, p2_start, p2_sectors) +  # 0x80 = bootable/active, matches upstream root
        make_entry(0, 0, 0, 0) +
        make_entry(0, 0, 0, 0)
    )
    assert len(new_entries) == 64

    boot[446:446 + 64] = new_entries
    assert boot[510:512] == b"\x55\xaa"

    # Only the raw area up through the start of partition 1 is meaningful now;
    # the old placeholder partition's own data (after that point) is discarded.
    boot_out_bytes = bytes(boot[:pre_partition_gap * 512])

    with open(args.boot_out, "wb") as f:
        f.write(boot_out_bytes)

    def mib(sectors):
        return sectors * 512 / 1024 / 1024

    print(f"dropped upstream placeholder partition (was {mib(p1_orig['sectors']):.1f} MiB, unused by boot)")
    print(f"pre-partition raw area (U-Boot/SPL, preserved verbatim): {mib(pre_partition_gap):.1f} MiB")
    print(f"partition 1 (BPIWBUILD config, new): start={p1_start} sectors={p1_sectors} "
          f"({mib(p1_sectors):.1f} MiB)")
    print(f"partition 2 (root ext4): start={p2_start} sectors={p2_sectors} "
          f"({mib(p2_sectors):.1f} MiB)")
    print(f"total disk size: {(p2_start + p2_sectors) * 512} bytes "
          f"({(p2_start + p2_sectors) * 512 / 1024 / 1024:.1f} MiB)")
    print(f"wrote {args.boot_out} ({len(boot_out_bytes)} bytes)")


if __name__ == "__main__":
    main()
