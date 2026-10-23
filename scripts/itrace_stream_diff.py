#!/usr/bin/env python3
"""itrace_stream_diff.py —— 用 IF/ID trace 对拍【实际执行的指令流】（配对感知）。

用法：
    python scripts/itrace_stream_diff.py sim/itrace_nocache.txt sim/itrace_icache.txt

为什么不用 pctrace 直接 diff（2026-10-14 实踩）：
    `pc` 口给的是 pc_r（顺序取指指针，配对成功时 +8），所以"跳号"既可能是
    配对、也可能是真丢了指令 —— 两种运行只要配对情况不同，pc 流就会假分叉。
    本脚本改成从 IF/ID 的内容变化提取【执行流】：
      * 连续重复的 IF/ID 内容 = 同一拍的冻结重复 ⇒ 折叠；
      * 内容变化 ⇒ lane A 执行了一次；`pair=1` 时 lane B 也执行了一次。
    这样"配对与否"不再影响序列，序列的分叉才是真正的指令级差异。

itrace 列（-DITRACE 的输出）：
    pcA instA pcB pair pr ex fetch_addr mem_ready | id_ex_pc ex_mem_pc mem_wb_pc
    | weA rdA wb_data | weB rdB wb_data_b
"""
import sys


def extract(path):
    """抽出执行流：[(slot, pc, inst), ...]，slot ∈ {A,B}。"""
    stream = []
    prev = None
    with open(path, "r") as f:
        for line in f:
            t = line.replace("|", " ").split()
            if len(t) < 4:
                continue
            pcA, instA, pcB, pair = t[0], t[1], t[2], t[3]
            key = (pcA, instA, pcB, pair)
            if key == prev:
                continue          # 冻结/停顿的重复，不是新执行
            prev = key
            if pcA != "00000000":
                stream.append(("A", pcA, instA))
            if pair == "1" and pcB != "00000000":
                stream.append(("B", pcB, ""))
    return stream


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a = extract(sys.argv[1])
    b = extract(sys.argv[2])
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i][1] == b[i][1]:
        i += 1
    print(f"executed: A={len(a)} 条 / B={len(b)} 条")
    if i >= n:
        print("长度范围内执行流完全一致（B 是 A 的前缀）")
        return 0
    print(f"first divergence at 指令 #{i}")
    for j in range(max(0, i - 10), min(n, i + 12)):
        mark = ">>" if j == i else "  "
        print(f"{mark} #{j:<7} A: {a[j][0]} {a[j][1]} {a[j][2]}    B: {b[j][0]} {b[j][1]} {b[j][2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
