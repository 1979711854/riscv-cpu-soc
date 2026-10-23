#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 tb_coremark.v 的 +TRACE 逐拍输出渲染成流水线时序波形 SVG。

用法（在仓库根目录）:
    python scripts/trace2svg.py sim/programs/trace.txt doc/figures/pipeline_waveform.svg

配套流程（抓一段 CoreMark 关键循环的波形）:
    1) scripts\\run_coremark.ps1 -Iter 1 -SkipSim   # 确保固件与 vvp 就绪
    2) cd sim && vvp tb_coremark.vvp "+ITER=1" "+IMEM=programs/imem.hex" \
           "+DMEM=programs/dmem.hex" "+PROF" "+TRACE_START=<起始拍>" "+TRACE_LEN=40"
       （注意 +TRACE_* 受 +PROF 门控，掉了 +PROF 会一个字符都写不出来）
    3) python scripts/trace2svg.py sim/programs/trace.txt doc/figures/pipeline_waveform.svg

设计说明: 图分两块 —— 上半是五级流水的"占用格"(每格一条指令，格内是 PC 低 4 位十六进制)，
下半是控制信号的电平波形。stall / flush 周期用整列底色标出，方便一眼定位气泡来源。

想找窗口就先抓一大段（+TRACE_LEN 给足）再用本脚本切 —— 不必先猜。例如：
    vvp ... "+PROF" "+TRACE_START=21000" "+TRACE_LEN=395000" "+TRACE_FILE=programs/trace_full.txt"
"""
import argparse
import sys
from xml.sax.saxutils import escape

STAGES = [
    ("IF  取指", "pc", "vid_if"),
    ("ID  译码", "ipc", "vid"),
    ("EX  执行", "epc", "vex"),
    ("MEM 访存", "mpc", "vmem"),
    ("WB  写回", "wrd", "vwb"),
]

# (显示名, 取值字段或组合键, 说明)
# 注意：2026-09-21 取指重定向改造后 ex_flush_d 已从设计里删除，
# 旧版本这里有一条 "冲刷第 2 拍 / fd" 的 lane —— 而 tb 的 +TRACE 输出
# 从来没有 fd 字段，那条线一直恒为 0，属于无效 lane。现改为真实存在的信号。
BIT_LANES = [
    ("load-use 停顿", "st", "amber"),
    ("分支/跳转冲刷", "fl", "red"),
    ("分支指令 (EX)", "br", "purple"),
    ("分支 taken", "br_taken", "purple"),
    ("jal / jalr", "jump", "purple"),
    ("前递 EX/MEM", "fwd_ex", "blue"),
    ("前递 MEM/WB", "fwd_wb", "blue"),
    ("MEM 读 (lw/lb)", "mre", "teal"),
    ("MEM 写 (sw/sb)", "mwe", "teal"),
]

PALETTE = {
    "bg": "#FAFAFA",
    "grid": "#E2E2E2",
    "text": "#1F1F1F",
    "muted": "#7A7A7A",
    "cell": "#DCE9F7",
    "cell_alt": "#CFE0F2",
    "bubble": "#F0F0F0",
    "amber": "#BA7517",
    "red": "#A32D2D",
    "blue": "#185FA5",
    "purple": "#6B3FA0",
    "teal": "#0F6E56",
}


def parse_trace(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("T "):
                continue
            rec = {}
            for tok in line[2:].split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    rec[k] = v
            if "cyc" in rec:
                rows.append(rec)
    return rows


def bit(rec, key):
    return rec.get(key, "0") == "1"


def value(rec, key):
    """取字段值，截成低位 4 位十六进制（程序 < 32KB，PC 够用）。"""
    raw = rec.get(key, "")
    return raw[-4:] if len(raw) > 4 else raw


def lane_state(rec, key):
    if key == "fwd_ex":
        return bit(rec, "faex") or bit(rec, "fbex")
    if key == "fwd_wb":
        return bit(rec, "fawb") or bit(rec, "fbwb")
    # branch_taken 是比较器的裸结果，非分支指令上也可能为 1，
    # 所以必须与 id_ex_branch（br）相与，才是"这条分支真的跳了"。
    if key == "br_taken":
        return bit(rec, "br") and bit(rec, "bt")
    if key == "jump":
        return bit(rec, "jmp") or bit(rec, "jr")
    return bit(rec, key)


def render(rows, out_path, cell_w=30, label_w=150, title=None):
    n = len(rows)
    if n == 0:
        raise SystemExit("trace 文件里没有解析到任何 T 行")

    top_off = 34 if title else 0   # 有标题时整体下移，避免压住周期号表头
    head_h = 26          # 周期号表头
    stage_h = 34         # 每级流水格高
    gap_h = 12
    lane_h = 20          # 每条控制信号高
    pad = 16

    y_stage0 = top_off + head_h + 4
    y_lanes0 = y_stage0 + len(STAGES) * stage_h + gap_h
    h = y_lanes0 + len(BIT_LANES) * lane_h + pad + 18
    w = label_w + n * cell_w + pad

    # 画布至少能放下标题（CJK 按 14px/字、ASCII 按 8px/字 估算）
    if title:
        need = sum(14 if ord(ch) > 0x2E80 else 8 for ch in title) + 2 * pad
        w = max(w, need)

    out = []
    a = out.append
    # 字体：根字体必须把中文字体排在前面，否则 latin 字体（Consolas/Menlo）会
    # 被优先命中而中文渲染成方框。十六进制数值格单独指定等宽字体，对齐更好看。
    a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
      f'font-family="Microsoft YaHei, Noto Sans CJK SC, PingFang SC, sans-serif">')
    mono = "Consolas, Menlo, monospace"
    a(f'<rect x="0" y="0" width="{w}" height="{h}" fill="{PALETTE["bg"]}"/>')

    if title:
        a(f'<text x="{pad}" y="{pad + 4}" font-size="14" font-weight="600" '
          f'fill="{PALETTE["text"]}">{escape(title)}</text>')

    # ---- stall / flush 整列底色（先画，压在最底层）----
    for i, rec in enumerate(rows):
        x = label_w + i * cell_w
        band_h = y_lanes0 - head_h + len(BIT_LANES) * lane_h
        if bit(rec, "st") or bit(rec, "dv"):
            a(f'<rect x="{x}" y="{head_h + top_off}" width="{cell_w}" height="{band_h}" '
              f'fill="{PALETTE["amber"]}" opacity="0.10"/>')
        if bit(rec, "fl"):
            a(f'<rect x="{x}" y="{head_h + top_off}" width="{cell_w}" height="{band_h}" '
              f'fill="{PALETTE["red"]}" opacity="0.10"/>')

    # ---- 表头：周期号。每格都标会连成一片看不清，按标签宽度定步长 ----
    sample = rows[0].get("cyc", "0")
    # 6 位数字在 font-size=10 的等宽字体下约 6px/字符；留 8px 间隙
    need_px = len(sample) * 6 + 8
    step = max(1, -(-need_px // cell_w))          # 向上取整
    if n // step > 10:                            # 标签仍太密就再稀释
        step = max(step, -(-n // 10))
    for i, rec in enumerate(rows):
        if i % step:
            continue
        x = label_w + i * cell_w
        a(f'<text x="{x}" y="{top_off + head_h - 9}" font-size="10" '
          f'font-family="{mono}" '
          f'fill="{PALETTE["muted"]}">{escape(rec["cyc"])}</text>')

    # ---- 五级流水占用格 ----
    for r, (name, field, vkey) in enumerate(STAGES):
        y = y_stage0 + r * stage_h
        a(f'<text x="{pad}" y="{y + stage_h/2 + 4}" font-size="12" fill="{PALETTE["text"]}">{escape(name)}</text>')
        for i, rec in enumerate(rows):
            x = label_w + i * cell_w
            valid = True if vkey == "vid_if" else bit(rec, vkey)
            if valid:
                fill = PALETTE["cell"] if r % 2 == 0 else PALETTE["cell_alt"]
                a(f'<rect x="{x+0.5}" y="{y+2.5}" width="{cell_w-1}" height="{stage_h-5}" '
                  f'rx="3" fill="{fill}" stroke="{PALETTE["grid"]}" stroke-width="0.5"/>')
                val = value(rec, field)
                if val:
                    a(f'<text x="{x + cell_w/2}" y="{y + stage_h/2 + 4}" font-size="11" '
                      f'font-family="{mono}" text-anchor="middle" '
                      f'fill="{PALETTE["text"]}">{escape(val)}</text>')
            else:
                a(f'<rect x="{x+0.5}" y="{y+2.5}" width="{cell_w-1}" height="{stage_h-5}" '
                  f'rx="3" fill="{PALETTE["bubble"]}" stroke="{PALETTE["grid"]}" '
                  f'stroke-width="0.5" stroke-dasharray="2 2"/>')

    # ---- 控制信号电平波形 ----
    for r, (name, key, color) in enumerate(BIT_LANES):
        y = y_lanes0 + r * lane_h
        y_hi = y + 3
        y_lo = y + lane_h - 4
        a(f'<text x="{pad}" y="{y + lane_h/2 + 4}" font-size="12" fill="{PALETTE["text"]}">{escape(name)}</text>')
        # 基线
        a(f'<line x1="{label_w}" y1="{y_lo}" x2="{label_w + n*cell_w}" y2="{y_lo}" '
          f'stroke="{PALETTE["grid"]}" stroke-width="0.5"/>')
        # 逐拍折线
        pts = []
        for i, rec in enumerate(rows):
            hi = lane_state(rec, key)
            x1 = label_w + i * cell_w
            x2 = x1 + cell_w
            lvl = y_hi if hi else y_lo
            if not pts:
                pts.append((x1, lvl))
            else:
                if pts[-1][1] != lvl:
                    pts.append((x1, pts[-1][1]))
                    pts.append((x1, lvl))
            pts.append((x2, lvl))
        d = " ".join(f"{px:.1f},{py:.1f}" for px, py in pts)
        a(f'<polyline points="{d}" fill="none" stroke="{PALETTE[color]}" stroke-width="1.6"/>')

    a('</svg>')
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    return w, h


def main():
    ap = argparse.ArgumentParser(description="trace -> 流水线时序波形 SVG")
    ap.add_argument("trace", help="+TRACE 输出文件")
    ap.add_argument("out", help="输出 SVG 路径")
    ap.add_argument("--cell", type=int, default=30, help="每拍像素宽（默认 30）")
    ap.add_argument("--title", default=None, help="图标题")
    args = ap.parse_args()

    rows = parse_trace(args.trace)
    w, h = render(rows, args.out, cell_w=args.cell, title=args.title)
    stall = sum(1 for r in rows if bit(r, "st") or bit(r, "dv"))
    flush = sum(1 for r in rows if bit(r, "fl"))
    print(f"解析 {len(rows)} 拍 -> {args.out} ({w}x{h})")
    print(f"窗口内: stall {stall} 拍, flush {flush} 拍")


if __name__ == "__main__":
    main()
