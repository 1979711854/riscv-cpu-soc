/* ============================================================================
 * board.c —— RT-Thread 板级支持包（BSP）
 * ----------------------------------------------------------------------------
 * 这个文件把 RT-Thread 接到我们自己的 RV32IM CPU 上。必须实现的东西只有四件：
 *
 *   1. rt_hw_board_init()       启动时被 rtthread_startup() 调用：
 *                               装 mtvec、初始化堆、初始化控制台、开 tick 中断
 *   2. rt_hw_console_output()   rt_kprintf 的出字口（写 UART_TX）
 *   3. timer_irq_handler()      MTIP 中断服务程序，里面只调 rt_tick_increase()
 *   4. (可选) rt_hw_console_getchar() / rt_hw_us_delay()
 *
 * 中断路径见 bsp/trap_gcc.S 的头注释。
 *
 * 端口地址与中断号见 bsp/board.h（其源头是 rtl/bus/addr_map.vh）。
 * ==========================================================================*/

#include <rthw.h>
#include <rtthread.h>

#include "board.h"
#include "riscv-ops.h"      /* read_csr / write_csr，来自 libcpu/risc-v/common */

/* 中断入口，定义在 libcpu/risc-v/common/interrupt_gcc.S。
 * [!] 我们的 mtvec 只支持 direct 模式（csr_file.v 写入时强制 {addr[31:2],2'b00}），
 *     所以直接把它的地址写进 mtvec —— 不用向量表。 */
extern void SW_handler(void);

/* 堆的起止，来自 link.ld（PROVIDE 出来的符号） */
extern char __heap_start;
extern char __heap_end;

/* ---- 寄存器读写小工具（volatile，别让编译器优化掉）---- */
#define REG32(addr)     (*(volatile rt_uint32_t *)(addr))

static rt_uint32_t mtimecmp_next;   /* 下一个比较值，每次 tick 递增 */
static const  rt_uint32_t TICK_CYCLES =
    (BOARD_SYSTEM_CLOCK_HZ + RT_TICK_PER_SECOND / 2) / RT_TICK_PER_SECOND;

/* ============================================================================
 * 控制台：把一个字符写进 UART 发送口
 * ----------------------------------------------------------------------------
 * [!] 没有流控。uart_tx 里是 1024 深的 FIFO，没有"忙"状态寄存器可读，
 *     所以这里只能直接写。短字符串（rt_kprintf 上限 RT_CONSOLEBUF_SIZE=128）
 *     远小于 FIFO 容量，不会溢出；**连续打超长字符串有可能丢字符**。
 *     真需要流控时改 RTL 加一个状态寄存器，别在这里加延时糊。
 * ==========================================================================*/
void rt_hw_console_output(const char *str)
{
    while (*str != '\0')
    {
        if (*str == '\n')
        {
            /* 串口终端要 \r\n 才会回到行首；只发 \n 的话会呈阶梯状 */
            REG32(MMIO_UART_TX) = '\r';
        }
        REG32(MMIO_UART_TX) = (rt_uint32_t)(*str);
        str++;
    }
}

/* 收字符（读清 valid）。读 0 表示暂无数据 —— 不用 -1，RT-Thread 认非负返回值。
 * [!] 目前只给 shell / 调试用；rtconfig.h 里没开 MSH，所以暂时没人调它。 */
char rt_hw_console_getchar(void)
{
    rt_uint32_t v = REG32(MMIO_UART_RX);
    if (v & 0x80000000u)        /* 最高位是 valid */
    {
        return (char)(v & 0xFFu);
    }
    return 0;
}

/* ============================================================================
 * 系统 tick：MTIP 中断服务程序
 * ----------------------------------------------------------------------------
 * 注册进 RT-Thread 的中断表（irq_id = 7 = mcause 0x80000007 的低 5 位）。
 * 约定：ISR 里只做事、不阻塞；重活丢给线程。
 * ==========================================================================*/
static void timer_irq_handler(int vector, void *param)
{
    RT_UNUSED(vector);
    RT_UNUSED(param);

    /* mtime >= mtimecmp 会一直拉着 MTIP，所以必须往前推 mtimecmp 才会落下。
     * 用「加法」而不是「重新读 mtime 再加」—— 后者会随中断延迟累积漂移。 */
    mtimecmp_next += TICK_CYCLES;
    REG32(MMIO_MTIMECMP) = mtimecmp_next;

    rt_tick_increase();
}

/* 启动 tick：设第一个比较值 + 打开 MTIE */
static void rt_hw_timer_init(void)
{
    rt_base_t level = rt_hw_interrupt_disable();

    mtimecmp_next = REG32(MMIO_MTIME) + TICK_CYCLES;
    REG32(MMIO_MTIMECMP) = mtimecmp_next;

    /* 注册中断入口。trap_common.c 的 rt_hw_interrupt_init() 已经把整张表
     * 填成"未处理"占位函数，这里只覆盖 7 号。 */
    rt_hw_interrupt_install(IRQ_MTIP, timer_irq_handler, RT_NULL, "mtip");

    /* 打开 mstatus.MIE（全局）+ mie.MTIE（定时器） */
    set_csr(mie, 1 << IRQ_MTIP);
    set_csr(mstatus, 1 << 3);       /* mstatus.MIE = bit3 */

    rt_hw_interrupt_enable(level);
}

/* ============================================================================
 * 微秒级延时（读 mtime 轮询）。给驱动/初始化用，别在中断里长延时。
 * ==========================================================================*/
void rt_hw_us_delay(rt_uint32_t us)
{
    rt_uint32_t start = REG32(MMIO_MTIME);
    rt_uint32_t ticks = (rt_uint32_t)(((rt_uint64_t)us * BOARD_SYSTEM_CLOCK_HZ) / 1000000u);

    /* mtime 是 32 位、85.0051MHz 下约 50 秒回绕一次。用无符号差值比较，
     * 回绕也能正确工作。 */
    while ((rt_uint32_t)(REG32(MMIO_MTIME) - start) < ticks)
    {
        /* 空转 */
    }
}

/* ============================================================================
 * 板级初始化 —— rtthread_startup() 的第一件事
 * ==========================================================================*/
void rt_hw_board_init(void)
{
    /* 1. 中断入口。mtvec 只支持 direct 模式，直接写 SW_handler 的地址。
     *    [!] SW_handler 在 .text.entry 段且 4 字节对齐（link.ld 里保证的），
     *        否则写进 mtvec 后地址低位会被截断，跳飞。 */
    write_csr(mtvec, (rt_uint32_t)(rt_ubase_t)SW_handler);

    /* 2. 中断分发表初始化（trap_common.c 提供） */
    rt_hw_interrupt_init();

    /* 3. 堆：link.ld 里 __heap_start = _end（代码+数据之后）、__heap_end = 0xF000
     *    （栈底之前）。32KB 里代码一大，堆就小 —— 不够时先裁 rtconfig.h。 */
    rt_system_heap_init(&__heap_start, &__heap_end);

    /* 4. 控制台。rtconfig.h 里没开 RT_USING_DEVICE，所以不用 rt_console_set_device，
     *    rt_kprintf 会直接走到上面那个 rt_hw_console_output()。 */

    /* 5. 系统 tick（最后做 —— 它一开就会有中断进来） */
    rt_hw_timer_init();

    /* [!] 这里本来可以调 rt_components_board_init() 做组件自动初始化，
     *     但 rtconfig.h 里故意没开 RT_USING_COMPONENTS_INIT（省代码），
     *     需要初始化的东西在本函数里手工调。 */
}
