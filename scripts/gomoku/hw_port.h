/* ============================================================================
 * hw_port.h —— 游戏用到的硬件端口（按键 / 时间 / 串口）
 * ----------------------------------------------------------------------------
 * 与 render.h 的 vid_bulk_write 同一个套路：**声明放在平台无关的模块里，
 * 实现分两份**——
 *     固件侧：hw_port.c（MMIO 直读 / 直写）
 *     x86 侧：测试文件自己造假的（假按键序列 + 假时间）
 * 这样 input.c / game.c 两边跑同一份源码，逻辑改动在 PC 上秒级验证。
 * ==========================================================================*/
#ifndef GOMOKU_HW_PORT_H
#define GOMOKU_HW_PORT_H

#include <stdint.h>

/* 读原始按键字节 {key[7:0]}，**按下 = 0**（低有效）。
 * [!] 硬件只做 2 级同步、**不做消抖**（rtl/periph/gpio.v 注释明说消抖放软件），
 *     所以调用方必须自己去抖 —— 这就是 input.c 存在的理由。 */
uint8_t hw_key_raw(void);

/* 自由跑的周期计数器（mtime），板上是 85.0051 MHz。
 * 只用来算【时间差】，不要当绝对时间用。 */
uint32_t hw_mtime(void);

/* 串口发一个字符（调试用，不发也行） */
void hw_uart_putc(char c);

void hw_uart_puts(const char *s);

/* 把周期差换算成毫秒。
 * 放在端口层是因为这个换算依赖板上时钟 —— 换板子/换主频只改这一处。 */
uint32_t hw_ticks_to_ms(uint32_t ticks);

/* 每毫秒多少计数（板上 = CPU_HZ/1000）。**init 类函数的阈值参数就是这么来的**：
 *      input_init(&in, t, keys, INPUT_DEBOUNCE_MS * hw_ticks_per_ms(), ...)
 * 不要自己在别处写 85005 之类的常数 —— 换主频时那会变成静默的错。 */
uint32_t hw_ticks_per_ms(void);

#endif /* GOMOKU_HW_PORT_H */
