#!/usr/bin/env python3
"""Derive host/usr/lib/firmware/edid/gameland.bin from the vendored steamdeck.bin.

Adds 1920x1200 at 60/90/120 Hz and swaps 2560x1440@120 for @90. See docs/streaming.md §6.
Usage: gen-edid.py [--check]
"""
import pathlib
import sys

EDID_DIR = pathlib.Path(__file__).resolve().parent.parent / "host/usr/lib/firmware/edid"
SRC, DST = EDID_DIR / "steamdeck.bin", EDID_DIR / "gameland.bin"

STD_TIMINGS = 38
BASE_DTD_1440 = 72
CTA_DUP_DTD = 128 + 103


def std_timing(width, refresh, aspect_bits=0b00):
    return bytes([width // 8 - 31, (aspect_bits << 6) | (refresh - 60)])


def dtd(pclk_khz, h, hfp, hsync, htot, v, vfp, vsync, vtot, size_mm, flags):
    hb, vb = htot - h, vtot - v
    hmm, vmm = size_mm
    return bytes([
        (pclk_khz // 10) & 0xFF, (pclk_khz // 10) >> 8,
        h & 0xFF, hb & 0xFF, (h >> 8) << 4 | hb >> 8,
        v & 0xFF, vb & 0xFF, (v >> 8) << 4 | vb >> 8,
        hfp & 0xFF, hsync & 0xFF, (vfp & 0xF) << 4 | (vsync & 0xF),
        (hfp >> 8) << 6 | (hsync >> 8) << 4 | (vfp >> 4) << 2 | vsync >> 4,
        hmm & 0xFF, vmm & 0xFF, (hmm >> 8) << 4 | vmm >> 8,
        0, 0, flags,
    ])


def dtd_size_mm(block, off):
    d = block[off:off + 18]
    return (d[12] | (d[14] >> 4) << 8, d[13] | (d[14] & 0xF) << 8)


def fix_checksums(b):
    for i in range(0, len(b), 128):
        b[i + 127] = (-sum(b[i:i + 127])) % 256


def build():
    b = bytearray(SRC.read_bytes())
    assert len(b) == 256 and b[126] == 1, "unexpected steamdeck.bin layout"
    assert b[CTA_DUP_DTD:CTA_DUP_DTD + 18] == b[72:90], "CTA DTD is no longer a duplicate"
    b[STD_TIMINGS + 0:STD_TIMINGS + 2] = std_timing(1920, 60)
    b[STD_TIMINGS + 6:STD_TIMINGS + 8] = std_timing(1920, 90)
    # cvt -r 1920 1200 120: 317.00  1920 1968 2000 2080  1200 1203 1209 1271 +hsync -vsync
    b[CTA_DUP_DTD:CTA_DUP_DTD + 18] = dtd(
        317000, 1920, 48, 32, 2080, 1200, 3, 6, 1271,
        dtd_size_mm(b, 54), flags=0b00011010)
    # CVT-RB 2560x1440@90: 367.93  2560 2608 2640 2720  1440 1443 1448 1503 +hsync -vsync
    b[BASE_DTD_1440:BASE_DTD_1440 + 18] = dtd(
        367930, 2560, 48, 32, 2720, 1440, 3, 5, 1503,
        dtd_size_mm(b, BASE_DTD_1440), flags=0b00011010)
    fix_checksums(b)
    return bytes(b)


def main():
    out = build()
    if sys.argv[1:] == ["--check"]:
        if DST.read_bytes() != out:
            sys.exit(f"{DST.name} is stale: rerun {pathlib.Path(__file__).name}")
        print(f"{DST.name} matches")
        return
    DST.write_bytes(out)
    print(f"wrote {DST}")


if __name__ == "__main__":
    main()
