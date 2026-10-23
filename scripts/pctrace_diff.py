#!/usr/bin/env python3
"""pctrace_diff.py —— 两份 PC trace 对拍，找第一条分叉并打印原始逐拍上下文。

用法：
    python scripts/pctrace_diff.py sim/pctrace_nocache.txt sim/pctrace_icache.txt

背景（2026-10-14，rtthread + Cache 挂死定位）：
    tb_rtthread 的 -DPCTRACE 每个 negedge 记一行 pc（= 原始行号即拍号偏移）。
    同一固件跑"无 Cache / 带 Cache"两份：
      * Cache 停顿会让 pc 原地重复 ⇒ 先折叠【连续重复】得到指令序列再对拍；
      * 第一处分叉 = Cache 开始取错指令 / 执行流走偏的位置。
    然后【回到原始逐拍】打印分叉点前后各若干拍 —— 那里能看到停顿/重定向的
    真实形状（pc 重复几拍、跳过哪些地址），是判断"哪一拍取错了"的关键。

    [!] 双发射机型上 pc 口只给 lane A 的地址 ⇒ 折叠后的序列本来就会"跳号"
        （lane B 的地址不在里面）。判断错指令时要拿【分叉那拍的实际 pc】
        去 objdump 对照，别拿折叠序列的相邻项当顺序执行。
"""
import sys


def collapse_with_map(path):
    """折叠连续重复 pc；返回 (序列, 序列每项对应的原始行号)。"""
    seq, rawpos = [], []
    prev = None
    with open(path, "r") as f:
        for i, line in enumerate(f):
            p = line.strip()
            if not p:
                continue
            if p != prev:
                seq.append(p)
                rawpos.append(i)
                prev = p
    return seq, rawpos


def dump_raw(path, center, before, after, label):
    with open(path, "r") as f:
        lines = [l.strip() for l in f]
    lo = max(0, center - before)
    hi = min(len(lines), center + after)
    print(f"--- {label}: raw cycles [{lo}..{hi})  (中心 = 分叉拍 {center}) ---")
    for i in range(lo, hi):
        mark = ">>" if i == center else "  "
        print(f"{mark} cyc {i:>8}  pc={lines[i]}")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a, ap = collapse_with_map(sys.argv[1])
    b, bp = collapse_with_map(sys.argv[2])
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    print(f"collapsed: A={len(a)} 指令 / B={len(b)} 指令")
    if i >= n:
        print("长度范围内完全一致（B 是 A 的前缀）—— 没有可分叉的点")
        return 0
    print(f"first divergence at 指令 #{i}: A({sys.argv[1]}) pc={a[i]}  B({sys.argv[2]}) pc={b[i]}")
    print()
    print("折叠序列上下文（lane A only，会跳号，正常）：")
    for j in range(max(0, i - 6), min(n, i + 8)):
        mark = ">>" if j == i else "  "
        print(f"{mark} #{j:<7} A={a[j]}   B={b[j]}")
    print()
    dump_raw(sys.argv[1], ap[i], 24, 12, "A " + sys.argv[1])
    print()
    dump_raw(sys.argv[2], bp[i], 24, 12, "B " + sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
