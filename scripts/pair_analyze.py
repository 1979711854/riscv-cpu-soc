#!/usr/bin/env python3
"""
双发射可行性探针（Stage 0）：动态配对率分析器

读 tb_coremark.v 的 +PAIRTRACE 输出（计时区间内逐条 retired {pc,instr}），
复放【保守配对规则】，估算动态配对率 p 与预测得分。纯离线，不碰 RTL。

[!] **必须在【单发射】配置下跑**（`run_coremark.ps1 -Iter 1 -Single` +
    `vvp tb_coremark_single.vvp ... +PAIRTRACE`）。原因：+PAIRTRACE 的影子和
    `v_wb` 都是**单沿**的，**双发射下它看不见 lane B** —— 数出来的 n 是
    【写回周期数】而不是指令数，配对率会被算歪。
    **判据**：输入文件行数必须是 **288,056**（= 每迭代指令数）。对不上就是口径错了。
    2026-10-10 实踩：双发射下 n = 228,183（= region commit），是错的。

**规则来源**：`rtl/core/core.v` 的 `pair_now`（实现）与本文件的 `PURE_ALU` / `BREAK`
（模型）是同一套规则的两种写法。**改 RTL 的配对规则时，这里要跟着改。**

[!] **2026-10-15（P2）口径对齐 —— `p_f7_b` 排除在 RTL 里是【双档】的，本模型按 1 档算**：
    * `LANEB_MEM=0`（P2 默认）：RTL 保持无条件 `p_f7_b != 0000001` —— 连
      `imm[11:5]==1` 的 OPIMM 也一并排除（保守但逐位保持旧基线）。
    * `LANEB_MEM=1`（P3 翻开关）：RTL 收窄成"只对 OP_REG 生效"
      `!((op==OP) && f7==1)`，lane B 额外允许 LOAD、并加"每对最多一条访存"。
    本文件的 `is_simple_b` 从 2026-10-15（36cb43b）起就按**收窄后（=1 档）**的规则写，
    所以它描述的是 **P3 的目标形态**，不是 P2 默认档的逐字复刻。
    pairtrace 实测：无条件收窄会多配 ~927 对 OPIMM ⇒ 这就是 P2 必须把收窄门控在
    `LANEB_MEM` 上、否则 CoreMark 基线（229,597 拍）会变的原因。
    改 `pair_now` 时记得回来同步这里（双向）：RTL 改规则 → 模型跟着改；
    模型口径变化 → 在 P2/P3 报告里记清哪一档对应哪个 `LANEB_MEM`。

[!] **2026-10-15 更正：本模型比实现【保守】，不要再把"③"当待做项。**
    本文件的 `BREAK` 把 lane A 是 branch/jal/jalr/system/fence 一律判成"本组 1 宽" ——
    那是 2026-10-10（双发射尚未实现）的 Stage-0 假设。而 `pair_now`（core.v:696）实际
    只门控 `!p_pred_taken` 与 mul/div/amo，**对 lane A 没有任何 opcode 限制** ——
    即"预测不跳转的分支可以配对"**早已实现**。
    实测交叉验证：288,056 条指令 / `region commit` 214,703 拍 ⇒ 双提交 **73,353** 对，
    与本文件「保守 + 分支配对」档的 **72,256** 只差 1.5%。
    ⇒ **打印出的「③ 放宽上界」不是上界，就是现状**；照它算会得出"+4.18% 可挖"的错误结论。
    详见 `doc/reports/2026-10-15_pair_rate_analysis.md`。

保守配对规则（slot A = 老，任意指令；slot B = 新，全满足时才与 A 同拍发射）：

    - B 是纯 ALU：opcode ∈ {OP, OP-IMM, LUI, AUIPC}
    - B 不是 M 扩展（OP 且 funct7==0b0000001 排除）
    - B 写非 x0 寄存器（rd_b != 0）
    - B 不依赖 A：A 的 rd_a（非 x0）不在 B 读的源寄存器里
    - 同对不写同一寄存器：rd_a != rd_b

  另外，A 是"打断"类指令时该组只能是 1 宽（A 单独发射），因为机器必然重定向/停顿：
    branch / jal / jalr / mul / div

  说明：本模型**保守**——把每条分支都当作打断（不利用"预测为不跳转的分支"与
  后继配对的可能），因此算出的 p 是下界。

[!] **这个模型回答的是"值不值得做双发射"，不是"当前双发射实现跑多快"。**
    `pred_region = g + STALL_CYCLES` 是从**单发射基线 363,515** 出发的外推，
    它不含当前实现在**取指级**的约束（两条必须同在 A1/A2 那一对里、`p_pred_taken`
    门控等）。**要评当前实现，用实测的 `region cycles`，别用这里的预测值。**
    2026-10-10 交叉验证：模型给 k=63,042 对，实测反推 59,873 对 —— **模型偏乐观 5%**，
    量级可信，绝对值别当真。
"""

import sys
import re

# ---- RISC-V 指令字段 ----
OP     = 0x33   # 0110011  reg-reg ALU
OPIMM  = 0x13   # 0010011  reg-imm ALU
LUI    = 0x37   # 0110111
AUIPC  = 0x17   # 0010111
LOAD   = 0x03
STORE  = 0x23
BRANCH = 0x63
JAL    = 0x6f
JALR   = 0x67
SYSTEM = 0x73
FENCE  = 0x0f

PURE_ALU = {OP, OPIMM, LUI, AUIPC}
# 打断类：A 是这些则本组 1 宽（不尝试配对）
BREAK = {BRANCH, JAL, JALR, SYSTEM, FENCE}

# 当前基线（用于算预测改进）
BASE_REGION_CYCLES = 363515
BASE_SCORE         = 233.85
CLOCK_MHZ          = 85.0051
STALL_CYCLES       = 20720 + 9396 + 45343   # load-use + mul + 分支，合计 75459（双发射不消除这些）


def fields(instr):
    op   = instr & 0x7f
    rd   = (instr >> 7) & 0x1f
    f3   = (instr >> 12) & 0x7
    rs1  = (instr >> 15) & 0x1f
    rs2  = (instr >> 20) & 0x1f
    f7   = (instr >> 25) & 0x7f
    return op, rd, f3, rs1, rs2, f7


def reads(instr):
    """B 实际读的源寄存器集合（LUI/AUIPC 不读 reg）。"""
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op == OP:
        return {rs1, rs2}
    if op == OPIMM:
        return {rs1}
    if op == LOAD:                 # [lane B 放 load] 基址寄存器
        return {rs1}
    return set()   # LUI / AUIPC


def is_simple_alu_b(instr):
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op not in PURE_ALU:
        return False
    if op == OP and f7 == 0x01:      # M 扩展排除
        return False
    if rd == 0:                       # 不写寄存器则配对无意义
        return False
    return True


def is_simple_b(instr, allow_load=False):
    """lane B 能否放这条。allow_load（[任务] lane B 放访存）时额外允许 LOAD。

    [!] **load 不能用 `f7` 判** —— 它的 `instr[31:25]` 是【立即数高位】，不是 funct7。
        实现里 `p_f7_b != 1` 那条排除必须【收窄成只对 OP_REG】`(op==OP && f7==1)`，
        否则 `imm[11:5]==1` 的合法 load 会被误排 —— 表现为"少配一对"，不报错、
        CRC 也不变（任务书 §7 R3）。
    [!] 不放 store：本轮明确不做（任务书 §8.2，风险 R-main：ex_flush 那拍 lane B
        若为 store 会静默写坏内存）。A' 档（load+store）只作上界参考。
    """
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op in PURE_ALU:
        if op == OP and f7 == 0x01:   # M 扩展排除（只对 OP_REG 有意义）
            return False
        return rd != 0                # 不写寄存器则配对无意义
    if allow_load and op == LOAD:
        return rd != 0
    return False


def is_break_a(instr):
    op, rd, f3, rs1, rs2, f7 = fields(instr)
    if op in BREAK:
        return True
    if op == OP and f7 == 0x01:       # mul/div：多拍共享单元，需独占发射
        return True
    return False


def is_pure_alu_a(a):
    """A 是纯 ALU（结果在 EX 同拍组合可得）——A→B 旁路的前提（load 不行）。"""
    op, rd, f3, rs1, rs2, f7 = fields(a)
    if op in PURE_ALU:
        return not (op == OP and f7 == 0x01)
    return False


def _pair_reason(a, b, allow_bypass, skip_break=False, allow_load_b=False):
    """返回 'ok' 或失败原因。allow_bypass 时允许 B 依赖纯 ALU 的 A。
    skip_break=True 时不把 A 的打断性算作失败（用于"预测不跳转的分支"放宽）。
    allow_load_b=True 时 lane B 可放 load，但【每对最多一条访存】（见下）。"""
    op_a, rd_a, _, _, _, _ = fields(a)
    if not skip_break and is_break_a(a):
        return 'break_a'
    if not is_simple_b(b, allow_load_b):
        return 'b_not_alu'
    op_b, rd_b, _, _, _, _ = fields(b)
    # [任务书 §2/§3] **每对最多一条访存** —— 规则的前提，时序上就不冲突：
    #   lane A / lane B 是【同对、同拍锁存】（ex_mem/ex_mem_b 同沿更新）⇒ 任一拍
    #   MEM 级里躺着的就是这一对的两条 ⇒ 访存口只需一次 2 路 mux，不用仲裁器。
    #   实现里对应新增的 `&& !(p_mem_a && p_ld_b)`（任务书 §4B）。
    if allow_load_b and op_a in (LOAD, STORE) and op_b == LOAD:
        return 'mem_both'
    if rd_a != 0 and rd_a == rd_b:       # 同对 WAW
        return 'waw'
    if rd_a != 0 and rd_a in reads(b):   # B 依赖 A
        if allow_bypass and is_pure_alu_a(a):
            return 'ok'
        return 'b_dep_a'
    return 'ok'


def pairable(a, b, allow_bypass=False):
    return _pair_reason(a, b, allow_bypass) == 'ok'


def analyze(path):
    insts = []   # (pc, instr)
    with open(path) as f:
        for line in f:
            m = re.match(r'^([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})', line)
            if m:
                insts.append((int(m.group(1), 16), int(m.group(2), 16)))
    n = len(insts)

    def taken_branch_at(i):
        """i 处是条件分支且实际跳转 = 下一条 retired 的 PC != pc+4。"""
        pc, ins = insts[i]
        op = ins & 0x7f
        if op != BRANCH:
            return False
        nxt = insts[i + 1][0] if i + 1 < n else (pc + 4)
        return nxt != (pc + 4) & 0xffffffff

    def reason(a, b, mode):
        # mode: 0=保守; 1=+A→B旁路; 2=+分支配对(预测不跳转的分支可与后继配对)
        #       3 = 2 + lane B 可放 load（每对最多一条访存）—— 本任务的目标档
        allow_load_b = (mode == 3)
        r = _pair_reason(a[1], b[1], mode in (1, 2, 3), allow_load_b=allow_load_b)
        if r != 'break_a':
            return r
        # break_a：看是否能靠"分支配对"救
        if mode in (2, 3):
            op_a = a[1] & 0x7f
            if op_a == BRANCH and not taken_branch_at_by_pc(a, b):
                return _pair_reason(a[1], b[1], False, skip_break=True,
                                    allow_load_b=allow_load_b)
        return 'break_a'

    def taken_branch_at_by_pc(a, b):
        pc, ins = a
        return b[0] != ((pc + 4) & 0xffffffff)

    def run(mode):
        k = 0
        i = 0
        reasons = {}
        while i < n:
            if i + 1 < n:
                r = reason(insts[i], insts[i + 1], mode)
            else:
                r = 'end'
            if r == 'ok':
                k += 1
                i += 2
            else:
                reasons[r] = reasons.get(r, 0) + 1
                i += 1
        g = n - k
        p = k / g if g else 0.0
        pred_region = g + STALL_CYCLES
        pred_cmhz = 1e6 / pred_region
        return k, g, p, pred_region, pred_cmhz, reasons

    def report(tag, mode):
        k, g, p, pred_region, pred_cmhz, reasons = run(mode)
        score85 = pred_cmhz * CLOCK_MHZ
        be = BASE_SCORE / pred_cmhz
        print("=" * 62)
        print(f"[{tag}]")
        print(f"  指令数 n          : {n:,}")
        print(f"  2 宽组合 k        : {k:,}   配对率 p = {p:.4f}")
        print(f"  组合总数 g=n-k    : {g:,}")
        for r in ('break_a', 'b_not_alu', 'b_dep_a', 'waw', 'mem_both', 'end'):
            if reasons.get(r):
                print(f"    单独发射-{r:<10}: {reasons[r]:>8,}  ({reasons[r]/g*100:4.1f}% of g)")
        print(f"  预测区间周期数    : {pred_region:,.0f}   (基线 {BASE_REGION_CYCLES:,})")
        print(f"  预测 CoreMark/MHz : {pred_cmhz:.3f}   (基线 2.751，单发射天花板 3.472)")
        print(f"  预测得分 @85.0051 : {score85:.1f}   (基线 {BASE_SCORE})")
        print(f"  break-even 时钟    : {be:.1f} MHz")
        return p, score85, be

    p0, s0, be0 = report("① 保守配对（Stage C 目标）", mode=0)
    print()
    p1, s1, be1 = report("② ① + A→B 旁路（Stage D，实测只值 +1 分）", mode=1)
    print()
    p2, s2, be2 = report("③ ① + 允许预测不跳转的分支配对（放宽，上界）", mode=2)
    print()
    p3, s3, be3 = report("④ ③ + lane B 可放 load（每对最多一条访存）—— 本任务目标档", mode=3)
    print("=" * 62)
    print()
    # ---- P1 判据（任务书 §6）----
    # ③ 是【当前实现】的近似（实现只门控 !p_pred_taken + mul/div/amo，对 lane A 无
    #    opcode 限制）—— 不是"上界"。②③④ 三档的相对差才是本次要看的量。
    # p = k/g 且 g = n-k  ⇒  k = p*n/(1+p)
    def k_of(p):
        return round(p * n / (1.0 + p))
    k2, k3 = k_of(p2), k_of(p3)
    print("P1 判据（相对【当前实现近似】= (3) 档）：")
    print(f"  (3) 现状近似        k = {k2:,}")
    print(f"  (4) +lane B load    k = {k3:,}   delta = {k3 - k2:+,}  ({(k3 - k2) / max(k2, 1) * 100:+.2f}%)")
    print(f"  ->  预测拍数        229,597 -> {229597 - (k3 - k2):,}"
          f"  ({-(k3 - k2) / 229597 * 100:+.2f}%)")
    print(f"  ->  预测 Score      {1e6 / 229597:.4f} -> {1e6 / (229597 - (k3 - k2)):.4f} CoreMark/MHz")
    print("=" * 62)
    print()
    print("门限判定（以 ① 为准）：")
    if p0 < 0.15:
        print(f"  p={p0:.3f} < 0.15  -> 放弃，保留 85MHz 版")
    elif p0 < 0.35:
        print(f"  0.15 <= p={p0:.3f} < 0.35  -> 可做但收益有限：需 Fmax 保住 ~{be0:.0f}MHz")
    else:
        print(f"  p={p0:.3f} >= 0.35  -> 达标，值得进 Stage A/B/C")
    print(f"  Stage D 旁路      : 得分 {s0:.0f} -> {s1:.0f}（+{s1-s0:.0f}）")
    print(f"  放宽分支配对(上界): 得分 {s0:.0f} -> {s2:.0f}（+{s2-s0:.0f}）")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "programs/pairtrace.txt"
    analyze(path)
