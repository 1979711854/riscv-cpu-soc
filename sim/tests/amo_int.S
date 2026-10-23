/* ============================================================================
 * amo_int.S —— T0 最小复现：流水线里【恰好一条】amoadd.w
 * ----------------------------------------------------------------------------
 * 目的（见 doc/reports/2026-10-08_taskbook_A_rv32a.md §T0）：
 *   把「amo_unit 模块对」和「AMO 与流水线的接口对」分开验证。
 *   单元测试 tb_amo.v 已经 17/17，所以这里的失败只可能出在集成上。
 *
 * 为什么要放在 .text.init：
 *   链接脚本把 .text.init 放在 0x0（CPU 复位后的取指地址），.text 放在 0x1000。
 *   写在 .text 里的 _start 会跑到 0x1000，而 CPU 复位到 0 ⇒ 从空处取指。
 *
 * 判据（由 sim/tb_amo_int.v 逐拍打印）：
 *   - ST_LATCH 那一拍 mem_rdata 必须是有效数据，不是 xxxxxxxx
 *   - 写回 rd 的值 = 旧值 0x0F，内存 0x2000 = 0x12
 * ==========================================================================*/
    .section .text.init
    .globl _start
_start:
    li      sp, 0x7F00

    li      t0, 0x2000            # 计数器地址（RAM 内，避开兼容区 0xFFF0+）
    li      t1, 0x0000000F
    sw      t1, 0(t0)             # [0x2000] = 0x0F

    li      t5, 0x3000            # 哨兵地址：与 AMO 的地址【不同】
    li      t6, 0x000000AA
    sw      t6, 0(t5)             # [0x3000] = 0xAA

    li      t2, 0x00000003
    amoadd.w t3, t2, (t0)         # t3 = 旧值 0x0F；[0x2000] = 0x12

    # [!] 紧跟 AMO 的这条 lw 落在【另一个地址】0x3000。
    #   若它与 AMO 抢 MEM 级，trace 里 AMO READ 那拍 mem_addr 会露出 0x3000
    #   （而不是 0x2000），锁回的旧值也会是哨兵 0xAA 而不是 0x0F。
    #   历史上 AMO 与 lw 同址（都读 t0），这个冲突在 trace 里看不出来。
    lw      t4, 0(t5)             # t4 = 哨兵 0xAA
    lw      a5, 0(t0)             # a5 = 读回计数器，应为 0x12

    # UART(0xFFFC) 逐字节汇报：t3 低字节（期望 0f），再 a5 低字节（期望 12）。
    li      t0, 0xFFFC
    sb      t3, 0(t0)
    sb      a5, 0(t0)

    li      t0, 0xFFF8            # done
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b
