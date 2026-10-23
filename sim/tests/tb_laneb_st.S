/* ============================================================================
 * tb_laneb_st.S —— lane B store 定向测试（A1：把"lane B 放 load"对称到 store）
 * ----------------------------------------------------------------------------
 * 为什么必须写：lane B 放 store 的全部风险都是【静默错值】——
 *   写口三条腿（mem_we / mem_addr / mem_wdata+mem_byte_en）挂错 lane、
 *   存数据误用 lane A 的 rs2（ex_mem_wdata）、字节使能用 lane A 的 funct3/地址、
 *   store→load 快通路判据（ld_bad_st）漏掉 lane B 那一支、未对齐异常漏判……
 *   任何一条错了都不抛异常、riscv-tests 也可能全 PASS，只有本文件与 CoreMark 四 CRC
 *   才抓得到。**先写用例再翻 LANEB_ST=1**（与 tb_laneb_ld.S 的纪律相同）。
 *
 * 用例与风险对应（core.v 的落点）：
 *   用例 1  写口三条腿 + ld_bad_st 的 lane B 项（判据③）：
 *           lane B store 紧跟 lane A 的【同址】load —— 漏了判据③ 那支，早读口
 *           与 store 写入是【同一沿】，load 读到旧值（静默错值）。
 *   用例 2  mem_byte_en / mem_wdata 的 SB 分支（字节使能取 lane B 的地址低两位）；
 *   用例 3  同上，SH 分支；
 *   用例 4  两条相邻 store 必须【不配对】（每对至多一条访存）+ 两次写都真正落盘；
 *   用例 5  lane A load + lane B store（同对两条访存）必须【不配对】——
 *           配对则访存口地址 mux 会把 lane A 的读引到 lane B 的地址上；
 *   用例 6  lane B store 在【被冲刷】的对里绝不能写（b_st_sel 看 ex_mem_b_valid，
 *           而它含 !ex_flush）：lane A 是"实际跳转、预测不跳"的前向分支。
 *           （真实覆盖来自 CoreMark——它的前向 taken 分支后面常有 store；
 *            本用例是尽力而为的定向版，见下面的说明）
 *   用例 7  未对齐 lane B store → mcause=6 / mtval=出错地址 / mepc=store 自己的 PC
 *           （与 tb_laneb_ld.S 用例 8 的 load 版对称）；
 *   用例 8  写口不留残留：lane A 的写回（rd）与 lane B 的 store 同对，rd 必须拿到
 *           自己的值，且 store 不得顺手写寄存器（reg_write_b 恒 0）。
 *
 * [对齐纪律] 每个图案前一条 nop + X = `addi x28,x0,0`（照抄 tb_laneb_ld.S）：
 *   nop 阻断 (nop,X) 配对（X 的 rs1=x0 撞上 nop 的 rd=x0，pair_now 直接拒），
 *   于是 nop 单独到达、下一到达拍就是 (X, S) ⇒ S 必为 lane B。
 *   X 的 rd=x28 避开 S 的 rs1/rs2/imm 三项配对约束。
 *
 * [运行口径]
 *   * 本文件在 LANEB_ST=0 与 =1 下【都必须 PASS】—— 0 档时 store 退化成
 *     顺序执行（lane A 单独发），语义不变，这正是"先写用例再翻开关"的基线判据；
 *   * 带 -EarlyLd 才能覆盖用例 1（判据③ 只在快通路下才有意义）；
 *   * 需要 -DLANEBMEM（lane B 能放 load 是 store 的前置能力）。
 *
 * 判分用 riscv-tests 的 tohost 机制（sim/tb_riscv.v 已支持）。
 * 汇编/运行：scripts\run_own_tests.ps1 -EarlyLd -LanebMem [-Name tb_laneb_st]
 * ==========================================================================*/
#include "encoding.h"
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_CODE_BEGIN

    /* ---------- 公共 setup ---------- */
    li    x7,  0x22223333        /* s2：各用例要写的值（可识别） */
    li    x10, 0x0BADF00D        /* a0：给用例 8 与"错源"对照用 */

    /* ============================================================
     * 用例 1：lane B 字 store → 紧跟 lane A 同址 load（判据③ 的 lane B 项）
     *   漏 ld_bad_st 的 lane B 支时的失败形态：load 走快通路，早读口与 store 的
     *   写是【同一沿】⇒ 读到旧值 0（靶子已清 0）⇒ x5 = 0 ≠ 0x22223333。
     * ============================================================ */
    li    TESTNUM, 1
    la    x6,  d_w1
    sw    x0,  0(x6)             /* 靶子清 0（旧值） */
    nop                          /* 对齐保险 */
    addi  x28, x0, 0             /* X：lane A */
    sw    x7,  0(x6)             /* S：lane B store（写 0x22223333） */
    lw    x5,  0(x6)             /* L：lane A load，同址 */
    li    x8,  0x22223333
    bne   x5,  x8, fail

    /* ============================================================
     * 用例 2：SB（字节使能 + 字节复制都取 lane B 那一份）
     *   d_w2 = 0x11223344 → sb 0xAB 到 +2 ⇒ 0x11AB3344。
     *   若使能错用 lane A 的地址或整字写，字面值就不是这个。
     * ============================================================ */
    li    TESTNUM, 2
    la    x6,  d_w2
    li    x7,  0x000000AB        /* 只留最低字节有效 */
    nop
    addi  x28, x0, 0             /* X：lane A */
    sb    x7,  2(x6)             /* S：lane B store，字节使能 = 4'b0100 */
    lw    x5,  0(x6)             /* 读回整字（慢通路） */
    li    x8,  0x11AB3344
    bne   x5,  x8, fail

    /* ============================================================
     * 用例 3：SH：d_w3 = 0x11223344 → sh 0xBEEF 到 +0 ⇒ 0x1122BEEF
     *   （小端：字里 +0/+1 是低半字；剩下 +2/+3 = 0x22/0x11 ⇒ 高半字仍是 0x1122）
     *   三种"挂错腿"的形态各不相同、都能被抓到：
     *     正确           = 0x1122BEEF
     *     使能错成 1100  = 0xBEEF3344
     *     整字写         = 0xBEEFBEEF
     * ============================================================ */
    li    TESTNUM, 3
    la    x6,  d_w3
    li    x7,  0x0000BEEF
    nop
    addi  x28, x0, 0             /* X：lane A */
    sh    x7,  0(x6)             /* S：lane B store，字节使能 = 4'b0011 */
    lw    x5,  0(x6)
    li    x8,  0x1122BEEF
    bne   x5,  x8, fail

    /* ============================================================
     * 用例 4：两条相邻 store（不同地址）—— 必须【不配对】（每对至多一条访存），
     *   且两次写都要真正落盘（判据 = 两个字都变成新值）。
     * ============================================================ */
    li    TESTNUM, 4
    la    x6,  d_w4
    sw    x0,  0(x6)
    sw    x0,  4(x6)
    li    x7,  0x0D15EA5E
    nop                          /* 对齐保险：让下面两条自成一对候选 */
    sw    x7,  0(x6)             /* 候选 lane A */
    sw    x7,  4(x6)             /* 候选 lane B —— 必须被"每对最多一条访存"拒掉 */
    lw    x5,  0(x6)
    lw    x9,  4(x6)
    bne   x5,  x7, fail
    bne   x9,  x7, fail

    /* ============================================================
     * 用例 5：lane A load + lane B store（同对两条访存）必须被拒
     *   若被放行，访存口地址 mux 优先级（lane B 腿在前）会把 lane A 的读
     *   引到 lane B 的地址上 ⇒ 读到另一个字。
     *   这里交错成 (X,lw) 一对、(sw,lw) 一对（后者必须拒）。
     * ============================================================ */
    li    TESTNUM, 5
    la    x6,  d_w5
    sw    x0,  0(x6)
    li    x7,  0x77770000
    sw    x7,  4(x6)             /* mem[d_w5+4] = 0x77770000 */
    li    x7,  0x00007777
    nop
    addi  x28, x0, 0             /* X：lane A */
    lw    x5,  0(x6)             /* 与 X 配对：lane B load，读 0 */
    sw    x7,  0(x6)             /* 与下一条 lw 候选配对：必须被拒（lane A 是访存） */
    lw    x9,  4(x6)             /* 读 0x77770000 */
    bne   x5,  x0, fail
    li    x8,  0x77770000
    bne   x9,  x8, fail
    lw    x10, 0(x6)             /* 刚才那条 store 真的落了盘 */
    bne   x10, x7, fail

    /* ============================================================
     * 用例 6：被冲刷的对里 lane B 的 store 绝不能写
     *   lane A = 前向 beq（实际 taken、静态预测 not-taken）⇒ 该对可配对，
     *   但 EX 级解析出 taken 会发 ex_flush ⇒ lane B 的 store 必须被压住
     *   （b_st_sel 看 ex_mem_b_valid，而 ex_mem_b_valid 含 !ex_flush）。
     *   [!] 若该 PC 恰好命中一个"预测 taken"的 BHT 项，配对会被 p_pred_taken
     *   提前拒掉 ⇒ 本用例退化成顺序执行（分支照旧跳、store 撤掉）——
     *   **仍然 PASS**，只是没覆盖到冲刷压制。真实覆盖来自 CoreMark 四 CRC
     *   （它的前向 taken 分支后面常有 store，且计时区间一字不差是硬判据）。
     * ============================================================ */
    li    TESTNUM, 6
    la    x6,  d_w6
    sw    x0,  0(x6)             /* 靶子清 0 */
    la    x9,  c6_target
    nop
    beq   x0,  x0, c6_target     /* lane A：前向、恒 taken */
    sw    x10, 0(x6)             /* lane B：若冲刷没压住，写进去的就是 0x0BADF00D */
c6_target:
    nop
    lw    x5,  0(x6)
    bne   x5,  x0, fail          /* 必须仍是 0 */

    /* ============================================================
     * 用例 7：未对齐 lane B store → mcause=6 / mtval=出错地址 / mepc=store 的 PC
     *   与 tb_laneb_ld.S 用例 8 对称（那边是 mcause=4）。
     *   [!] LANEB_ST=0 时这条 store 是 lane A，期望值完全相同（mepc 都指向它自己）
     *   ⇒ 本用例在两档下都 PASS，是"关档等价"的判据之一。
     * ============================================================ */
    li    TESTNUM, 7
    la    x8,  st_handler
    csrw  mtvec, x8
    la    x9,  sh_site           /* 期望 mepc */
    la    x11, d_victim
    addi  x11, x11, 1            /* 期望 mtval = d_victim+1 */
    la    x6,  d_victim
    addi  x6,  x6, 1             /* 奇地址 ⇒ sh 未对齐 */
    nop                          /* 对齐保险 */
    addi  x28, x0, 0             /* X：lane A（幂等，被 trap 冲掉也无害） */
sh_site:
    sh    x10, 0(x6)             /* lane B store，奇地址 → mcause=6 */
    nop                          /* 断开与后继指令的配对（照抄 tb_laneb_ld.S 的纪律） */
    li    x8,  6
    bne   x18, x8,  fail         /* mcause = 6（Store/AMO misaligned）*/
    bne   x19, x11, fail         /* mtval  = 出错地址 */
    bne   x20, x9,  fail         /* mepc   = sh 自己的 PC */

    /* ============================================================
     * 用例 8：lane A 的写回不被 lane B 的 store 污染
     *   (X, S) 一对里 X（lane A）写 x5；S（lane B，store）不写任何寄存器。
     *   判据：x5 拿到自己的值，且靶子字也变成 store 的值（两条腿互不干扰）。
     * ============================================================ */
    li    TESTNUM, 8
    la    x6,  d_w8
    sw    x0,  0(x6)
    li    x7,  0x5A5A5A5A
    nop
    addi  x5,  x0, 0x123     /* X：lane A，rd=x5（= store 的 rd 字段不会撞）*/
    sw    x7,  0(x6)         /* S：lane B store */
    li    x8,  0x123
    bne   x5,  x8, fail      /* lane A 的写回必须完好 */
    lw    x9,  0(x6)
    bne   x9,  x7, fail      /* store 也必须真的落了盘 */

    /* ---------- 全部通过 ---------- */
    RVTEST_PASS

fail:
    RVTEST_FAIL

/* ----------------------------------------------------------------------------
 * 未对齐异常 handler：记录 mcause/mtval/mepc，mepc += 4 跳过肇事指令。
 * 只用 s2/s3/s4 与 t4，不碰主体别的寄存器（与 tb_laneb_ld.S 同款）。
 * --------------------------------------------------------------------------*/
        .align 2
st_handler:
        csrr  x18, mcause
        csrr  x19, mtval
        csrr  x20, mepc
        addi  x29, x20, 4
        csrw  mepc, x29
        mret

RVTEST_CODE_END

RVTEST_DATA_BEGIN
        .align 4
d_w1:         .word 0x00000000   /* 用例 1：先清 0，被 store 改成 0x22223333 */
d_w2:         .word 0x11223344   /* 用例 2：sb 到 +2 ⇒ 0x11AB3344 */
d_w3:         .word 0x11223344   /* 用例 3：sh 到 +0 ⇒ 0x1122BEEF */
d_w4:         .word 0x00000000   /* 用例 4：两个字（+0 / +4） */
              .word 0x00000000
d_w5:         .word 0x00000000   /* 用例 5：两个字：+0 由 lane A store 写，+4 预置 */
              .word 0x77770000
d_w6:         .word 0x00000000   /* 用例 6：被冲刷的 store 不能碰它 */
d_w8:         .word 0x00000000   /* 用例 8 */
d_victim:     .word 0x11223344   /* 用例 7：奇地址 sh 的靶子 */
RVTEST_DATA_END
