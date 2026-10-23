/* ============================================================================
 * link.ld —— boot selector（128KB 单一位流的复位入口）
 * ----------------------------------------------------------------------------
 * 布局（与 scripts/coremark_port/link.ld、scripts/rtthread/bsp/link.ld 同一张图）：
 *
 *   0x0000 ┌──────────────┐
 *          │  boot.S      │  ← 复位入口 _start，必须 ≤ 4KB
 *   0x1000 ├──────────────┤
 *          │  CoreMark    │  key[2] 按住时跳这里
 *   0x10000├──────────────┤
 *          │  RT-Thread   │  默认跳这里（五子棋）
 *   0x1FFF0└──────────────┘  保留（兼容区别名陷阱，见 three_way_split §1.2）
 *
 * [!] 4KB 是硬的：0x1000 已被 CoreMark 的 .text.init 占用（它的入口固定在那儿），
 *     本脚本越界就是两块镜像重叠 —— merge_images.py 会报错拦下，但那时已经晚了。
 *     所以下面用 ASSERT 在链接期就挡住。
 * ==========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x0;

  .text.init : { *(.text.init) *(.text.startup) }
  . = ALIGN(4);
  .text : { *(.text .text.*) }

  _end = .;

  /DISCARD/ : {
    *(.comment)
    *(.note.*)
    *(.eh_frame)
    *(.riscv.attributes)
  }
}

/* boot 区上限 0x1000（CoreMark 的 .text.init 从这里开始） */
ASSERT(_end <= 0x1000, "boot selector 超过 4KB：0x0~0xFFF 装不下，检查 boot.S")
