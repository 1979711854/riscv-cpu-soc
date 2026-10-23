/* ============================================================================
 * video_text.c —— 极简 HDMI 文本控制台（40x30 tile 终端）
 * ----------------------------------------------------------------------------
 * 设计取舍（为什么不用五子棋的 render.c）：
 *   · render.c 依赖 9216 字节的 TILE_PATTERN（棋盘图块）和它自己的 40x30 版面假设，
 *     CoreMark 只要"能打字的终端"，把棋盘装进跑分镜像纯属浪费；
 *   · 这里只 include font.h（95x7 = 665 字节）和 palette.h（12x4 = 48 字节），
 *     图块在 video_text_init() 里现算 —— **新美术不进 .rodata**（任务书 §2.4）。
 *
 * [!] 不用 libc（没有 memset/memcpy）—— CoreMark 固件是 freestanding。
 * ==========================================================================*/
#include "video_text.h"

#include "../gomoku/font_coremark.h" /* 完整 95 字（含小写）；五子棋 UI 用 font.h 子集 */
#include "../gomoku/palette.h"    /* TILE_PALETTE / PAL_UI_BG ... */

#ifdef VIDEO_TEXT_HOST
/* x86 主机预览（sim/tools/preview_coremark.c，-DVIDEO_TEXT_HOST）：显存直写
 * 重定向到 harness 的假内存。固件构建【永不定义】VIDEO_TEXT_HOST —— 走原定义。 */
#include "host_mmio.h"
#define REG8(a)  HOST_R8(a)
#define REG32(a) HOST_R32(a)
#else
#define REG8(a)  (*(volatile unsigned char  *)(a))
#define REG32(a) (*(volatile unsigned int   *)(a))
#endif

#define VIDEO_NT       0x80010000u
#define VIDEO_PAT      0x80020000u
#define VIDEO_PAL      0x80030000u
#define VIDEO_SCROLL_X 0x80030400u
#define VIDEO_SCROLL_Y 0x80030404u

/* 屏幕文字的影子缓冲：滚屏要"把 29 行搬上去"，而显存不一定支持 CPU 读
 * （tile PPU 是写多读少的双口 RAM），所以自己留一份。
 * 30*40 = 1200 字节 .bss，对 128KB 的统一存储器可以忽略。 */
static unsigned char vbuf[VIDEO_TEXT_ROWS][VIDEO_TEXT_COLS];

static int  v_row, v_col;      /* 光标 */
static int  v_mirror = 1;      /* 1 = 上屏 */

/* ---- 显存三件套 ---------------------------------------------------------- */
static void write_nt(int row, int col, const unsigned char *src, int n)
{
    int i;
    unsigned int base = VIDEO_NT + (unsigned int)row * 256u + (unsigned int)col;
    for (i = 0; i < n; i++) REG8(base + (unsigned int)i) = src[i];
}

/* [!] `#pragma GCC unroll 1` 不是优化，是**必须**：
 *     CoreMark 的编译选项里有 `-funroll-all-loops -fpeel-loops`，而这里是
 *     256 次 / 16x16 次的定长循环 —— 不封住就会被整段展开，一个 put_tile 就
 *     膨胀成 2KB+ 代码、make_glyph_tile 更是好几 KB。
 *     实测：不封 → 整个固件 +10.3KB；封住 → +1.4KB（见提交说明）。 */
static void put_tile(unsigned int tile, const unsigned char *buf)
{
    unsigned int base = VIDEO_PAT + tile * 256u;
    int i;
#pragma GCC unroll 1
    for (i = 0; i < 256; i++) REG8(base + (unsigned int)i) = buf[i];
}

/* 把一个 5x7 字模放大 FONT_SCALE 倍写成 16x16 图块。与 scripts/gomoku/render.c
 * 的同一段算法逐像素一致（那边是五子棋 HUD 用，这里是 CoreMark 用）。 */
static void make_glyph_tile(unsigned char *buf, int glyph)
{
    int x, y;
    int ox = (16 - FONT_W * FONT_SCALE) / 2;
    int oy = (16 - FONT_H * FONT_SCALE) / 2;

#pragma GCC unroll 1
    for (y = 0; y < 16; y++) {
#pragma GCC unroll 1
        for (x = 0; x < 16; x++) {
            unsigned char v = (unsigned char)FONT_BG;
            if (x >= ox && y >= oy) {
                int fx = (x - ox) / FONT_SCALE;
                int fy = (y - oy) / FONT_SCALE;
                if (fx < FONT_W && fy < FONT_H &&
                    ((FONT_GLYPH[glyph][fy] >> (FONT_W - 1 - fx)) & 1u))
                    v = (unsigned char)FONT_FG;
            }
            buf[y * 16 + x] = v;
        }
    }
}

static void clear_row(int row)
{
    static unsigned char line[VIDEO_TEXT_COLS];
    int i;
#pragma GCC unroll 1
    for (i = 0; i < VIDEO_TEXT_COLS; i++) {
        line[i] = (unsigned char)FONT_TILE_BASE;
        vbuf[row][i] = ' ';
    }
    write_nt(row, 0, line, VIDEO_TEXT_COLS);
}

void video_text_clear(void)
{
    int r;
#ifdef VIDEO_TEXT_HOST
    /* 主机预览取像点：每次清屏前把当前 nametable 快照给 harness。
     * 第 2 次清屏 = draw_result_page 抹掉滚动报告之前 —— 即"跑分过程中"的画面。 */
    { extern void host_video_snapshot(void); host_video_snapshot(); }
#endif
    for (r = 0; r < VIDEO_TEXT_ROWS; r++) clear_row(r);
    v_row = 0;
    v_col = 0;
}

void video_text_init(void)
{
    unsigned char buf[256];
    int i;

    /* ---- 1) 调色板：和五子棋同一份（palette.h），24bit RGB 存成 B,G,R,0 ---- */
    for (i = 0; i < TILE_N_PALETTE; i++) {
        unsigned int rgb = TILE_PALETTE[i];
        unsigned int base = VIDEO_PAL + (unsigned int)i * 4u;
        REG8(base + 0u) = (unsigned char)(rgb & 0xFFu);          /* B */
        REG8(base + 1u) = (unsigned char)((rgb >> 8) & 0xFFu);   /* G */
        REG8(base + 2u) = (unsigned char)((rgb >> 16) & 0xFFu);  /* R */
        REG8(base + 3u) = 0;
    }

    /* ---- 2) 字库：95 个字模 -> 16x16 图块（24KB 显存，固件里只有 665 字节）---- */
    for (i = 0; i < FONT_N_GLYPHS; i++) {
        make_glyph_tile(buf, i);
        put_tile((unsigned int)(FONT_TILE_BASE + i), buf);
    }

    /* ---- 3) 清屏 + scroll 归零 ---- */
    video_text_clear();
    REG32(VIDEO_SCROLL_X) = 0u;
    REG32(VIDEO_SCROLL_Y) = 0u;
}

/* 滚屏：影子缓冲整体上移一行，然后整屏重写（1200 字节，只有满 30 行才发生）。 */
static void scroll_up(void)
{
    int r, c;
#pragma GCC unroll 1
    for (r = 1; r < VIDEO_TEXT_ROWS; r++)
#pragma GCC unroll 1
        for (c = 0; c < VIDEO_TEXT_COLS; c++)
            vbuf[r - 1][c] = vbuf[r][c];
    clear_row(VIDEO_TEXT_ROWS - 1);
    for (r = 0; r < VIDEO_TEXT_ROWS - 1; r++)
        write_nt(r, 0, vbuf[r], VIDEO_TEXT_COLS);
}

static void newline(void)
{
    v_col = 0;
    v_row++;
    if (v_row >= VIDEO_TEXT_ROWS) {
        v_row = VIDEO_TEXT_ROWS - 1;
        scroll_up();
    }
}

/* [!] noinline：它被 putdec/puthex/puts/rule 从十几处调用，
 *     -O3 会把这份"写显存 + 折行 + 滚屏"的逻辑展开十几遍（实测多 3KB+ 代码）。 */
__attribute__((noinline))
void video_text_putc(char c)
{
    unsigned char t;

    if (!v_mirror) return;
    if (c == '\r') return;                  /* 串口是 CRLF，屏上只要一次换行 */
    if (c == '\n') { newline(); return; }

    /* 不可打印字符（含 8 位中文/乱码）一律当空格，避免把图块号写飞。 */
    if ((unsigned char)c < 0x20 || (unsigned char)c > 0x7E) c = ' ';

    t = (unsigned char)(FONT_TILE_BASE + ((unsigned char)c - FONT_BASE));
    vbuf[v_row][v_col] = (unsigned char)c;
    REG8(VIDEO_NT + (unsigned int)v_row * 256u + (unsigned int)v_col) = t;

    v_col++;
    if (v_col >= VIDEO_TEXT_COLS) newline();
}

void video_text_puts(const char *s)
{
    while (*s) video_text_putc(*s++);
}

/* 在 (row,col) 直接写一段字，**不动光标、不换行、不滚动**。
 * 结果页用：每行固定落在指定行，行距才拉得开（滚动区仍然走 putc 的流式输出）。 */
void video_text_at(int row, int col, const char *s)
{
    if (row < 0 || row >= VIDEO_TEXT_ROWS) return;
    while (*s && col < VIDEO_TEXT_COLS) {
        unsigned char c = (unsigned char)*s++;
        if (c < 0x20 || c > 0x7E) c = ' ';
        if (col >= 0) {
            vbuf[row][col] = c;
            REG8(VIDEO_NT + (unsigned int)row * 256u + (unsigned int)col)
                = (unsigned char)(FONT_TILE_BASE + (c - FONT_BASE));
        }
        col++;
    }
}

void video_text_putdec(unsigned v, int width)
{
    char tmp[12];
    int  n = 0, pad;

    if (v == 0) tmp[n++] = '0';
    while (v && n < 11) { tmp[n++] = (char)('0' + (v % 10u)); v /= 10u; }

    for (pad = width - n; pad > 0; pad--) video_text_putc(' ');
    while (n--) video_text_putc(tmp[n]);
}

void video_text_puthex(unsigned v, int width)
{
    static const char hx[] = "0123456789abcdef";
    int i, sh;

    for (i = 0; i < width; i++) {
        sh = (width - 1 - i) * 4;
        video_text_putc(hx[(v >> sh) & 0xFu]);
    }
}

void video_text_rule(void)
{
    int i;
    /* [!] 一整行 = 40 字符，写满第 40 个时 putc 自己就折行了；
     *     这里**不要再补 '\n'** —— 否则会多出一个空行（40 字刚好顶到边界）。 */
    if (v_col != 0) video_text_putc('\n');
    for (i = 0; i < VIDEO_TEXT_COLS; i++) video_text_putc('-');
}

void video_text_mirror(int on)
{
    v_mirror = on;
}

int video_text_mirror_on(void)
{
    return v_mirror;
}
