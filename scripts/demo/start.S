/* ============================================================================
 * 演示程序启动代码
 * ==========================================================================*/
    .section .text.init
    .globl _start
    .type _start, @function
_start:
    li   sp, 0xF000          /* 栈顶（RAM 高端，向下生长） */

    /* 清 .bss */
    la   t0, _bss_start
    la   t1, _end
1:
    bge  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main

    /* main 正常不会返回（死循环）。真返回了就用 EBREAK 停机，
     * 由 cpu_top 把 done 拉高点灯 —— 顺带验证 EBREAK 的停机钩子。 */
    ebreak
3:
    j    3b
