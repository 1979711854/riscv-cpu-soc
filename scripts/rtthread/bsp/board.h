/* ============================================================================
 * board.h —— 本板（盘古 MES2L676-200HP）的板级定义
 * ----------------------------------------------------------------------------
 * 地址来自 rtl/bus/addr_map.vh（SoC 唯一真相）。改地址必须三处同步：
 *   1. rtl/bus/addr_map.vh
 *   2. scripts/demo/addr_map.h
 *   3. 本文件
 * ==========================================================================*/
#ifndef __BOARD_H__
#define __BOARD_H__

/* ---- 系统时钟：用于把 tick/延时换算成 mtime 周期数 ----
 *
 * 三套口径别混（和 项目约定文档 里说的一样）：
 *   上板（本地盘古板）  85.0051 MHz（RATIO0=13.5）/ **76.5052 MHz（RATIO0=15.0，带 Cache 的降频档）**
 *                       —— 板上是哪一档由【位流里的 PLL】决定，所以本值必须与它配套，
 *                          且横幅打印的主频也从这里来（**不许在 .c 里写死**，见 app/main.c）。
 *   仿真                100 MHz      测试台写 `always #5 clk`；build.ps1 -Sim 传 100000000
 *   远程 FPGA 平台      27 MHz       没有 PLL
 *
 * 所以【不能写死】。build.ps1 -Sim 会自动传 100000000，上板用默认值。
 * [!] 算错的后果：tick 周期按倍率偏 —— 功能还能跑（mdelay 数的是 tick 个数），
 *     但仿真里每 500ms 会多跑或少跑相应倍数的周期，白白拖慢仿真或让延时失真。
 * [!] 改频率时本文件容易被漏掉（早期文档只列了 3 处常量，没算上这里）。
 *     完整清单见 rtl/top/cpu_top_board.v 头部注释。 */
#ifndef BOARD_SYSTEM_CLOCK_HZ
#define BOARD_SYSTEM_CLOCK_HZ       76505200u
#endif

/* ---- 外设 MMIO（字地址，直接读写）-------------------------------------- */
#define MMIO_GPIO_BASE              0x80000000u  /* W LED[7:0] / R {key[7:0], led[7:0]} */
#define MMIO_UART_TX                0x80000008u  /* W 发一个字符 */
#define MMIO_UART_RX                0x8000000Cu  /* R {valid, 23'b0, data[7:0]}，读清 valid */
#define MMIO_MTIME                  0x80000010u  /* R 周期计数器 [31:0] */
#define MMIO_MTIMECMP               0x80000014u  /* W/R 定时器比较值 */

/* ---- 兼容区（CoreMark 硬编码，不可移动；栈顶必须避开 0xFFF0 以上）---- */
#define MMIO_LEGACY_CYCLE           0x0000FFF4u
#define MMIO_LEGACY_DONE            0x0000FFF8u
#define MMIO_LEGACY_UART_TX         0x0000FFFCu

/* ---- 中断号：RT-Thread 的 irq_id = mcause & 0x1F ----
 * 本 CPU 只产生两种中断：
 *   MTIP（mcause = 0x8000_0007）→ irq_id 7   ← 系统 tick 用它
 *   MEIP（mcause = 0x8000_000B）→ irq_id 11  ← 外部中断（UART RX 非空），
 *                                              [！] 通路具备但本工程未使用、无测试
 * 参考：rtl/core/csr_file.v 的 mip/mie 只实现 MTIP(bit7)/MEIP(bit11) */
#define IRQ_MTIP                    7
#define IRQ_MEIP                    11

/* RT-Thread 的中断表长度（trap_common.c 默认 32），7 和 11 都在范围内 */
#define BOARD_IRQ_NUM               32

#endif /* __BOARD_H__ */
