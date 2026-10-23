# -*- coding: utf-8 -*-
"""analyze_ila.py —— 把 Fabric Debugger 导出的 VCD 变成"流水线效率"指标。

用途：赛事要求"利用 ILA 波形分析 CPU 执行 CoreMark 关键算法时的流水线效率"。
本脚本不做画面，只产出可写进报告的表：

    * 采样窗口周期数、提交指令数、IPC
    * 停顿（load-use / 除法）占比、分支冲刷次数与占比
    * 双发射配对率、前递命中率（有探针时才算）

信号按名字关键字匹配，因此新旧两版探针束都能用：

    提交 A      mem_wb_we / memwbregwrite
    提交 B      mem_wb_b_we / memwbbregwrite      （缺失时按单发射算）
    停顿        stall（排除 div_stall）
    冲刷        ex_flush
    配对        pair_now + if_id_pair
    前递        fwd_a_ex / fwd_b_ex / fwd_a_wb / fwd_b_wb

用法：
    python scripts/analyze_ila.py doc/board/ila_hw_xxx.vcd
    python scripts/analyze_ila.py <vcd> --md out.md
"""
import argparse
import io
import re
import sys

# ---------------------------------------------------------------- VCD 解析 ----


def parse_vcd(path):
    """返回 (signals, samples)；signals=[(name,width)]，samples=[{id: value}]。"""
    names = {}          # id -> (name, width)
    samples = []
    cur = {}
    in_header = True

    def flush():
        if cur:
            samples.append(dict(cur))

    txt = io.open(path, encoding="utf-8", errors="replace").read()
    # 头部 $var
    for w, vid, name in re.findall(r"\$var\s+wire\s+(\d+)\s+(\S+)\s+(\S+)", txt):
        names[vid] = (name, int(w))
    body = txt.split("$enddefinitions $end", 1)
    if len(body) < 2:
        return [], []
    lines = body[1].splitlines()

    for line in lines:
        line = line.strip()
        if not line or line.startswith("$"):
            continue
        if line[0] == "#":
            flush()
            cur.clear()
            continue
        if line[0] in "bB":
            try:
                bits, vid = line[1:].split()
            except ValueError:
                continue
            cur[vid] = int(bits.replace("x", "0").replace("z", "0"), 2)
            continue
        if line[0] in "01xXzZ":
            cur[line[1:]] = 1 if line[0] == "1" else 0
            continue
    flush()

    # 去掉首尾空样本
    signals = [(vid, n, w) for vid, (n, w) in names.items()]
    return signals, samples


# ---------------------------------------------------------------- 信号匹配 ----

KEYS = {
    "commit_a": ("mem_wb_we", "memwbregwrite", "mem_wb_reg_write"),
    "commit_b": ("mem_wb_b_we", "memwbbregwrite", "mem_wb_b_reg_write"),
    "stall": ("stall",),
    "div_stall": ("div_stall",),
    "flush": ("ex_flush",),
    "pair": ("pair_now", "pairnow"),
    "if_id_pair": ("if_id_pair", "ifidpair"),
    "laneb_valid": ("ex_mem_b_valid", "exmembvalid"),
    "fwd": ("fwd_a_ex", "fwd_b_ex", "fwd_a_wb", "fwd_b_wb"),
    "bht_hit": ("bht_hit",),
    "bht_taken": ("bht_taken",),
    "mispred": ("mispred",),
}


def norm(s):
    return re.sub(r"[^a-z0-9_]", "", s.lower())


# Fabric Debugger 若没加载 .fic，波形里只显示 DataPort[<通道号>]。
# 这里按 ila_probes.vh 的通道表把序号还原成逻辑名，保证两种导出都能分析。
DATA_PORT_MAP = {}
for _i in range(0, 15):
    DATA_PORT_MAP[_i] = "pc[%d]" % _i
for _i in range(15, 30):
    DATA_PORT_MAP[_i] = "if_id_pc[%d]" % (_i - 15)
for _i in range(30, 45):
    DATA_PORT_MAP[_i] = "id_ex_pc[%d]" % (_i - 30)
for _i in range(45, 60):
    DATA_PORT_MAP[_i] = "ex_mem_pc[%d]" % (_i - 45)
for _i in range(60, 67):
    DATA_PORT_MAP[_i] = "if_id_instr[%d]" % (_i - 60)
DATA_PORT_MAP.update({
    67: "stall", 68: "div_stall", 69: "ex_flush", 70: "id_ex_mem_read",
    71: "fwd_a_ex", 72: "fwd_b_ex", 73: "fwd_a_wb", 74: "fwd_b_wb",
    75: "id_ex_branch", 76: "branch_taken", 77: "mem_we", 78: "mem_re",
    79: "mem_wb_reg_write", 80: "bht_hit_p", 81: "bht_taken_p",
    82: "p_pred_taken", 83: "p_redirect", 84: "ex_mispred",
    85: "id_ex_pred_taken", 86: "pair_now", 87: "if_id_pair",
    88: "ex_mem_b_valid", 89: "p_ras_hit", 90: "p_btb_pred",
    91: "mem_wb_b_reg_write",
})


def unalias(signals):
    """把 DataPort[n] 换成逻辑名；已经是逻辑名的原样保留。"""
    out, hit = [], 0
    for vid, name, width in signals:
        m = re.match(r"^DataPort\[(\d+)\]$", name.strip())
        if m and int(m.group(1)) in DATA_PORT_MAP:
            out.append((vid, DATA_PORT_MAP[int(m.group(1))], width))
            hit += 1
        else:
            out.append((vid, name, width))
    if hit:
        print("[i] 按通道表还原了 %d 个 DataPort 名字" % hit)
    return out


def build_index(signals):
    idx = {}
    normed = [(vid, norm(name)) for vid, name, _ in signals]
    for key, pats in KEYS.items():
        found = []
        for vid, n in normed:
            if key == "stall":
                if n.endswith("stall") and "div" not in n:
                    found.append(vid)
            elif any(p in n for p in pats):
                found.append(vid)
        idx[key] = found
    return idx


# ---------------------------------------------------------------- 统计 ----


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("--md", help="把结果另存为 markdown")
    args = ap.parse_args()

    signals, samples = parse_vcd(args.vcd)
    if not samples:
        print("[!] 解析失败：没有采到样本")
        return 1

    signals = unalias(signals)
    idx = build_index(signals)
    print("VCD:", args.vcd)
    print("信号数:", len(signals), "  样本数（周期）:", len(samples))

    missing = [k for k in ("commit_a", "stall", "flush") if not idx.get(k)]
    if missing:
        print("[!] 缺少关键信号:", missing)
    for k in ("commit_b", "pair", "fwd", "bht_hit"):
        if not idx.get(k):
            print("[i] 无", k, "探针 —— 该项指标跳过")

    def bit(ids, smp):
        v = 0
        for vid in ids:
            v |= smp.get(vid, 0) & 1
        return v

    cycles = len(samples)
    commits = sum(bit(idx["commit_a"], s) + bit(idx["commit_b"], s) for s in samples)
    stall = sum(1 for s in samples if bit(idx["stall"], s))
    div = sum(1 for s in samples if bit(idx["div_stall"], s))
    flush = sum(1 for s in samples if bit(idx["flush"], s))
    pair = sum(1 for s in samples if bit(idx["pair"], s) and bit(idx["if_id_pair"], s))
    laneb = sum(1 for s in samples if bit(idx["laneb_valid"], s))
    fwd = sum(1 for s in samples if bit(idx["fwd"], s))
    bhit = sum(1 for s in samples if bit(idx["bht_hit"], s) and bit(idx["bht_taken"], s))
    mis = sum(1 for s in samples if bit(idx["mispred"], s))

    def pct(n):
        return "%.1f%%" % (100.0 * n / cycles) if cycles else "-"

    rows = [
        ("采样周期数", "%d" % cycles),
        ("提交指令数", "%d" % commits),
        ("IPC", "%.2f" % (commits / cycles) if cycles else "-"),
        ("load-use 停顿拍", "%d（%s）" % (stall, pct(stall))),
        ("除法停顿拍", "%d（%s）" % (div, pct(div))),
        ("分支冲刷次数", "%d（%s）" % (flush, pct(flush))),
    ]
    if idx.get("pair"):
        rows.append(("双发射配对拍", "%d（%s）" % (pair, pct(pair))))
        rows.append(("lane B 有效拍", "%d（%s）" % (laneb, pct(laneb))))
    if idx.get("fwd"):
        rows.append(("前递生效拍", "%d（%s）" % (fwd, pct(fwd))))
    if idx.get("bht_hit"):
        rows.append(("BHT 命中且预测跳转", "%d" % bhit))
        rows.append(("BHT 误判", "%d" % mis))

    md = ["| 指标 | 值 |", "|---|---|"]
    for k, v in rows:
        md.append("| %s | %s |" % (k, v))
        print("%-20s %s" % (k, v))

    if args.md:
        io.open(args.md, "w", encoding="utf-8").write("\n".join(md) + "\n")
        print("\n写出:", args.md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
