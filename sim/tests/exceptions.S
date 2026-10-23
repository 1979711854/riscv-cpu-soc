/* ============================================================================
 * 同步异常定向测试
 * ----------------------------------------------------------------------------
 * 逐个验证五类同步异常的 mcause / mtval / mepc 语义，以及 mret 能正确返回：
 *
 *   1  ECALL                → mcause = 11 (Environment call from M)
 *   2  EBREAK               → mcause = 3  (Breakpoint)
 *   3  未定义 opcode        → mcause = 2  (Illegal instruction)
 *   4  写只读 CSR           → mcause = 2（`unimp` 的规范语义）
 *   5  未对齐 lh            → mcause = 4  (Load address misaligned)，mtval = 出错地址
 *   6  未对齐 sw            → mcause = 6  (Store address misaligned)，mtval = 出错地址
 *      并且要验证这次 store 【没有真的写进内存】—— 异常指令绝不能提交副作用
 *
 * 处理器统一做两件事：
 *   * 把 mcause / mtval / mepc 记到 s1 / s2 / s3 供主体校验
 *   * `mepc += 4` 跳过肇事指令，让主体能继续往下跑
 *     （异常与中断不同：异常的 mepc 指向【肇事指令本身】，中断指向被打断的下一条）
 *
 * 判分用 riscv-tests 的 tohost 机制。汇编见 scripts/run_own_tests.ps1
 * ==========================================================================*/
#include "encoding.h"
#include "riscv_test.h"
#include "test_macros.h"

/* 靶子：RAM 里一个正常可读写的字。未对齐 store 必须陷入异常、
 * 且绝不能改动这个字 —— 那是"异常指令不产生副作用"的直接证据。
 *
 * [!] 别用外设区地址当靶子：0x8000_0020 之类没有外设响应，写进去读出来是 0，
 * 会让"写进去再读回来"的校验当场失败（2026-09-23 实踩）。
 * 这里取 RAM 高处的空闲字，避开代码、数据段与兼容区（0xFFF0 起）。*/
#define VICTIM    0x00007F00

RVTEST_CODE_BEGIN

        la    t0, exc_handler
        csrw  mtvec, t0

        li    s1, 0               /* 最近一次 mcause */
        li    s2, 0               /* 最近一次 mtval  */
        li    s3, 0               /* 最近一次 mepc   */

        /* ================= 用例 1：ECALL → mcause 11 ================= */
        li    TESTNUM, 1
        li    s1, -1
ecall_site:
        ecall
        li    t0, 11
        bne   s1, t0, fail
        /* mepc 必须指向 ecall 自己 */
        la    t0, ecall_site
        bne   s3, t0, fail

        /* ================= 用例 2：EBREAK → mcause 3 ================= */
        li    TESTNUM, 2
        li    s1, -1
ebreak_site:
        ebreak
        li    t0, 3
        bne   s1, t0, fail

        /* ================= 用例 3：未定义 opcode → mcause 2 ========= */
        li    TESTNUM, 3
        li    s1, -1
        .word 0x0000007f          /* 未定义 opcode=1111111 */
        li    t0, 2
        bne   s1, t0, fail

        /* ================= 用例 4：写只读 CSR → mcause 2 ============ */
        li    TESTNUM, 4
        li    s1, -1
        csrrw x0, cycle, x0       /* = unimp：写只读 CSR */
        li    t0, 2
        bne   s1, t0, fail

        /* ================= 用例 5：未对齐 lh → mcause 4 ============ */
        li    TESTNUM, 5
        li    s1, -1
        li    t0, VICTIM
        lh    t1, 1(t0)           /* VICTIM+1 是奇地址 → 半字未对齐 */
        li    t0, 4
        bne   s1, t0, fail
        /* mtval 必须是出错地址 */
        li    t0, VICTIM + 1
        bne   s2, t0, fail

        /* ================= 用例 6：未对齐 sw → mcause 6 ============ */
        li    TESTNUM, 6
        li    s1, -1
        /* 先把靶子的原值写成可识别的 0x11223344 */
        li    TESTNUM, 9
        li    t0, VICTIM
        li    t1, 0x11223344
        sw    t1, 0(t0)
        lw    t2, 0(t0)
        li    t3, 0x11223344
        bne   t2, t3, fail

        /* 再对 VICTIM+1 做【未对齐】的 sw：它必须陷入异常，且绝不能改内存 */
        li    t0, VICTIM
        li    t1, 0xDEADBEEF
        sw    t1, 1(t0)           /* 地址 = VICTIM+1 → 未对齐 */

        li    t0, 6
        bne   s1, t0, fail        /* mcause 必须 = 6 */
        li    TESTNUM, 7
        li    t0, VICTIM + 1
        bne   s2, t0, fail        /* mtval = 出错地址 */

        /* [重点] 关键：原值必须原封不动 —— 异常指令没有产生任何副作用 */
        li    TESTNUM, 8
        li    t0, VICTIM
        lw    t2, 0(t0)
        li    t3, 0x11223344
        bne   t2, t3, fail

        /* 全部通过 */
        RVTEST_PASS

fail:
        RVTEST_FAIL

/* ----------------------------------------------------------------------------
 * 同步异常处理程序
 * 记录 mcause/mtval/mepc，然后 mepc += 4 跳过肇事指令。
 * 只使用 t-reg 与 s1/s2/s3，不碰主体别的寄存器。
 * --------------------------------------------------------------------------*/
        .align 2
exc_handler:
        csrr  s1, mcause
        csrr  s2, mtval
        csrr  s3, mepc
        addi  t4, s3, 4           /* 跳过肇事指令 */
        csrw  mepc, t4
        mret

RVTEST_CODE_END

RVTEST_DATA_BEGIN
RVTEST_DATA_END
