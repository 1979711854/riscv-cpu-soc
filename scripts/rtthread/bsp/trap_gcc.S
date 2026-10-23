/* ============================================================================
 * trap_gcc.S —— 中断入口与分发（RT-Thread「RV32 移植指南」的方式一）
 * ----------------------------------------------------------------------------
 * 源码依据：libcpu/risc-v/common/readme.md §4 步骤三「方式一」
 *           （官方原文："该函数的实现如下（用户直接使用，无需修改）"）
 *
 * 整条中断路径（对照 libcpu/risc-v/common/interrupt_gcc.S）：
 *
 *   mtvec = SW_handler          ← 在 board.c 里设置；我们只支持 direct 模式
 *     ↓
 *   SW_handler:                 ← interrupt_gcc.S 提供
 *     关 MIE → 存线程上下文到【线程栈】
 *     csrrw sp, mscratch, sp    ← 切到【中断栈】（mscratch 里是 __rt_rvstack）
 *     call rt_interrupt_enter
 *     call rt_hw_do_after_save_above    ← 【本文件】
 *     call rt_interrupt_leave
 *     按需切线程 → 恢复上下文 → mret
 *
 * 所以本文件只干一件事：把控制权交给 rt_common 里的统一分发函数。
 * ==========================================================================*/

#include "cpuport.h"

    .globl rt_hw_do_after_save_above
    .type  rt_hw_do_after_save_above,@function
rt_hw_do_after_save_above:
    addi  sp, sp,  -4
    STORE ra,  0 * REGBYTES(sp)

    csrr  a0, mcause          /* 传给分发函数：mcause */
    csrr  a1, mepc            /* 备用：出错时的返回地址 */
    mv    a2, sp              /* 备用：当前栈帧 */
    call  rt_rv32_system_irq_handler

    LOAD  ra,  0 * REGBYTES(sp)
    addi  sp, sp,  4
    ret

/* [!] 方式一【不需要】rt_trigger_software_interrupt ——
 *     那个函数只在「向量中断」方式下才要（用软件中断触发上下文切换）。
 *     我们的 mtvec 只支持 direct 模式（csr_file.v 里写入时强制 {addr[31:2], 2'b00}），
 *     走的是非向量方式，所以不实现它。
 *
 *     若日后有人把 mtvec 改成向量模式，这个文件要按 readme 的方式二重写。 */
