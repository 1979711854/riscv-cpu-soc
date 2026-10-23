#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 trace_fig2_raw.txt 里挑一个"信息量最大"的 48 拍窗口画图 2。

评分 = 窗口内各类事件的覆盖度（每类封顶计入，避免单一事件刷分）：
  stall / 多拍停顿 / 冲刷 / 误预测 / 重定向 / 前递(EX) / 前递(WB) / 访存 / 分支
输出：窗口起始行号 + 该窗口的 T 行切片（写到 trace_fig2_win.txt）。
"""
import sys

SRC = "sim/programs/trace_fig2_raw.txt"
DST = "sim/programs/trace_fig2_win.txt"
W = 48

rows = []
with open(SRC, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line.startswith("T "):
            continue
        rec = {}
        for tok in line[2:].split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                rec[k] = v
        rows.append((line, rec))

def b(rec, k):
    return rec.get(k, "0") == "1"

def score(window):
    recs = [r for _, r in window]
    s = 0.0
    # 每类事件：有就加分，数量封顶（>3 次不再多给）
    for key in ("st", "dv", "fl", "fd", "ir"):
        n = sum(1 for r in recs if b(r, key))
        s += min(n, 3)
    fwd = sum(1 for r in recs if b(r, "faex") or b(r, "fbex") or b(r, "fawb") or b(r, "fbwb"))
    s += min(fwd // 4, 4)
    mem = sum(1 for r in recs if b(r, "mwe") or b(r, "mre"))
    s += min(mem // 3, 4)
    br = sum(1 for r in recs if b(r, "br"))
    s += min(br // 3, 3)
    # 提交密度（v_wb）越高越好：说明这段是真干活，不是一坨气泡
    s += sum(1 for r in recs if b(r, "vwb")) / W * 3
    # 两类分支恢复事件（冲刷 fl / 误预测恢复 fd）最好都出现，图才有教学价值
    n_fl = sum(1 for r in recs if b(r, "fl"))
    n_fd = sum(1 for r in recs if b(r, "fd"))
    if n_fl and n_fd:
        s += 6
    elif n_fl or n_fd:
        s += 2
    return s

best, best_i = -1, 0
for i in range(0, len(rows) - W + 1):
    sc = score(rows[i:i + W])
    if sc > best:
        best, best_i = sc, i

win = rows[best_i:best_i + W]
with open(DST, "w", encoding="utf-8") as f:
    for line, _ in win:
        f.write(line + "\n")

recs = [r for _, r in win]
ev = {k: sum(1 for r in recs if b(r, k)) for k in ("st", "dv", "fl", "fd", "ir", "br", "mwe", "mre")}
fwd = sum(1 for r in recs if b(r, "faex") or b(r, "fbex") or b(r, "fawb") or b(r, "fbwb"))
print(f"总行数 {len(rows)}，选窗口 行 {best_i}..{best_i+W-1}  cyc={recs[0].get('cyc')}..{recs[-1].get('cyc')}  score={best:.1f}")
print(f"事件: {ev}  前递拍={fwd}  提交拍(vwb)={sum(1 for r in recs if b(r,'vwb'))}")
print(f"切片 -> {DST}")
