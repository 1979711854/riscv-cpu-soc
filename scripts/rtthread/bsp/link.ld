/* ============================================================================
 * link.ld —— RT-Thread 的链接脚本（128KB 统一存储器，第二程序区）
 * ----------------------------------------------------------------------------
 * 布局（与 scripts/boot/link.ld、scripts/coremark_port/link.ld 同一张图）：
 *
 *   0x00000 ┌──────────────┐
 *           │  boot.S      │  复位入口，松开按键 → 0x10000
 *   0x01000 ├──────────────┤
 *           │  CoreMark    │  跑分档（栈顶 0xF000）
 *   0x10000 ├──────────────┤  ← 本镜像起点（boot.S 里 jr 0x10000）
 *           │  .text       │  代码
 *           │  .rodata     │  常量（T7 起 ALIGN(4)，不再吃 4KB 页对齐）
 *           │  .data       │  已初始化数据
 *           │  .bss        │  未初始化数据（含 3 条线程栈）
 *   _end    ├──────────────┤
 *           │  堆          │  rt_system_heap_init(_end, __heap_end)
 *   0x1FFF0 ├──────────────┤
 *           │  栈 / 中断栈  │  向下生长
 *   0x1FFF0 └──────────────┘  __stack_top = __rt_rvstack
 *   (0x1FFF0~0x1FFFF 保留，不许当 RAM 用 —— 见下)
 *
 * [!] 四条硬约束，改这个文件前先读：
 *   1. 起点必须是 **0x10000**。scripts/boot/boot.S 是直接 `jr 0x10000` 的，
 *      改这里不改 boot.S 就会跳进 CoreMark 的中段（或空白区）。
 *   2. 栈顶必须 <= **0x1FFF0**（不含）。0x1FFF0~0x1FFFF 是保留区：
 *      它的 addr[15:4] 也是 0xFFF，兼容区判决一旦漏掉 `!addr[16]`
 *      （rtl/bus/mem_bus.v）就会被误判成 MMIO。栈往下长也可能撞进这里，
 *      所以栈顶定在 0x1FFF0，最后 16 字节留给"踩线即报错"的安全边界。
 *      低 64KB 的 0xFFF0~0xFFFF 是 CoreMark 兼容区 MMIO（0xFFF4 计时 /
 *      0xFFF8 done / 0xFFFC UART），本程序**不碰**，但也绝不能把数据放进去。
 *   3. __rt_rvstack 必须存在。libcpu/risc-v/common/context_gcc.S 的
 *      rt_hw_context_switch_to 会 `la t0, __rt_rvstack` 并写进 mscratch ——
 *      它同时是「开机引导栈顶」和「中断栈顶」。少这个符号会链接失败。
 *   4. 堆和栈不能重叠。0x10000~0x1FFF0 这段是代码 + 数据 + 堆，
 *      代码一大，堆就小；堆不够用时先裁 rtconfig.h（关组件），别去动栈。
 * ==========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

/* 栈顶：__rt_rvstack 与 __stack_top 是同一个位置（栈向下生长）
 * 栈区留 4KB（0x1EFF0~0x1FFF0），与上一版 0xF000~0xFFF0 的 4KB 等价 ——
 * 堆的顶端停在 __heap_end，**不能**顶到栈顶，否则中断一来就踩穿堆。 */
__stack_top = 0x1FFF0;
PROVIDE(__rt_rvstack = __stack_top);
PROVIDE(__stack_bottom = 0x1EFF0);
PROVIDE(__heap_end = 0x1EFF0);

SECTIONS
{
  . = 0x10000;

  /* 中断入口 SW_handler 在 .text.entry 段里，必须放在最前面且 4 字节对齐 ——
   * mtvec 只有 direct 模式，写进去的是 {addr[31:2], 2'b00}，不对齐会跳飞。 */
  .text.init : { *(.text.init) *(.text.startup) }
  . = ALIGN(4);
  .text : {
    *(.text.entry)
    *(.text .text.*)
  }

  /* [T7 2026-10-19] 原来这里是 ALIGN(0x1000) —— 继承自 demo/coremark 链接脚本
   *   的历史遗产（当年 imem/dmem 分柜时代按 4KB 页切）。elf2mem 按【段名】+
   *   VMA 分桶，根本不看边界；这个 4KB 对齐在 .text 已到 50KB 的今天白白浪费
   *   ~3.3KB 堆（镜像 101% 装不下的直接原因之一）。改成 ALIGN(4)。
   *   代价：无 —— 代码/数据都在同一块统一 RAM 里，地址平移不改变语义。 */
  . = ALIGN(4);
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  . = ALIGN(4);
  .data   : { *(.data .data.* .sdata .sdata.*) }

  . = ALIGN(8);
  .bss : {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.*)
    *(COMMON)
    . = ALIGN(8);
    _bss_end = .;
  }

  _end = .;
  PROVIDE(end = .);
  PROVIDE(__heap_start = _end);

  /DISCARD/ : {
    *(.comment)
    *(.note.*)
    *(.eh_frame)
    *(.riscv.attributes)
  }
}
