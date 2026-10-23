/* ============================================================================
 * video_text.h —— CoreMark 用的极简 HDMI 文本控制台（任务书 2026-10-18 任务 B）
 * ----------------------------------------------------------------------------
 * 干什么：把 40x30 的 tile PPU 当成一台终端用 —— 40 列 × 30 行、8x8 字库放大 2x。
 *         `ee_printf` 的每个字符同时写 UART 和显存，串口里有什么，屏幕上就有什么。
 *
 * [!] 三条硬约束（见任务书 §3.2 / §3.6）：
 *   1. **计时区间里不许写显存**：`video_init()` 必须在 `start_time()` 之前调完；
 *      计时期间的字符由 `video_mirror_set(0)` 挡掉（见 core_portme.c 的 start_time）。
 *   2. **UART 必须保留**：串口日志是回归证据，镜像只是"多加一路"，不是替换。
 *   3. **调色板与五子棋共用一份**：调色板取 scripts/gomoku/palette.h；
 *      字库用 scripts/gomoku/font_coremark.h（完整 95 字含小写）。
 *      五子棋 UI 的 font.h 是子集，不能给控制台用（会掉小写字母）。
 *
 * 显存地址（rtl/bus/addr_map.vh）：
 *   nametable 0x8001_0000（字节寻址 r*256+c）
 *   pattern   0x8002_0000（tile*256 + py*16 + px）
 *   palette   0x8003_0000（每项 4 字节 B,G,R,0）
 *   scroll    0x8003_0400 / 0x8003_0404
 * ==========================================================================*/
#ifndef COREMARK_VIDEO_TEXT_H
#define COREMARK_VIDEO_TEXT_H

#define VIDEO_TEXT_COLS  40
#define VIDEO_TEXT_ROWS  30

/* 上电初始化：写调色板 + 把 95 个字模放大成 16x16 图块 + 清屏 + scroll=0。
 * **必须在 start_time() 之前调用**（它写 ~24KB 显存，约 0.3ms @76.5MHz）。 */
void video_text_init(void);

/* 输出一个字符（支持 '\n' 换行、'\r' 忽略、自动折行、到底部滚屏）。 */
void video_text_putc(char c);

void video_text_puts(const char *s);

/* 在 (row,col) 直接写一段字：不动光标、不换行、不滚动。结果页排版用。 */
void video_text_at(int row, int col, const char *s);

/* 无符号十进制（补空格到 width 位，右对齐）。 */
void video_text_putdec(unsigned v, int width);

/* 0x%04x 形式（小写十六进制，补 0 到 width 位）。 */
void video_text_puthex(unsigned v, int width);

/* 清屏（填空格图块）。 */
void video_text_clear(void);

/* 镜像开关：1 = 字符同时上屏，0 = 只走串口。
 * [!] start_time() 里关、stop_time() 里开 —— 这是"计时区间不碰显存"的保险丝：
 *     即使以后有人在计时区间里打日志，也不会把 Total ticks 弄脏。 */
void video_text_mirror(int on);
int  video_text_mirror_on(void);

/* 结果页专用：画一条分隔线（'-----'）。 */
void video_text_rule(void);

#endif /* COREMARK_VIDEO_TEXT_H */
