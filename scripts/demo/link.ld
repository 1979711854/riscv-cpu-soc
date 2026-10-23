/* ============================================================================
 * 演示程序链接脚本
 * ----------------------------------------------------------------------------
 * 布局与 scripts/coremark_port/link.ld 一致，好处是同一份存储器镜像规则：
 *   0x0000 起   .text（指令）
 *   0x1000 起   .rodata / .data / .bss（数据）
 *   栈顶 0xF000 向下生长
 * 注意 RAM 在 0xFFF0~0xFFFF 被兼容区 MMIO 挖掉，所以栈顶不要超过 0xFFF0。
 * ==========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x0;
  .text.init : { *(.text.init) *(.text.startup) }
  . = ALIGN(4);
  .text : { *(.text) *(.text.*) }

  . = ALIGN(0x1000);
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data   : { *(.data .data.* .sdata .sdata.*) }
  .bss    : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
  _end = .;
  _bss_start = ADDR(.bss);

  _stack_top = 0xF000;
}
