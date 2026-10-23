#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_bmp2png.py —— 把 preview 生成的 24 位 BMP 转成 PNG（无 PIL 依赖）。

用法:
    python -I sim/tools/_bmp2png.py doc/board/preview_title.bmp [more.bmp ...]

BMP: 54 字节头 + bottom-up 24bpp（640x480 行宽 1920 天然 4 对齐，预览工具输出）。
PNG: 手写 encoder（zlib + struct），color type 2（真彩 RGB）、filter 0。
"""
import struct
import sys
import zlib


def bmp_to_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"BM":
        raise SystemExit("%s: not a BMP" % path)
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    if bpp != 24:
        raise SystemExit("%s: expect 24bpp, got %d" % (path, bpp))
    row_raw = ((w * 3 + 3) // 4) * 4          # BMP 行 4 字节对齐
    rows = []
    for y in range(h - 1, -1, -1):            # bottom-up -> top-down
        base = offset + y * row_raw
        row = bytearray()
        for x in range(w):
            b, g, r = data[base + x * 3: base + x * 3 + 3]
            row += bytes((r, g, b))           # BGR -> RGB
        rows.append(b"\x00" + bytes(row))     # filter 0 + 行数据

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
           + chunk(b"IEND", b""))
    out = path[: path.rfind(".")] + ".png"
    with open(out, "wb") as f:
        f.write(png)
    print("PNG ->", out)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        bmp_to_png(p)
