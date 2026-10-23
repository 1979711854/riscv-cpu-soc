/* ============================================================================
 * addr_map.h —— 外设地址映射（软件侧）
 * ----------------------------------------------------------------------------
 * 必须与 RTL 侧 rtl/bus/addr_map.vh 保持一致。改一处要同步改另一处。
 * ==========================================================================*/
#ifndef ADDR_MAP_H
#define ADDR_MAP_H

/* 外设区 0x8000_0000 起 */
#define GPIO_BASE   0x80000000u   /* W: LED[7:0]      R: {key[7:0], led[7:0]}  */
#define UART_TX     0x80000008u   /* W: 发送一个字符（取低字节）                  */
#define UART_RX     0x8000000Cu   /* R: {valid[31], 23'b0, data[7:0]}，读会弹出一个 */
#define TIMER       0x80000010u   /* R: 32 位自由跑周期计数器（= mtime）           */
#define MTIMECMP    0x80000014u   /* W/R: 定时器比较值。mtime >= mtimecmp → MTIP 拉高
                                   *      写新的 mtimecmp 后 MTIP 自动落下。
                                   *      只接受整字写（sw），sb/sh 会被忽略。
                                   *      复位值为全 1，所以上电时不会误触发。
                                   *      要开中断还需 mie.MTIE(bit7) 与 mstatus.MIE(bit3)。*/
/* Cache 命中/缺失计数器（只读，高阶任务①的答辩证据）
 *   只在 mem_bus 的 DCACHE_EN=1 时累加；默认关时两者恒 0。
 *   命中率 = HITS / (HITS + MISSES)。用 *(volatile unsigned int*) 整字读。 */
#define DCACHE_HITS 0x80000018u   /* R: D-Cache 命中的 load 次数 */
#define DCACHE_MISS 0x8000001Cu   /* R: D-Cache 缺失的 load 次数 */
#define ICACHE_HITS 0x80000020u   /* R: I-Cache 命中的取指次数 */
#define ICACHE_MISS 0x80000024u   /* R: I-Cache 缺失的取指次数 */

/* ---------------------------------------------------------------------------
 * 视频区 —— tile PPU 背景层。分界线：addr[17:16]==0 是外设区，非 0 是视频区。
 *
 * 显存是【32 位字 + 字节使能】的 CPU 口，所以 sb/sh/sw 都只花 1 拍且语义正确。
 * nametable 和 pattern 都按【字节地址】寻址，跟 PPU 内部一致：
 *
 *   第 r 行第 c 块（r=0..31, c=0..255）的 tile 号：
 *       *(volatile unsigned char *)(VIDEO_NT + r*256 + c) = tile_id;
 *
 *   图块 tile_id 的第 py 行第 px 列像素（py,px = 0..15）的颜色索引：
 *       *(volatile unsigned char *)(VIDEO_PAT + tile_id*256 + py*16 + px) = idx;
 *
 *   调色板第 i 项（i=0..255）的 24bit 颜色（8:8:8）：
 *       *(volatile unsigned int  *)(VIDEO_PAL + i*4) = 0xRRGGBB;
 *
 * 上电后显存是 BRAM 的随机内容，出图前必须先把上面三样填满。
 * ------------------------------------------------------------------------- */
#define VIDEO_BASE  0x80010000u   /* 视频区基址                          */
#define VIDEO_NT    0x80010000u   /* 8KB  图块表（2048 字 = 8192 个 tile 号）*/
#define VIDEO_PAT   0x80020000u   /* 64KB 图块像素（256 块 × 16×16）        */
#define VIDEO_PAL   0x80030000u   /* 1KB  调色板（256 项 × 24bit）          */
#define VIDEO_REG   0x80030400u   /* 控制寄存器，只接受整字写 sw            */
#define VIDEO_SCROLL_X (VIDEO_REG + 0x0)  /* W/R 背景横向滚动 [11:0]        */
#define VIDEO_SCROLL_Y (VIDEO_REG + 0x4)  /* W/R 背景纵向滚动 [11:0]        */
#define VIDEO_STATUS   (VIDEO_REG + 0x8)  /* R   bit0 = vblank              */

/* vblank = 帧同步期间（宽 2 行 = 62.7us ≈ CPU 3100 拍）。等它再改 scroll，
 * 可以避免一帧扫到一半时换世界坐标造成上下半屏撕裂。
 *   while (!(*((volatile unsigned int *)VIDEO_STATUS) & 1u)) ;
 *   *((volatile unsigned int *)VIDEO_SCROLL_X) = new_scroll & 0xFFFu; */

/* 兼容区（CoreMark 移植层硬编码，本程序不用，列出仅供对照）
 *   0xFFF4 R 周期计数   0xFFF8 W done   0xFFFC W UART 发送 */
#define LEGACY_TIMER   0x0000FFF4u
#define LEGACY_DONE    0x0000FFF8u
#define LEGACY_UART_TX 0x0000FFFCu

/* 板上时钟：本地盘古板经 PLL 27MHz→76.5052MHz（见 rtl/top/cpu_top_board.v）。
 *   [!] 2026-10-17 128KB 版在 85 MHz 收不住，STATIC_RATIO0 13.5→15.0 降到 76.5 MHz。
 * [重点] 仿真与远程 FPGA 平台固定 27MHz —— 回远程平台要把这里改回 27000000u，
 *   同时 scripts/coremark_port/core_portme.c 的 EE_TICKS_PER_SEC、
 *   scripts/rtthread/bsp/board.h 的 BOARD_SYSTEM_CLOCK_HZ 一起改。 */
#define CPU_HZ      76505200u

#endif /* ADDR_MAP_H */
