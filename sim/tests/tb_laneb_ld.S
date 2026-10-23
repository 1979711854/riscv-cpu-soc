/* ============================================================================
 * tb_laneb_ld.S —— lane B load 定向测试（P3 / 任务书 §7 的 R1、R2、R5）
 * ----------------------------------------------------------------------------
 * 为什么必须在翻 LANEB_MEM=1 之前写好并通过（任务书 §6 P3 第 1 条）：
 *   R1/R2 都是"静默错值"类缺陷 —— 错了不抛异常、CRC 之外什么都看不出来，
 *   基线测试（CoreMark / riscv-tests）恰好没有这些指令组合 ⇒ 必须定向构造。
 *
 * 用例与风险的对应关系：
 *   用例 1  R1  (§4F)：lane B load 紧跟一条依赖它的指令（消费者在下一条的
 *           lane A）。验 (E) 的 lane B load-use 停顿子句 + (I) 的 wb_data_b
 *           前递解包。(F) 的四个 fwd_*_exb 门控是同拍 WAR 的防护，本用例顺带
 *           覆盖其端到端行为。
 *   用例 2  R1  (§4E 的 if_id_pair 分支)：消费者在【下一条的 lane B】
 *           （rs1_b 子句）。漏了 if_id_pair 门控或 rs1_b 比较就会拿陈旧值。
 *   用例 3~6  R1 + (I)：lane B 的 lb / lbu / lh / lhu —— 验 wb_data_b 的
 *           符号/零扩展解包（2026-10-11 实踩过：只前递原始字时 lb/lh 全 FAIL）。
 *   用例 7  R2  (§4G)：指针追逐 —— lane A load 的基址来自【同拍 lane B load】
 *           的结果。验 (G) 的 ld_bad_base 新项：漏了它，ld_f_exb 被 (F) 门控
 *           挡掉后会静默回落到陈旧基址，而 ld_fast 仍判"可走快通路" ⇒ 读到错
 *           地址。判据 = 拿到链式解引用的【正确】叶子值，不是错叶子值。
 *   用例 8  R5  (§4H)：lane B 的未对齐 lh —— 验 mcause=4 / mtval=出错地址 /
 *           mepc=肇事指令 PC（§3.2 修过的 trap_pc 选择逻辑）。
 *
 * [对齐纪律] 每个图案前一条 nop + X = `addi x28,x0,0`：
 *   * nop 阻断 (nop, X) 配对（lane B 候选的 rd=x0，pair_now 直接拒）；
 *   * 于是 X 必以 lane A 单独到达，下一到达拍就是 (X, L1) ⇒ L1 必为 lane B。
 *   这样无论上游指令怎么配对，图案的 A/B 落位都是确定的。X 的 rd=x28 避开
 *   L1 的 rs1(x6)/imm[4:0](0..2)/rd(x5) 三项配对约束。
 *
 * [运行口径] 必须带 -EarlyLd（与板上级配置一致）：R2 的 (G) 洞只在
 *   EARLY_LD=1 时可达（ld_fast 是快通路判据）。LANEB_MEM=0 时本文件所有用例
 *   都应 PASS（lane B 放不了 load，图案退化成顺序执行，行为不变）—— 这是
 *   "先写用例再翻开关"的基线判据。
 *
 * 判分用 riscv-tests 的 tohost 机制（sim/tb_riscv.v 已支持）。
 * 汇编方式见 scripts/run_own_tests.ps1（-LanebMem 传 -DLANEBMEM 开开关）
 * ==========================================================================*/
#include "encoding.h"
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_CODE_BEGIN

    /* ---------- 公共 setup（INIT_XREG 已把全部寄存器清零，这里显式给值） ---------- */
    li    x10, 0x00000100        /* a0：用例 2 的加数（可识别值） */
    la    x6,  d_word1           /* t1：用例 1/2/3~6 的 load 基址 */

    /* ============================================================
     * 用例 1（R1，字 load）：lane B load 紧跟 lane A 消费者
     * ============================================================ */
    li    TESTNUM, 1
    nop                           /* 对齐保险 */
    addi  x28, x0, 0              /* X：lane A */
    lw    x5, 0(x6)               /* L1：lane B load，x5 ← mem[d_word1] */
    addi  x7, x5, 1               /* L2：消费者（rs1=x5）*/
    li    x8, 0x12345679          /* 期望 = d_word1 + 1 */
    bne   x7, x8, fail

    /* ============================================================
     * 用例 2（R1，消费者落在下一条的 lane B）：rs1_b 停顿子句
     *   (X,L1) 配对发射后，下一到达拍天然是 (L2a,L2b) ⇒ L2b 与 L1 相隔一对，
     *   其 rs1=x5 必须由 (E) 的 if_id_pair && rs1_b 子句停住，数据走
     *   MEM/WB 的 fwd_ba_wbb（wb_data_b）。
     * ============================================================ */
    li    TESTNUM, 2
    nop                           /* 对齐保险（阻断上一指令与 X 配对） */
    addi  x28, x0, 0              /* X：lane A */
    lw    x5, 0(x6)               /* L1：lane B load，x5 ← 0x12345678 */
    addi  x9, x0, 0               /* L2a：lane A，独立（rd=x9）*/
    add   x7, x5, x10             /* L2b：lane B，rs1=x5（依赖 L1）、rs2=x10 */
    li    x8, 0x12345778          /* 期望 = 0x12345678 + 0x100 */
    bne   x7, x8, fail

    /* ============================================================
     * 用例 3~6（R1 + (I) 解包）：lane B 的 lb / lbu / lh / lhu
     *   d_bytes = 0x89ABCDEF（小端：字节序 EF CD AB 89）
     *   每次都是 nop + X + L1(load) + L2(消费者)，检查符号/零扩展。
     * ============================================================ */
    li    TESTNUM, 3
    la    x6,  d_bytes           /* 字节/半字靶子（用例 1/2 用的是 d_word1）*/
    nop
    addi  x28, x0, 0              /* X：lane A */
    lb    x5, 0(x6)               /* L1：lane B lb  → x5 = 0xFFFFFFEF（sext EF）*/
    addi  x7, x5, 1               /* L2：消费者 */
    li    x8, 0xFFFFFFF0
    bne   x7, x8, fail

    li    TESTNUM, 4
    nop
    addi  x28, x0, 0              /* X：lane A */
    lbu   x5, 1(x6)               /* L1：lane B lbu → x5 = 0x000000CD（zext CD）*/
    addi  x7, x5, 1               /* L2：消费者 */
    li    x8, 0x000000CE
    bne   x7, x8, fail

    li    TESTNUM, 5
    nop
    addi  x28, x0, 0              /* X：lane A */
    lh    x5, 2(x6)               /* L1：lane B lh  → x5 = 0xFFFF89AB（sext 89AB，小端）*/
    addi  x7, x5, 1               /* L2：消费者 */
    li    x8, 0xFFFF89AC
    bne   x7, x8, fail

    li    TESTNUM, 6
    nop
    addi  x28, x0, 0              /* X：lane A */
    lhu   x5, 0(x6)               /* L1：lane B lhu → x5 = 0x0000CDEF（zext CDEF）*/
    addi  x7, x5, 1               /* L2：消费者 */
    li    x8, 0x0000CDF0
    bne   x7, x8, fail

    /* ============================================================
     * 用例 7（R2，指针追逐）：lane A load 的基址来自同拍 lane B load
     *   x5 先填【陈旧】指针（指向错叶子）；L1 把 x5 覆写为正确指针；
     *   L2 以 x5 为基址取数 —— 必须拿到【正确】叶子的值。
     *   漏 (G) 时的失败形态：L2 的 ID 级 AGU 拿到陈旧 x5 ⇒ ld_fast 仍为 1
     *   ⇒ 快通路读到错叶子 ⇒ x7 = 0x0BADBAD0（静默错值）。
     * ============================================================ */
    li    TESTNUM, 7
    la    x6,  d_right_ptr        /* L1 基址 = 正确指针字的地址 */
    la    x5,  d_wrong_leaf       /* x5 的陈旧值 = 错叶子地址 */
    nop                           /* 对齐保险 */
    addi  x28, x0, 0              /* X：lane A */
    lw    x5, 0(x6)               /* L1：lane B load，x5 ← mem[d_right_ptr] = &d_right_leaf */
    lw    x7, 0(x5)               /* L2：lane A load，基址 = x5（刚被 L1 写）*/
    li    x8, 0x600DF00D          /* 期望 = 正确叶子的值（不是 0x0BADBAD0）*/
    bne   x7, x8, fail

    /* ============================================================
     * 用例 8（R5 / §4H）：lane B 的未对齐 lh → trap 语义
     *   装自己的 handler（其余用例的意外陷阱仍走 env 的 trap_vector，
     *   会以 1337 响亮失败，不会被本 handler 掩盖）。mepc 必须指向
     *   lh 自己（§3.2 修过的 trap_pc：lane B 是唯一肇事者时取 B 的 PC）。
     * ============================================================ */
    li    TESTNUM, 8
    la    x8,  lb_handler
    csrw  mtvec, x8
    la    x9,  lh_site            /* 期望 mepc */
    la    x10, d_victim
    addi  x10, x10, 1             /* 期望 mtval = d_victim+1 */
    la    x6,  d_victim
    addi  x6, x6, 1               /* 奇地址 ⇒ lh 未对齐 */
    nop                           /* 对齐保险 */
    addi  x28, x0, 0              /* X：lane A（幂等，重放安全） */
lh_site:
    lh    x5, 0(x6)               /* L1：lane B load，奇地址 → mcause=4 */
    nop                           /* 断开与后继指令的配对（否则 LANEB_MEM=0 时
                                     后继 li 会被 trap 冲掉，见头部说明） */
    li    x8, 4
    bne   x18, x8, fail           /* mcause = 4（Load misaligned）*/
    bne   x19, x10, fail          /* mtval  = 出错地址 */
    bne   x20, x9, fail           /* mepc   = lh 自己的 PC */

    /* ---------- 全部通过 ---------- */
    RVTEST_PASS

fail:
    RVTEST_FAIL

/* ----------------------------------------------------------------------------
 * 未对齐异常 handler：记录 mcause/mtval/mepc，mepc += 4 跳过肇事指令。
 * 只用 s2/s3/s4 与 t4，不碰主体别的寄存器（与 exceptions.S 同款）。
 * --------------------------------------------------------------------------*/
        .align 2
lb_handler:
        csrr  x18, mcause
        csrr  x19, mtval
        csrr  x20, mepc
        addi  x29, x20, 4
        csrw  mepc, x29
        mret

RVTEST_CODE_END

RVTEST_DATA_BEGIN
        .align 4
d_word1:      .word 0x12345678        /* 用例 1/2 的 load 目标值 */
d_bytes:      .word 0x89ABCDEF        /* 用例 3~6 的字节/半字靶子 */
                                     /* 用例 7 的指针追逐数据：
                                        L1 把 x5 写成 &d_right_leaf；x5 的陈旧值是
                                        &d_wrong_leaf。两个叶子的值差异极大，
                                        错通路一定被抓到。*/
d_right_ptr:  .word d_right_leaf      /* L1 的 load 结果（正确指针）*/
d_right_leaf: .word 0x600DF00D        /* 正确叶子的值 */
d_wrong_leaf: .word 0x0BADBAD0        /* 错叶子的值（漏 (G) 时会读到它）*/
d_victim:     .word 0x11223344        /* 用例 8 的未对齐靶子（奇地址访问）*/
RVTEST_DATA_END
