#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""提取 tb_laneb_ld 反汇编中 0x40~0x300 的指令，供图 3 标注。"""
import re

for line in open('doc/reports/fig3_laneb_ld_disasm.txt', encoding='utf-16', errors='replace'):
    m = re.match(r'\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)', line)
    if m:
        a = int(m.group(1), 16)
        if 0x40 <= a < 0x300:
            print(m.group(1), m.group(3).strip())
