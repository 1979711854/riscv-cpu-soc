/* ============================================================================
 * hw_port.c —— 游戏用到的硬件端口的固件侧实现（MMIO 直读直写）
 * ----------------------------------------------------------------------------
 * 本文件是【固件专用】：x86 单测自己造一份假的（假按键序列 + 假时间），
 * 所以不编译这个文件。两边实现同一个接口，input.c / game.c 因此两边同一份源码。
 *
 * 地址定义来自 scripts/demo/addr_map.h（它是 rtl/bus/addr_map.vh 的软件侧影子，
 * 改一处要同步改另一处）。
 * ==========================================================================*/
#include "addr_map.h"
#include "hw_port.h"

#define REG8(a)  (*(volatile unsigned char  *)(a))
#define REG32(a) (*(volatile unsigned int   *)(a))

uint8_t hw_key_raw(void)
{
    /* GPIO 读回 {key[7:0], led[7:0]}：高 8 位是按键、低 8 位是 LED。
     * **按下 = 0**（低有效）—— 但顶层只把其中 4 个 bit 接到了真实按键
     * （cpu_top_board.v 里 .key({4'b1111, key})），所以高位恒为 1。 */
    return (uint8_t)(REG32(GPIO_BASE) >> 8);
}

uint32_t hw_mtime(void)
{
    return REG32(TIMER);
}

void hw_uart_putc(char c)
{
    REG8(UART_TX) = (unsigned char)c;
}

void hw_uart_puts(const char *s)
{
    while (*s) hw_uart_putc(*s++);
}

uint32_t hw_ticks_per_ms(void)
{
    /* 板上时钟见 addr_map.h 的 CPU_HZ（当前 85,005,100）。
     * **别写死 27e6 / 49.89e6 / 62.03e6** —— 那些是历史口径，以 PDS 时序报告的实际频率为准。 */
    return CPU_HZ / 1000u;
}

uint32_t hw_ticks_to_ms(uint32_t ticks)
{
    return ticks / hw_ticks_per_ms();
}
