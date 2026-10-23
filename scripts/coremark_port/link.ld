/* ============================================================================
 * link.ld —— CoreMark 的链接脚本（128KB 统一存储器 + boot selector）
 * ----------------------------------------------------------------------------
 * [!] 2026-10-17 起 .text 起点从 0x0 改成 **0x1000**：0x0~0xFFF 留给
 *     scripts/boot/boot.S（复位入口 / 运行期选路）。要让 CoreMark 单独跑，
 *     必须让 boot.S 跳 0x1000；本文件不再被复位向量直接进入。
 *
 *   0x0000~0x0FFF  boot selector（≤4KB）
 *   0x1000~      本镜像（text 起，rodata 按 4KB 对齐）
 *   0x0F000      栈顶 _stack_top（不变）
 *   0xFFF0~0xFFFF 兼容区 MMIO（0xFFF4/0xFFF8/0xFFFC），**不能被镜像碰到**
 * ==========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x1000;
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
  _tohost    = 0xFFF8;
}
