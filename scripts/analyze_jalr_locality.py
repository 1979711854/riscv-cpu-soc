# -*- coding: utf-8 -*-
"""analyze_jalr_locality.py —— 分析 +JALRTRACE 的输出，回答"BTB/RAS 该做多大"。

配套：sim/tb_coremark.v 的 +JALRTRACE 探针（默认关、纯被动、不改周期数）。
生成数据：
    cd sim
    vvp tb_coremark_dual_earlyld.vvp "+ITER=1" "+IMEM=programs/imem.hex" \\
        "+DMEM=programs/dmem.hex" "+MEMWAIT=0" "+JALRTRACE"
    # 产出 sim/programs/jalrtrace.txt，每行 "J|R <pc> <target> <rd> <rs1>"（十六进制）

用法：
    python analyze_jalr_locality.py <jalrtrace.txt>

[!] 跑之前先确认 sim/programs/ 里是 CoreMark 的镜像 —— run_riscv_tests.ps1 /
    run_own_tests.ps1 会把 programs/ 覆盖成 riscv-test / 自写测试的镜像，
    那样仿真会 TIMEOUT（本脚本读到的就是空文件）。先跑一次
    `run_coremark.ps1 -Iter 1 -EarlyLd -SkipSim` 重新生成固件。
"""
import sys
import io
from collections import defaultdict

RA1, RA5 = 1, 5   # x1=ra, x5=t0 —— RISC-V ABI 里两个"返回地址"寄存器


def load(path):
    ev = []
    with io.open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 5:
                ev.append((p[0], int(p[1], 16), int(p[2], 16), int(p[3]), int(p[4])))
    return ev


def pct(h, n):
    return "%6.2f%%" % (100.0 * h / n) if n else "  n/a  "


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    ev = load(sys.argv[1])
    jals = [e for e in ev if e[0] == 'J']
    jalrs = [e for e in ev if e[0] == 'R']
    n = len(jalrs)
    if n == 0:
        print("jalr 条数为 0 —— 检查 sim/programs/ 里是不是 CoreMark 的镜像（见文件头 [!]）")
        return 1

    print("jal %d 条 / jalr %d 条" % (len(jals), n))
    rets = [e for e in jalrs if e[3] == 0 and e[4] in (RA1, RA5)]
    print("jalr 中 ret 形态（rd=x0 & rs1=ra）: %d 条（%.1f%%）\n"
          % (len(rets), 100.0 * len(rets) / n))

    # ---- 每点位"上次目标"（全相联、无冲突；即"完美 tag 的 1 项表"）----
    last, h = {}, 0
    for pc, tg in [(e[1], e[2]) for e in jalrs]:
        if last.get(pc) == tg:
            h += 1
        last[pc] = tg
    print("[基线] 每点位记上次目标            : %5d  %s" % (h, pct(h, n)))

    # ---- 每点位最近 K 个目标（全相联 LRU）----
    for K in (2, 4, 8):
        hist, h = defaultdict(list), 0
        for e in jalrs:
            L = hist[e[1]]
            if e[2] in L:
                h += 1
                L.remove(e[2])
            L.append(e[2])
            if len(L) > K:
                L.pop(0)
        print("[基线] 每点位最近 %d 个目标          : %5d  %s" % (K, h, pct(h, n)))

    # ---- 组相联 BTB（PC 索引）----
    def btba(entries, ways):
        sets = entries // ways
        k = max(1, sets.bit_length() - 1)
        idx_mask = sets - 1
        tbl = [[None] * ways for _ in range(sets)]
        lru = [[0] * ways for _ in range(sets)]
        h, tick = 0, 0
        for pc, tg in [(e[1], e[2]) for e in jalrs]:
            tick += 1
            i = (pc >> 2) & idx_mask
            tag = (pc >> 2) >> k
            w, victim, vlru = tbl[i], 0, None
            for j in range(ways):
                if w[j] is not None and w[j][0] == tag:
                    if w[j][1] == tg:
                        h += 1
                    victim = j
                    break
                if vlru is None or lru[i][j] < vlru:
                    vlru, victim = lru[i][j], j
            w[victim] = (tag, tg)
            lru[i][victim] = tick
        return h

    print()
    for entries in (256, 1024):
        for ways in (1, 2, 4):
            h = btba(entries, ways)
            print("[BTB]  %4d 项 / %d 路 组相联        : %5d  %s" % (entries, ways, h, pct(h, n)))

    # ---- RAS ----
    print()
    for depth in (4, 8, 16, 32):
        st, h, pop = [], 0, 0
        for typ, pc, tg, rd, rs1 in ev:
            if typ == 'J':
                if rd in (RA1, RA5):
                    st.append(pc + 4)
                    if len(st) > depth:
                        st.pop(0)
            else:
                if rd == 0 and rs1 in (RA1, RA5):
                    pop += 1
                    pred = st.pop() if st else None
                    if pred == tg:
                        h += 1
                elif rd in (RA1, RA5):
                    st.append(pc + 4)
                    if len(st) > depth:
                        st.pop(0)
        print("[RAS]  %2d 项（预测 ret %d 条）      : %5d  %s" % (depth, pop, h, pct(h, n)))

    # ---- RAS + 非 ret 走"每点位最近 4 个目标" ----
    print()
    for depth in (8, 16):
        st, h, hist = [], 0, defaultdict(list)
        for typ, pc, tg, rd, rs1 in ev:
            if typ == 'J':
                if rd in (RA1, RA5):
                    st.append(pc + 4)
                    if len(st) > depth:
                        st.pop(0)
            else:
                if rd == 0 and rs1 in (RA1, RA5):
                    pred = st.pop() if st else None
                    if pred == tg:
                        h += 1
                else:
                    if rd in (RA1, RA5):
                        st.append(pc + 4)
                        if len(st) > depth:
                            st.pop(0)
                    L = hist[pc]
                    if tg in L:
                        h += 1
                        L.remove(tg)
                    L.append(tg)
                    if len(L) > 4:
                        L.pop(0)
        print("[RAS %2d + 非ret 每点位4目标] 总命中 : %5d  %s" % (depth, h, pct(h, n)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
