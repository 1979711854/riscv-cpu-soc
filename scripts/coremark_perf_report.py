#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
coremark_perf_report.py —— 解析 sim/tb_coremark.v 的 +PROF 输出，打印与其他参赛组
同口径的 CoreMark 性能报表。

背景与口径（重要，先读再改）：
  * 我们的 +PROF 原有 "region commit" 计的是【提交拍数】（影子链 v_wb 每拍≤1，
    双发射的第二条不计）—— 2026-10-16 发现它会低估双发贡献、把 IPC 算成 0.899。
    现 tb 已增加 "region instr"（提交【指令条数】，一对到 WB 计 2）⇒
    **IPC = region instr ÷ region cycles**，与对手打印的
    "Total instructions ÷ Total cycles / IPC" 同口径。
  * 对手的 "Stalled frontend/backend cycles" 是整拍停顿口径；我们的是
    "无提交拍归因"（七桶）。两者近似而非严格相等，报表中分开标注。
  * 我们没有 I/D Cache（单周期片内 BRAM，取指/访存从不缺失）⇒ Cache 类指标
    在本设计上恒为零缺失，如实打印 N/A。

用法：
    python scripts/coremark_perf_report.py <prof_output.txt>     # 单份报表
    python scripts/coremark_perf_report.py <prof_output.txt> --compare   # 带两组参考数据对比
    cat prof.txt | python scripts/coremark_perf_report.py -      #  stdin

输入即 `vvp ... "+PROF"` 的 stdout（可含直方图等无关行，解析只认键值行）。
"""

import re
import sys

# ---------------------------------------------------------------------------
# 参考组数据（2026-10-16 用户提供的另外两组串口原文摘录，仅此两处硬编码；
# 换数据只改这里）。ticks 口径 IPC = instructions/ticks（他们打印的 IPC 用的
# 是 Total cycles 口径，比 ticks 宽约 19%，不可直接比——详见 doc 对比表）。
# ---------------------------------------------------------------------------
REF_GROUPS = [
    {
        "name": "参考组①（-O3, GCC16.2, rv32imc）",
        "freq_mhz": 90.0,
        "iters": 6000,
        "ticks": 1210239431,
        "instr": 1946712287,
        "cycles": 1441295128,
        "br_miss": None,           # 该组串口未给分支数/失败数
        "br_count": None,
        "fe_stall": 71243962,
        "be_stall": 265084387,
        "ic_miss": 543,
        "dc_miss": 5135,
        "printed_ipc": 1.350,
        "src": "用户提供 2026-10-16 串口原文",
    },
    {
        "name": "参考组②（-O2 -g, GCC16.2, rv32imc）",
        "freq_mhz": 83.5,
        "iters": 6000,
        "ticks": 1423553432,
        "instr": 1930090597,
        "cycles": 1691325421,
        "br_miss": 19025135,
        "br_count": 347259390,
        "fe_stall": 126357495,
        "be_stall": None,          # 该组串口未给后端停顿
        "ic_miss": 141,
        "dc_miss": 390393,
        "printed_ipc": 1.141,
        "src": "用户提供 2026-10-16 串口原文",
    },
]

# 我们：ticks 口径的 IPC = instr/ticks（与上表同算法）
# 无提交拍 → frontend/backend 映射（近似口径，报表内注明）


def _num(s):
    """值行开头取第一个整数（容忍 '14218  6.549418%' / '195094  (提交拍数…)' /
    '4009  (= 真分支代价的尾巴)' / '1403' 等尾巴形式），返回 (int, pct|None)。"""
    s = s.strip()
    m = re.match(r"^(-?\d+)", s)
    if not m:
        return None, None
    n = int(m.group(1))
    mp = re.search(r"([0-9]+\.?[0-9]*)\s*%", s)
    pct = float(mp.group(1)) if mp else None
    return n, pct


def parse_prof(text):
    """从 +PROF 输出抓键值。键统一去空白、去 [!] 前缀；后写的同键行覆盖先写的
    （region 段在全局段之后打印 ⇒ region 口径自然覆盖全局口径）。"""
    d = {}
    for line in text.splitlines():
        # 形如 "region cycles    : 217088" / "  load-use 占    : 110"
        m = re.match(r"^\s*([^:]+?)\s*:\s*(.+?)\s*$", line)
        if not m:
            continue
        key = re.sub(r"\s+", "", m.group(1)).replace("[!]", "")
        val = m.group(2)
        n, pct = _num(val)
        if n is not None:
            d[key] = n
            if pct is not None:
                d[key + "%"] = pct
            continue
        # 浮点行：region IPC / CPI / CoreMark/MHz 等
        mf = re.match(r"^(-?\d+\.\d+)", val.strip())
        if mf:
            d[key] = float(mf.group(1))
    return d


def g(d, *keys, default=0):
    for k in keys:
        if k in d:
            return d[k]
    return default


def report(d, compare=False):
    L = []
    ticks = g(d, "Totalticks", "regioncycles")
    instr = g(d, "regioninstr")
    slots = g(d, "regioncommit")
    cycles = ticks  # 我们的计时区 cycles 就是 ticks（同时钟）

    ipc = instr / cycles if cycles else 0.0
    cpi = cycles / instr if instr else 0.0
    cm_mhz = 1e6 / ticks if ticks else 0.0

    # ---- 分支（计时区口径；tb 已有 region 级 cond/jal/jalr/mispredict）----
    br_cond = g(d, "condbranches")
    br_taken = g(d, "taken")
    jal = g(d, "jal")
    jalr = g(d, "jalr")
    br_count = br_cond + jal + jalr
    br_miss = g(d, "mispredict")          # region 段的 mispredict（EX 解析口径）
    br_rate = 100.0 * br_miss / br_count if br_count else 0.0

    # ---- 停顿映射（无提交拍归因 → 他们的 frontend/backend 近似口径）----
    flush_now = g(d, "冲刷当拍占")
    flush_tail = g(d, "冲刷后3拍内")
    redir_tail = g(d, "预测重定向后")
    nofetch = g(d, "其中IF/ID空")
    mc = g(d, "mc_stall占")
    loaduse = g(d, "load-use占")
    stall_tail = g(d, "停顿后4拍内")
    mem_freeze = g(d, "访存冻结")
    dark = g(d, "真正无解释")
    fe = flush_now + flush_tail + redir_tail                 # 控制/取供相关
    # 注：nofetch（IF/ID 空）是七桶之上的重叠子项，不计入 fe（否则分桶和 > noretire）
    be = mc + loaduse + stall_tail + mem_freeze              # 数据/执行相关
    noret = g(d, "regionnoretire")
    stall = g(d, "regionstall")
    fe_rate = 100.0 * fe / cycles if cycles else 0.0
    be_rate = 100.0 * be / cycles if cycles else 0.0

    L.append("=" * 68)
    L.append("CoreMark 性能报表（本设计 · 仿真层 +PROF，计时区间口径）")
    L.append("=" * 68)
    L.append("Total ticks            : %d" % ticks)
    L.append("Total instructions     : %d   (提交指令条数，双发拍计 2)" % instr)
    L.append("IPC                    : %.3f   (instructions/cycles)" % ipc)
    L.append("CPI                    : %.3f   (cycles/instruction)" % cpi)
    L.append("commit slots           : %d   (提交拍数，每拍≤1；旧口径，保留对照)" % slots)
    L.append("CoreMark/MHz (主分)    : %.4f   (= 10^6 / ticks)" % cm_mhz)
    L.append("-" * 68)
    L.append("I-Cache miss           : N/A  (无 I-Cache：单周期 BRAM，取指从不缺失)")
    L.append("D-Cache load miss      : N/A  (无 D-Cache：单周期 BRAM，访存 1 拍契约)")
    L.append("Branch count           : %d   (cond %d + jal %d + jalr %d)"
             % (br_count, br_cond, jal, jalr))
    L.append("Branch miss            : %d" % br_miss)
    L.append("Branch mispredict rate : %.3f%%" % br_rate)
    L.append("Stalled frontend cycles: %d   (≈ 冲刷 %d + 冲刷尾 %d + 重定向尾 %d；另 IF/ID 空 %d 为重叠子项不计入)"
             % (fe, flush_now, flush_tail, redir_tail, nofetch))
    L.append("Stalled frontend rate  : %.3f%%" % fe_rate)
    L.append("Stalled backend cycles : %d   (≈ mc %d + load-use %d + 停顿尾 %d + 访存冻结 %d)"
             % (be, mc, loaduse, stall_tail, mem_freeze))
    L.append("Stalled backend rate   : %.3f%%" % be_rate)
    L.append("-" * 68)
    L.append("附：无提交拍 %d (%.1f%%) = frontend %d + backend %d + 未归因 dark %d；"
             "其中 stall %d (%.1f%%)、flush %d (%.1f%%)、mul %d 条"
             % (noret, 100.0 * noret / cycles if cycles else 0, fe, be, dark,
                stall, 100.0 * stall / cycles if cycles else 0,
                g(d, "regionflush"), g(d, "regionflush%"), g(d, "regionmulexec")))
    L.append("口径注：他们的 frontend/backend 为整拍停顿；本表为无提交拍归因的近似映射。")

    if compare:
        L.append("")
        L.append("=" * 68)
        L.append("与参考组对比（ticks 口径 = 各自串口 Total ticks，与主分同源）")
        L.append("=" * 68)
        L.append("%-26s %10s %10s %8s %9s" % ("组", "拍/迭代", "指令/迭代", "IPC", "CoreMark/MHz"))
        rows = [("本设计（ ours ）", ticks, instr, ipc, cm_mhz)]
        for rg in REF_GROUPS:
            tpi = rg["ticks"] / rg["iters"]
            ipi = rg["instr"] / rg["iters"]
            ripc = rg["instr"] / rg["ticks"]
            rcm = 1e6 / tpi
            rows.append((rg["name"], tpi, ipi, ripc, rcm))
        for name, tpi, ipi, ripc, rcm in rows:
            L.append("%-26s %10.0f %10.0f %8.3f %9.4f" % (name, tpi, ipi, ripc, rcm))
        L.append("-" * 68)
        L.append("注：参考组的 cycles 口径比 ticks 宽约 19%（其打印 IPC 1.350/1.141 用的是")
        L.append("    Total cycles）；本表统一用 ticks 口径，与赛题主分公式同源可比。")
        L.append("    参考组数据为硬编码于本脚本 REF_GROUPS（来源：用户 2026-10-16 提供）。")
    L.append("")
    return "\n".join(L)


def main():
    args = [a for a in sys.argv[1:]]
    compare = "--compare" in args
    args = [a for a in args if a != "--compare"]
    if not args or args[0] == "-":
        text = sys.stdin.read()
    else:
        with open(args[0], "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    d = parse_prof(text)
    if "regioncycles" not in d and "Totalticks" not in d:
        sys.stderr.write("!! 没解析到 region cycles / Total ticks —— 输入是 +PROF 输出吗？\n")
        sys.exit(1)
    print(report(d, compare=compare))


if __name__ == "__main__":
    main()
