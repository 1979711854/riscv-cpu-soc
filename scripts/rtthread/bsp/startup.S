/* ============================================================================
 * startup.S —— 复位入口 _start
 * ----------------------------------------------------------------------------
 * 复位后 PC = 0x0，从这里开始。做三件事：
 *   1. 把 sp 设到栈顶（__stack_top = 0xFFF0）
 *   2. 清 .bss（C 语言要求未初始化全局变量为 0）
 *   3. 调 rtthread_startup()（RT-Thread 的 C 入口，永不返回）
 *
 * [!] 开机时用的这条栈就是__rt_rvstack 那条栈 —— 引导阶段和中断阶段共用。
 *     调 rt_hw_context_switch_to 之后，线程各用各的栈，这条栈只服务中断。
 *
 * [!] 不在这里开中断。开中断的时机由 board.c 决定（设置 mtvec + mie 的 MTIE）。
 * ==========================================================================*/

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function

_start:
    /* 1. 栈顶。用 la 取链接脚本里的符号，别写死地址 —— 改布局时不用动这里 */
    la    sp, __stack_top

    /* 2. 清 .bss */
    la    a0, _bss_start
    la    a1, _bss_end
    bgeu  a0, a1, 2f
1:
    sw    zero, 0(a0)
    addi  a0, a0, 4
    bltu  a0, a1, 1b
2:

    /* 3. 交给 RT-Thread。rtthread_startup() 里有 rt_hw_board_init()，
     *    它会装 mtvec、初始化堆和控制台，最后启动调度器 —— 不会返回。 */
    call  rtthread_startup

    /* 万一返回了（不该发生），停在这里便于调试时看出是启动失败 */
3:
    j     3b
