#!/usr/bin/env python3
"""Build a small, spec-compliant FAT32 filesystem image by hand.
Used because a plain build host may not have mkfs.vfat/mtools available.
Contains CONFIG.TXT (editable Wi-Fi + timezone config) and README.TXT.

Usage: make_fat32.py <output.fat32> <sectors> <config_template_path>
"""
import struct
import sys
import datetime
import os

OUT_PATH = sys.argv[1] if len(sys.argv) > 1 else "bpiwbuild-config.fat32"
PART_SECTORS = int(sys.argv[2]) if len(sys.argv) > 2 else 131072  # 64 MiB
CONFIG_TEMPLATE = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
    os.path.dirname(__file__), "..", "config", "CONFIG.TXT.template"
)

BYTES_PER_SECTOR = 512
SEC_PER_CLUSTER = 1          # 512-byte clusters -> guarantees ClusterCount >= 65525 (true FAT32)
RESERVED_SECTORS = 32
NUM_FATS = 2
VOLUME_LABEL = "BPIWBUILD"
OEM_NAME = b"BPIWBLD "

with open(CONFIG_TEMPLATE, "rb") as f:
    CONFIG_TXT = f.read()

README_TXT = b"""This partition holds the configuration for bpi-zero-wbuild.

1. Open CONFIG.TXT in a text editor.
2. Fill in SSID, PSK, COUNTRY, HIDDEN, and (optionally) TIMEZONE.
3. Save the file back to this drive.
4. Eject/safely-remove this drive, put the SD card in the board, and
   power it on.

The board reads this file once, on its very first boot, to connect
to Wi-Fi and set its time zone, then continues its normal setup.
"""


def fat_time(dt):
    t = (dt.hour << 11) | (dt.minute << 5) | (dt.second // 2)
    d = ((dt.year - 1980) << 9) | (dt.month << 5) | dt.day
    return t, d


def make_83_name(name, ext):
    name = name.upper().ljust(8)[:8].encode("ascii")
    ext = ext.upper().ljust(3)[:3].encode("ascii")
    return name + ext


def build():
    total_sectors = PART_SECTORS

    # --- FAT size calculation (Microsoft fatgen103 approximation) ---
    root_dir_sectors = 0  # FAT32: root dir lives in the cluster heap
    tmp_val1 = total_sectors - (RESERVED_SECTORS + root_dir_sectors)
    tmp_val2 = (256 * SEC_PER_CLUSTER) + NUM_FATS
    tmp_val2 = tmp_val2 // 2  # FAT32
    fat_size = (tmp_val1 + (tmp_val2 - 1)) // tmp_val2

    data_sectors = total_sectors - (RESERVED_SECTORS + NUM_FATS * fat_size)
    count_of_clusters = data_sectors // SEC_PER_CLUSTER

    if count_of_clusters < 65525:
        raise SystemExit(
            f"CountOfClusters={count_of_clusters} < 65525; not valid FAT32 "
            "per spec heuristic. Increase partition size or decrease cluster size."
        )

    cluster_size = SEC_PER_CLUSTER * BYTES_PER_SECTOR
    root_cluster = 2

    img = bytearray(total_sectors * BYTES_PER_SECTOR)

    # ---------------- Boot sector (BPB) ----------------
    bs = bytearray(BYTES_PER_SECTOR)
    bs[0:3] = b"\xeb\x58\x90"          # JMP short + NOP
    bs[3:11] = OEM_NAME
    struct.pack_into("<H", bs, 11, BYTES_PER_SECTOR)
    bs[13] = SEC_PER_CLUSTER
    struct.pack_into("<H", bs, 14, RESERVED_SECTORS)
    bs[16] = NUM_FATS
    struct.pack_into("<H", bs, 17, 0)      # RootEntCnt = 0 for FAT32
    struct.pack_into("<H", bs, 19, 0)      # TotSec16 = 0 (using TotSec32)
    bs[21] = 0xF8                          # Media = fixed disk
    struct.pack_into("<H", bs, 22, 0)      # FATSz16 = 0 for FAT32
    struct.pack_into("<H", bs, 24, 63)     # SecPerTrk (legacy, unused)
    struct.pack_into("<H", bs, 26, 255)    # NumHeads (legacy, unused)
    struct.pack_into("<I", bs, 28, 0)      # HiddSec (partition-relative image; 0)
    struct.pack_into("<I", bs, 32, total_sectors)  # TotSec32
    struct.pack_into("<I", bs, 36, fat_size)   # FATSz32
    struct.pack_into("<H", bs, 40, 0)          # ExtFlags (mirrored FATs)
    struct.pack_into("<H", bs, 42, 0)          # FSVer 0.0
    struct.pack_into("<I", bs, 44, root_cluster)  # RootClus
    struct.pack_into("<H", bs, 48, 1)          # FSInfo sector
    struct.pack_into("<H", bs, 50, 6)          # Backup boot sector
    bs[64] = 0x80                              # DrvNum
    bs[65] = 0                                 # Reserved1
    bs[66] = 0x29                              # BootSig
    struct.pack_into("<I", bs, 67, 0x12345678)  # VolID
    bs[71:82] = VOLUME_LABEL.ljust(11)[:11].encode("ascii")
    bs[82:90] = b"FAT32   "
    bs[510] = 0x55
    bs[511] = 0xAA
    img[0:512] = bs

    # ---------------- FSInfo sector (sector 1) ----------------
    fsinfo = bytearray(BYTES_PER_SECTOR)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    struct.pack_into("<I", fsinfo, 484, 0x61417272)
    struct.pack_into("<I", fsinfo, 488, 0xFFFFFFFF)
    struct.pack_into("<I", fsinfo, 492, 0xFFFFFFFF)
    struct.pack_into("<I", fsinfo, 508, 0xAA550000)
    img[512:1024] = fsinfo

    img[6 * 512:6 * 512 + 512] = bs
    img[7 * 512:7 * 512 + 512] = fsinfo

    fat_start = RESERVED_SECTORS * BYTES_PER_SECTOR
    data_start = (RESERVED_SECTORS + NUM_FATS * fat_size) * BYTES_PER_SECTOR

    def cluster_offset(n):
        return data_start + (n - 2) * cluster_size

    def set_fat_entry(fat_bytes, n, val):
        struct.pack_into("<I", fat_bytes, n * 4, val & 0x0FFFFFFF)

    fat = bytearray(fat_size * BYTES_PER_SECTOR)
    set_fat_entry(fat, 0, 0x0FFFFFF8)
    set_fat_entry(fat, 1, 0x0FFFFFFF)

    now = datetime.datetime(2026, 1, 1, 0, 0, 0)
    ftime, fdate = fat_time(now)

    def write_file_clusters(data, start_cluster):
        clusters_needed = max(1, (len(data) + cluster_size - 1) // cluster_size)
        cl = start_cluster
        for i in range(clusters_needed):
            chunk = data[i * cluster_size:(i + 1) * cluster_size]
            off = cluster_offset(cl)
            img[off:off + len(chunk)] = chunk
            next_cl = cl + 1 if i < clusters_needed - 1 else 0x0FFFFFFF
            set_fat_entry(fat, cl, next_cl)
            cl += 1
        return clusters_needed

    next_free_cluster = 3  # cluster 2 is root dir
    root_entries = bytearray()

    vol_entry = bytearray(32)
    vol_entry[0:11] = VOLUME_LABEL.ljust(11)[:11].encode("ascii")
    vol_entry[11] = 0x08  # ATTR_VOLUME_ID
    struct.pack_into("<H", vol_entry, 22, ftime)
    struct.pack_into("<H", vol_entry, 24, fdate)
    root_entries += vol_entry

    def add_file_entry(fname, ext, data):
        nonlocal next_free_cluster
        cl = next_free_cluster
        clusters_used = write_file_clusters(data, cl)
        next_free_cluster += clusters_used
        e = bytearray(32)
        e[0:11] = make_83_name(fname, ext)
        e[11] = 0x20  # ATTR_ARCHIVE
        struct.pack_into("<H", e, 14, ftime)
        struct.pack_into("<H", e, 16, fdate)
        struct.pack_into("<H", e, 18, fdate)
        struct.pack_into("<H", e, 20, (cl >> 16) & 0xFFFF)
        struct.pack_into("<H", e, 22, ftime)
        struct.pack_into("<H", e, 24, fdate)
        struct.pack_into("<H", e, 26, cl & 0xFFFF)
        struct.pack_into("<I", e, 28, len(data))
        return e

    root_entries += add_file_entry("CONFIG", "TXT", CONFIG_TXT)
    root_entries += add_file_entry("README", "TXT", README_TXT)

    root_dir_data = bytes(root_entries)
    root_dir_clusters_needed = max(1, (len(root_dir_data) + cluster_size - 1) // cluster_size)
    if root_dir_clusters_needed > 1:
        raise SystemExit(
            "Root directory needs more than one cluster; allocate its "
            "clusters before file data to avoid overlap (not implemented)."
        )
    write_file_clusters(root_dir_data if root_dir_data else b"\x00" * cluster_size, root_cluster)

    for i in range(NUM_FATS):
        off = fat_start + i * fat_size * BYTES_PER_SECTOR
        img[off:off + len(fat)] = fat

    with open(OUT_PATH, "wb") as f:
        f.write(img)

    print(f"Wrote {OUT_PATH}: {len(img)} bytes "
          f"({len(img)/1024/1024:.1f} MiB), FATSz={fat_size} sectors, "
          f"clusters={count_of_clusters}, cluster_size={cluster_size}B, "
          f"config={len(CONFIG_TXT)}B")


if __name__ == "__main__":
    build()
