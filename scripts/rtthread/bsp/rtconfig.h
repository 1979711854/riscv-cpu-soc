/* ============================================================================
 * rtconfig.h —— RT-Thread Nano 配置（为 32KB 统一存储器裁到最小）
 * ----------------------------------------------------------------------------
 * 参照：RT-Thread v5.3.0 的 bsp/core-v-mcu/core-v-cv32e40p/rtconfig.h
 *       （官方 readme.md「RV32 移植指南」里点名的"方式一"范例）
 *
 * [!] 这是**手工裁剪版**，不是 menuconfig 生成的。改这里的任何一项都要
 *     重新编译并核对镜像占用（见 scripts/rtthread/build.ps1 打印的字数）。
 *
 * 裁剪原则：32KB 要同时装【内核 + 应用 + 数据 + 栈】，所以凡是用不到的
 * 组件一律不编 —— 少一个组件，就多几 KB 留给游戏。
 * ==========================================================================*/
#ifndef RT_CONFIG_H__
#define RT_CONFIG_H__

/* ---- 内核基本参数 ---- */
#define RT_NAME_MAX                 8
#define RT_CPUS_NR                  1
#define RT_ALIGN_SIZE               4
#define RT_THREAD_PRIORITY_MAX      32
#define RT_TICK_PER_SECOND          1000
#define RT_VER_NUM                  0x50300

/* ---- 线程栈：小内存下这几个数直接决定能不能装下 ---- */
#define IDLE_THREAD_STACK_SIZE      256
#define RT_MAIN_THREAD_STACK_SIZE   1024
#define RT_MAIN_THREAD_PRIORITY     10

/* ---- 线程间通信：全开（每个才几百字节）---- */
#define RT_USING_SEMAPHORE
#define RT_USING_MUTEX
#define RT_USING_EVENT
#define RT_USING_MAILBOX
#define RT_USING_MESSAGEQUEUE

/* ---- 内存管理：只用 small mem（slab/memheap 各要一份独立实现，不编）---- */
#define RT_USING_SMALL_MEM
#define RT_USING_SMALL_MEM_AS_HEAP
#define RT_USING_HEAP

/* ---- 控制台：rt_kprintf 走 UART，由 board.c 的 rt_hw_console_output 实现 ---- */
#define RT_USING_CONSOLE
#define RT_CONSOLEBUF_SIZE          128

/* kservice.c 的 rt_backtrace_frame() 无条件引用这个宏（那函数是 rt_weak，
 * 不因配置而消失），所以即使不开调试也必须定义 —— 它只是栈回溯的循环上界。 */
#define RT_BACKTRACE_LEVEL_MAX_NR   32

/* ---- 启动方式：走 rt_application_init 建 main 线程 ---- */
#define RT_USING_USER_MAIN

#define ARCH_RISCV

/* ============================================================================
 * 以下【故意不定义】—— 每一条都是在 32KB 里省内存/省代码，不是漏了：
 *
 *   RT_USING_TIMER_SOFT      软件定时器线程（+512 字节栈 + 一个线程控制块）。
 *                            只用硬件定时器回调的话不需要它。
 *   RT_USING_DEVICE          设备框架。我们的 console 直接走 rt_hw_console_output，
 *                            不经过设备模型，所以框架本身可以不要。
 *   RT_USING_SERIAL/PIN      设备驱动。外设直接用 MMIO 访问，不走驱动框架。
 *   RT_USING_DEVICE_IPC      device 框架配套。
 *   RT_USING_MSH / FINSH_*   命令行 shell（光栈就 4096 字节 + 一大堆命令表）。
 *                            32KB 下装不起；要它的时候再说。
 *   RT_USING_DEBUG           调试代码。出问题时临时打开。
 *   RT_USING_HOOK            钩子机制。
 *   RT_USING_COMPONENTS_INIT 组件自动初始化。手工调用初始化函数，
 *                            省掉自动初始化的段与遍历代码。
 * ==========================================================================*/

#endif /* RT_CONFIG_H__ */
