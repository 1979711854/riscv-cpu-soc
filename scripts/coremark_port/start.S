    .section .text.init
    .globl _start
    .type _start, @function
_start:
    li   sp, 0xF000        # 栈顶（dmem 高端，向下生长）

    # 清 .bss
    la   t0, _bss_start
    la   t1, _end
1:
    bge  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main

    # main 返回后写 tohost=1 通知 testbench 结束
    li   t0, 0xFFF8
    li   a0, 1
    sw   a0, 0(t0)
3:
    j    3b
