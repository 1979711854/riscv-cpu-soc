/* ============================================================================
 * 定时器中断（CLINT / MTIP）定向测试
 * ----------------------------------------------------------------------------
 * 只验证【核心闭环】，刻意保持最小、显然正确：
 *
 *   1  MIE = 0 时，MTIP 已挂起 → 【不得】触发
 *   2  MIE = 1 后（MTIP 仍挂起） → 【必须】触发
 *   3  处理器内校验 mcause == 0x8000_0007，并把 mtimecmp 推到远未来
 *   4  mret 返回后 mstatus.MIE 必须已由 MPIE 恢复为 1
 *   5  重新武装 mtimecmp 后 → 【必须】再次触发
 *      这条是 MTIP"纯电平比较、写 mtimecmp 后自动落下"的关键验证：
 *      若把 MTIP 做成锁存，mret 恢复 MIE 后会立刻再次 trap，PC 被钉死在
 *      mtvec，用例 5 必然等不到。
 *
 * 刻意【不】校验 mepc 的具体数值：中断是在"下一条指令边界"被受理的，
 * 到底落在哪一条取决于前一条 CSR 指令是否已提交，很容易写成脆弱断言
 * （2026-09-23 在这个坑上绕了很久）。正确性由"返回后程序继续正常执行、
 * 且能再次响应"来保证 —— 返回地址错了根本走不到 PASS。
 *
 * 判分用 riscv-tests 的 tohost 机制（sim/tb_riscv.v 已支持）。
 * 汇编方式见 scripts/run_own_tests.ps1
 * ==========================================================================*/
#include "encoding.h"
#include "riscv_test.h"
#include "test_macros.h"   /* 本机补的最小宏集：TESTNUM / init（见该文件头注释）*/

/* ---- 本项目的外设地址（单一真相见 rtl/bus/addr_map.vh）---- */
#define MTIME      0x80000010      /* R    mtime（= 自由跑周期计数器）*/
#define MTIMECMP   0x80000014      /* W/R  mtimecmp                  */

/* mie.MTIE 与 mip.MTIP 是同一个位（bit7）；这版 encoding.h 只定义了后者 */
#define MIE_MTIE_BIT   MIP_MTIP
/* mcause 的定时器中断编码：bit31 = 中断，低位 = IRQ_M_TIMER(7) */
#define CAUSE_TIMER    ((1 << 31) | IRQ_M_TIMER)

RVTEST_CODE_BEGIN

        /* 装自己的 trap 处理程序（覆盖 RVTEST_CODE_BEGIN 装的 trap_vector）*/
        la    t0, irq_handler
        csrw  mtvec, t0

        li    s0, 0                 /* 中断触发次数 */
        li    s1, 0                 /* 处理器内的错误标志 */

        /* ---- 从"干净状态"开始：MIE=0、MTIE=0、mtimecmp=远未来 ----
         * 复位后本就是 MIE=0/MTIE=0，这里显式写一遍，让测试自洽。*/
        csrwi mstatus, 0
        csrwi mie, 0
        li    t0, MTIMECMP
        li    t1, -1
        sw    t1, 0(t0)

        /* ================= 用例 1：MIE = 0 → 不得触发 ================= */
        li    TESTNUM, 1
        li    t0, MIE_MTIE_BIT
        csrw  mie, t0               /* MTIE = 1；MIE 仍为 0 */
        /* 武装：mtimecmp = mtime + 4，等 MTIP 拉高 */
        li    t0, MTIME
        lw    t1, 0(t0)
        addi  t1, t1, 4
        li    t0, MTIMECMP
        sw    t1, 0(t0)

        li    t2, 64                /* 等足够久，让 MTIP 一定已挂起 */
1:      addi  t2, t2, -1
        bnez  t2, 1b
        bnez  s0, fail              /* MIE=0 竟然还触发了 */

        /* ================= 用例 2：MIE = 1 → 必须触发 ================= */
        li    TESTNUM, 2
        csrsi mstatus, MSTATUS_MIE  /* MIE 0→1；MTIP 此刻已是高 */

        li    t2, 4096              /* 中断应在下一条指令就被受理，这里给足余量 */
2:      addi  t2, t2, -1
        beqz  t2, fail              /* 超时：中断没来 */
        beqz  s0, 2b                /* s0 == 0 说明还没进过处理器 */
        bnez  s1, fail              /* 处理器里发现了错误 */

        /* ================= 用例 3：mret 后 MIE 必须已恢复 ================= */
        li    TESTNUM, 3
        csrr  t0, mstatus
        andi  t0, t0, MSTATUS_MIE
        beqz  t0, fail              /* 没恢复 → 中断再也来不了 */

        /* ================= 用例 4：重新武装后必须能【再次】触发 ============ */
        li    TESTNUM, 4
        mv    t3, s0                /* 记住当前次数 */
        li    t0, MTIME
        lw    t1, 0(t0)
        addi  t1, t1, 4
        li    t0, MTIMECMP
        sw    t1, 0(t0)
        li    t2, 4096
3:      addi  t2, t2, -1
        beqz  t2, fail              /* 超时：第二次中断没来（MTIP 没落下就会这样）*/
        bleu  s0, t3, 3b

        /* 全部通过 */
        RVTEST_PASS

fail:
        RVTEST_FAIL

/* ----------------------------------------------------------------------------
 * trap 处理程序
 * 只处理定时器中断；其余 trap 记错误标志后也 mret 回去，由主体报 fail。
 * 只用 t-reg 与 s0/s1，不碰主体依赖的其他寄存器。
 * --------------------------------------------------------------------------*/
        .align 2
irq_handler:
        csrr  t5, mcause
        li    t6, CAUSE_TIMER
        bne   t5, t6, 9f

        addi  s0, s0, 1             /* 计数 +1 */

        /* [重点] 让 MTIP 自动落下：把 mtimecmp 推到远未来。
         *   本设计里 MTIP 是纯电平比较器，这一写下一拍就翻低 ——
         *   这正是 mret 恢复 MIE 后不会立刻再次 trap 的原因。*/
        li    t5, MTIMECMP
        li    t6, -1                /* 32'hFFFF_FFFF */
        sw    t6, 0(t5)

        mret

9:      ori   s1, s1, 1             /* mcause 不是定时器中断 */
        mret

RVTEST_CODE_END

/* tohost / fromhost / signature 区都在这一段里定义 —— 缺了它链接会找不到
 * `tohost` 符号（RVTEST_PASS/FAIL 要往里写）。本测试没有签名数据。*/
RVTEST_DATA_BEGIN
RVTEST_DATA_END
