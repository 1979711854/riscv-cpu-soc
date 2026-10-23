/* ============================================================================
 * 演示程序：读按键 -> 写 LED -> 串口打印
 * ----------------------------------------------------------------------------
 * 这是赛题基础任务③「外设系统集成」的验收程序，也是应用场景雏形：
 *   * 轮询按键（0x8000_0000 高字节，低有效），把状态镜像到 LED（低字节）
 *   * 按键状态变化时，经软件去抖确认后通过串口打印一行
 *   * 同时轮询串口接收（0x8000_000C），收到字符就回显 —— 构成最小交互终端
 *
 * 期望的串口输出（测试台 sim/tb_demo.v 就是照这个逐行比对的）：
 *   RV32I SoC demo ready\r\n
 *   KEY=0x00 LED=0x00\r\n          <- 上电初始状态
 *   KEY=0x01 LED=0x01\r\n          <- 按下 KEY1
 *   KEY=0x00 LED=0x00\r\n          <- 松开
 *   KEY=0x08 LED=0x08\r\n          <- 按下 KEY4
 *   RX=A\r\n                       <- 从串口收到 'A'
 * ==========================================================================*/
#include "addr_map.h"

#define REG32(a)  (*(volatile unsigned int   *)(a))
#define REG8(a)   (*(volatile unsigned char  *)(a))

#define KEY_ACTIVE_LOW  0x1u

/* 去抖等待时长。机械按键抖动在 ms 量级，10ms 足够。
 * （27MHz 下 10ms = 270000 个周期）*/
#define DEBOUNCE_MS     10u

/* ------------------------------------------------------------------ */
/* 串口输出                                                            */
/* ------------------------------------------------------------------ */
static void uart_putc(char c)
{
    REG8(UART_TX) = (unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex8(unsigned v)
{
    unsigned hi = (v >> 4) & 0xFu;
    unsigned lo = v & 0xFu;
    uart_putc(hi < 10u ? (char)('0' + hi) : (char)('A' + hi - 10u));
    uart_putc(lo < 10u ? (char)('0' + lo) : (char)('A' + lo - 10u));
}

/* ------------------------------------------------------------------ */
/* 外设访问                                                            */
/* ------------------------------------------------------------------ */

/* LED 写 + 按键读共用一个寄存器（见 rtl/periph/gpio.v） */
static void gpio_write_led(unsigned v)
{
    REG32(GPIO_BASE) = v & 0xFFu;
}

/* 返回"哪些键被按下"，1 = 按下。硬件给的是原始电平（低有效），这里取反成直观语义 */
static unsigned gpio_read_keys(void)
{
    unsigned raw = REG32(GPIO_BASE);
    return (~(raw >> 8)) & 0xFFu;
}

static void delay_ms(unsigned ms)
{
    unsigned start = REG32(TIMER);
    unsigned ticks = ms * (CPU_HZ / 1000u);

    /* 无符号减法天然处理 32 位回绕 */
    while ((REG32(TIMER) - start) < ticks)
        ;
}

/* ------------------------------------------------------------------ */
/* 主循环                                                              */
/* ------------------------------------------------------------------ */
int main(void)
{
    unsigned keys;
    unsigned last;

    gpio_write_led(0);
    uart_puts("RV32I SoC demo ready\r\n");

    last = gpio_read_keys();
    uart_puts("KEY=0x");
    uart_puthex8(last);
    uart_puts(" LED=0x");
    uart_puthex8(last);
    uart_puts("\r\n");

    for (;;) {
        /* ---- 按键：变化 -> 去抖 -> 确认 -> 镜像到 LED 并打印 ---- */
        keys = gpio_read_keys();
        if (keys != last) {
            delay_ms(DEBOUNCE_MS);
            keys = gpio_read_keys();
            if (keys != last) {
                last = keys;
                gpio_write_led(keys);
                uart_puts("KEY=0x");
                uart_puthex8(keys);
                uart_puts(" LED=0x");
                uart_puthex8(keys);
                uart_puts("\r\n");
            }
        }

        /* ---- 串口接收：只读一次。
         * 这个寄存器读操作会【弹出】FIFO 头部，所以不能写
         * while (!(REG32(UART_RX) >> 31)); —— 那会在判断里就把字节吃掉。 ---- */
        {
            unsigned rx = REG32(UART_RX);
            if (rx >> 31) {
                uart_puts("RX=");
                uart_putc((char)(rx & 0xFFu));
                uart_puts("\r\n");
            }
        }
    }
}
