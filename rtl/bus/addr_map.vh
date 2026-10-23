// ============================================================================
// 地址映射 —— SoC 唯一真相（single source of truth）
// ----------------------------------------------------------------------------
// 三处必须保持一致，改这里要同步改另外两处：
//   1. 本文件（RTL）
//   2. scripts/demo/addr_map.h（演示程序，软件侧）
//   3. doc/spec.md 的地址映射表（文档）
// ============================================================================
`ifndef ADDR_MAP_VH
`define ADDR_MAP_VH

// ---------------------------------------------------------------------------
// RAM：32 位字，32768 word = 128KB，字索引用 addr[16:2]
//   注意低 64KB 的 0xFFF0~0xFFFF 被下面的兼容区挖走，RAM 实际可用到 0x1FFEF。
//   [!] 0x1FFF0 的 addr[15:4] 也是 0xFFF —— 兼容区判决必须加 `!addr[16]`，
//       否则 0x1FFF0 会被误判成 MMIO（mem_bus.v / core.v 的快通路判定同此）。
//   栈顶：CoreMark 0xF000，RT-Thread 0x1FFF0（见 scripts/rtthread/bsp/link.ld）。
// [!] RAM 扩容时必须一起改（漏一处就是静默错位）：
//     core.v（地址端口与切片）、cpu_top.v（三根 wire 宽度）、
//     mem_bus.v（ram_word 切片、ram_hit/legacy_hit）、unified_mem.v（阵列深度）、
//     cache_i.v / cache_d.v（word 宽度 + TAG_BITS）、sim/mem_model.vh 与各 tb、
//     本文件的 RAM_LAST_BYTE。
//     凡是承载"word 索引"的线宽度都要一起走（曾因 imem_addr2 少扩一位，
//     取指地址 >= 0x8000 时 lane B 从低 32KB 取错指令）；新增承载 word 索引
//     的线要补进这份清单。
// ---------------------------------------------------------------------------
`define RAM_BASE        32'h0000_0000
`define RAM_LAST_BYTE   32'h0001_FFEF

// ---------------------------------------------------------------------------
// 兼容区 0xFFF0~0xFFFF —— CoreMark 的链接脚本/移植层硬编码
//   core_portme.c: 读写 0xFFF4 当 get_time()
//   ee_printf.c  : 写 0xFFFC 输出字符、读 0xFFF4 等 UART 发完
//   start.S      : 写 0xFFF8 = 1 通知结束
// [!] 地址与 CoreMark 移植层里的字面量绑定，必须一起搬 —— 否则 CoreMark 读不到
//     计时器、串口不出字，而编译零报错。
// ---------------------------------------------------------------------------
`define LEGACY_HI_BYTE  8'hFF              // addr[15:8] == 0xFF 且 addr[7:4] == 0xF
`define LEGACY_LO_NIB   4'hF
`define LEGACY_CYCLE    32'h0000_FFF4      // R  周期计数器 [31:0]
`define LEGACY_DONE     32'h0000_FFF8      // W  写低字节 1 → done 拉高
`define LEGACY_UART_TX  32'h0000_FFFC      // W  UART 发一个字符

// ---------------------------------------------------------------------------
// 外设区 0x8000_0000 起，字内偏移 = addr[5:2]
//   与视频区的分界看 addr[17:16]：2'b00 = 外设区（0x8000_0000~0x8000_FFFF），
//   非 00 = 视频区（见下）。所以外设区实际是 64KB 而不是整个 0x8000_0000 以上，
//   但现有外设最大只用到 0x14，这个窗口绰绰有余。
// ---------------------------------------------------------------------------
`define PERIPH_MASK     32'h8000_0000      // addr[31] == 1 即落在高半区
`define PERIPH_GPIO     4'h0               // 0x00  W LED[7:0] / R {key[7:0], led[7:0]}
`define PERIPH_UART_TX  4'h2               // 0x08  W 发字符
`define PERIPH_UART_RX  4'h3               // 0x0C  R {valid, 23'b0, data[7:0]}，读清 valid
`define PERIPH_TIMER    4'h4               // 0x10  R 周期计数器 [31:0] = mtime
// ---------------------------------------------------------------------------
// CLINT（机器模式定时器）—— 最小集，只有 mtime 比较
//   mtime     = 0x8000_0010（与上面的 TIMER、以及兼容区 0xFFF4 是同一个计数器）
//   mtimecmp  = 0x8000_0014，可写；复位值全 1
//   mtime >= mtimecmp  →  MTIP 拉高（mip bit7），软件写新的 mtimecmp 后自动落下
//
// 注意：mtime/mtimecmp 都是 32 位，不是规范建议的 64 位。
// [!] 27MHz 下约 159 秒回绕，本项目最长运行远小于该量级且软件每次比较前先写
//     mtimecmp，够用；跑长任务需扩到 64 位（mtimeh/mtimecmph）。
// ---------------------------------------------------------------------------
`define PERIPH_MTIMECMP 4'h5               // 0x14  W/R 定时器比较值 [31:0]

// ---------------------------------------------------------------------------
// Cache 命中/缺失计数器（只读）：32 位 load 计数，命中率 = HITS / (HITS + MISSES)。
//   只在 DCACHE_EN=1 时累加；默认关时恒 0。
//   [!] 用 sw 读会读到整字；不要用 sb/lb 去读（不额外防）。
// ---------------------------------------------------------------------------
`define PERIPH_DCACHE_HITS 4'h6           // 0x18  R D-Cache 命中的 load 次数
`define PERIPH_DCACHE_MISS 4'h7           // 0x1C  R D-Cache 缺失的 load 次数
`define PERIPH_ICACHE_HITS 4'h8           // 0x20  R I-Cache 命中的取指次数
`define PERIPH_ICACHE_MISS 4'h9           // 0x24  R I-Cache 缺失的取指次数
`define PERIPH_AGU_PROBE 4'hA            // 0x28  R 假 AGU 结果（只在综合量时序时用）

// ---------------------------------------------------------------------------
// 视频区 0x8001_0000 起 —— tile PPU 的显存 + 控制寄存器
//
//   译码看 addr[17:16] != 2'b00（见 mem_bus.v）。区内四个子窗口：
//
//     0x8001_0000   8KB   nametable  2048 个 32 位字 = 8192 个 tile 号
//     0x8002_0000  64KB   pattern   16384 个字 = 65536 个像素索引
//     0x8003_0000   1KB   palette     256 个字（每字一个 24bit 颜色）
//     0x8003_0400   1KB   控制寄存器
//
//   显存 A 口是 32 位字 + 字节使能：sb/sh/sw 都只花 1 拍且语义正确
//   （8 位口会让 sw 静默只写 1 字节，见 vram_b32.v 文件头）。
//
//   nametable 按字节地址寻址，与 PPU 内部一致：
//     第 r 行第 c 块（r=0..31, c=0..255）的 tile 号在
//         VIDEO_NT + r*256 + c
//     于是 sb 写一个 tile、lb 读一个 tile，都只用一条指令。相邻列在同一个
//     32 位字里，但因为是字节使能写，不需要读-改-写。
//
//   pattern 同理：tile T 的第 py 行第 px 列像素在
//         VIDEO_PAT + T*256 + py*16 + px
//
//   palette：VIDEO_PAL + index*4，低 24 位是 RGB（高位忽略）。
//
//   控制寄存器只接受整字写 sw，sb/sh 静默忽略（理由同 mtimecmp）：
//     0x8003_0400  W/R  scroll_x[11:0]  背景横向滚动，world_x = x + scroll_x
//     0x8003_0404  W/R  scroll_y[11:0]  背景纵向滚动，world_y = y + scroll_y
//     0x8003_0408  R    {31'b0, vblank} vblank=1 表示正处在帧同步期间，
//                       改 scroll 前先等它，避免同一帧上下半屏来自不同位置。
//   写 scroll_x 是 12 位自然截断 = 环绕：世界宽 4096 像素、高 512 像素，
//   滚出右边缘会从左边绕回来，属预期行为。
// ---------------------------------------------------------------------------
`define VIDEO_BASE   32'h8001_0000
`define VIDEO_NT     32'h8001_0000
`define VIDEO_PAT    32'h8002_0000
`define VIDEO_PAL    32'h8003_0000
`define VIDEO_REG      32'h8003_0400
`define VIDEO_SCROLL_X 32'h8003_0400
`define VIDEO_SCROLL_Y 32'h8003_0404
`define VIDEO_STATUS   32'h8003_0408   // R: bit0 = vblank

`endif
