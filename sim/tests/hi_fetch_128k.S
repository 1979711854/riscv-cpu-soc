/* ============================================================================
 * 覆盖 B+ —— 「代码 > 64 KB / 取指越过 0x10000」回归（128KB 扩容专用）
 * ----------------------------------------------------------------------------
 * 为什么非有不可：128 KB 扩容后，代码可以越过 0x10000。双发射第二取指口
 * `imem_addr2` 若漏改到 15 位（停在 14 位），取指地址 ≥ 0x10000 时 lane B 会
 * 回绕到低 64 KB。本测试与 hi_fetch.S 同构，只是把回绕边界从 8192 word
 * （0x8000）换成 16384 word（0x10000）—— 这才是本次扩容的直接覆盖。
 *
 * 做法（不改链接脚本）：运行时把一段代码【拷到高地址】再跳过去执行。
 *   * 低地址「毒丸块」：`addi s0, s0, 1` × N，落在 .text（链接脚本放 0x2000）。
 *   * 「执行块」源：`addi t2, t2, 1` × N + 一条 `jalr` 回跳。运行时拷到 D。
 *   * 判据：跑完断言 `s0 == 0 && t2 == N`。
 *
 * 地址数学（关键）：lane B 读 word `W+1`；若 `imem_addr2` 被截成 14 位，则
 *   = `W + 1 − 16384`。
 *   ⇒ 执行块起点 D（word）与毒丸块起点 P（word）须满足 `D = 16383 + P`，
 *     即【字节】上 `D_byte = P_byte + 16383*4 = P_byte + 65532`。
 *   于是执行到 word `D+i` 时，截位的 lane B 恰好落在毒丸 word `P+i`：
 *     * 修好后：lane B 取到真正的下一条 `addi t2,t2,1` ⇒ `rd_a(t2)==rs1_b(t2)` ⇒ 【不配对】
 *       ⇒ PC 逐字推进，`s0` 恒 0、`t2 = N`。
 *     * 截位时：lane B 取到毒丸 `addi s0,s0,1` ⇒ 配对判据成立（t2 != s0、t2 != x0）⇒ lane B
 *       真的执行毒丸 ⇒ **`s0 != 0`**。这就是判据，不用看波形。
 *
 * [!] N 取 2048：执行块目标 D ≈ 0x12000，D + N*4 ≈ 0x14000，远离
 *     0x1FFF0 保留区；源块仍在低 64 KB。功能上任意 N ≥ 1 都能检出。
 *     本测试不用 sp（RVTEST 序言已把寄存器全清零）。
 * ==========================================================================*/

#include "encoding.h"
#include "riscv_test.h"
#include "test_macros.h"

#define N 2048

/* 毒丸块 + 拷贝源，都落 .text（链接脚本把 .text 放在 0x2000）。
 * P 由 `la` 在运行时算出 —— 别写死 0x2000，环境宏的序言长度会变。*/
        .section .text
        .align 4
poison_block:
        .rept N
        addi    s0, s0, 1
        .endr
exec_src:
        .rept N
        addi    t2, t2, 1
        .endr
        jalr    x0, 0(t3)             /* t3 = 返回地址（绝对值，拷贝不变）*/

RVTEST_CODE_BEGIN

        /* ---- 目标地址 D*4 = &poison_block + 8191*4 ---- */
        la      t0, poison_block
        li      t1, 65532             /* 16383 * 4 */
        add     t0, t0, t1            /* t0 = 执行块目标【字节】地址 */

        /* ---- 把执行块源拷到高地址 ---- */
        la      t1, exec_src          /* 拷贝源 */
        la      t3, after_exec        /* 返回地址（执行块末尾的 jalr 用）*/
        li      t5, N+1               /* 拷 N 个字 + 1 条 jalr */
        li      t2, 0                 /* 执行块累加器 */
        li      s0, 0                 /* 毒丸累加器（必须保持 0）*/
copy_loop:
        lw      t4, 0(t1)
        sw      t4, 0(t0)
        addi    t1, t1, 4
        addi    t0, t0, 4
        addi    t5, t5, -1
        bnez    t5, copy_loop
        fence.i

        /* ---- 跳进高地址执行块（PC ≈ 0x12000 ≥ 0x10000）---- */
        la      t0, poison_block
        li      t1, 65532
        add     t0, t0, t1
        jalr    x0, 0(t0)

after_exec:
        /* ---- 校验 ---- */
        bnez    s0, fail_s0           /* s0 != 0 ⇒ 取了指纹毒丸 ⇒ 截位 bug 存在 */
        li      t0, N
        bne     t2, t0, fail_t2       /* 执行块应恰好执行 N 次 */

        RVTEST_PASS

fail_s0:
        li      TESTNUM, 1
        j       do_fail
fail_t2:
        li      TESTNUM, 2
do_fail:
        RVTEST_FAIL

RVTEST_CODE_END

/* tohost / fromhost / signature 区都在这一段里定义 —— 缺了它链接会找不到
 * `tohost` 符号（RVTEST_PASS/FAIL 要往里写）。本测试没有签名数据。*/
RVTEST_DATA_BEGIN
RVTEST_DATA_END
