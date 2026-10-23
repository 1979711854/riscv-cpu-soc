/* ============================================================================
 * preview_gomoku.c —— 五子棋主机预览（x86，不需要板子/iverilog/RISC-V 工具链）
 * ----------------------------------------------------------------------------
 * 作用：把**真实的** main.c / render.c / game.c 链进来，用一个假的
 *      vid_bulk_write() 接住显存写入，然后：
 *        1) 打印 40x30 的 tile 网格（排版/行距/对齐/缺行，一眼能看）；
 *        2) 可选输出 640x480 的 24 位 BMP（字体/颜色/整体观感）。
 *
 * 用法（一般通过 scripts\gomoku\preview.ps1 调用）：
 *      preview_gomoku.exe --scene title
 *      preview_gomoku.exe --scene game  --txt out.txt --bmp out.bmp
 *      preview_gomoku.exe --scene all   --bmp doc\board\preview
 *
 * scene: 0=title 1=submenu 2=game 3=over
 *
 * [!] 本文件只负责“假硬件 + 取像”。真正的场景绘制在 _main_preview.c 的
 *     preview_render_scene() 里（由 _mk_preview.py 从 main.c 自动生成），
 *     所以预览和固件用的是同一份布局代码，不会漂移。
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "render.h"
#include "font.h"

#define TILE_W      16
#define TILE_BYTES  (TILE_W * TILE_W)
#define SCREEN_W    (SCREEN_COLS * TILE_W)   /* 640 */
#define SCREEN_H    (SCREEN_ROWS * TILE_W)   /* 480 */

static uint8_t g_nt[32 * 256];
static uint8_t g_pat[256 * TILE_BYTES];
static uint8_t g_pal[256 * 4];

/* _main_preview.c 提供（从 main.c 生成） */
void preview_render_scene(int scene);

/* ---- 假显存 -------------------------------------------------------------- */
void vid_bulk_write(uint8_t region, uint16_t offset, const uint8_t *data, uint16_t len)
{
    uint16_t i;
    for (i = 0; i < len; i++) {
        if (region == VID_REGION_NT) {
            unsigned p = (unsigned)offset + i;
            if (p < sizeof(g_nt)) g_nt[p] = data[i];
        } else if (region == VID_REGION_PAT) {
            unsigned p = (unsigned)offset + i;
            if (p < sizeof(g_pat)) g_pat[p] = data[i];
        } else {
            unsigned p = (unsigned)offset + i;
            if (p < sizeof(g_pal)) g_pal[p] = data[i];
        }
    }
}

void video_set_scroll(int x, int y) { (void)x; (void)y; }
int  video_wait_vblank(void)        { return 0; }

/* ---- 假按键 / 时间 / UART ------------------------------------------------- */
uint8_t  hw_key_raw(void)              { return 0xFF; }      /* 无按键 */
uint32_t hw_mtime(void)                { return 0; }
void     hw_uart_putc(char c)          { (void)c; }
void     hw_uart_puts(const char *s)   { (void)s; }
uint32_t hw_ticks_per_ms(void)         { return 76505u; }
uint32_t hw_ticks_to_ms(uint32_t t)    { return t / 76505u; }

/* ---- 取像 ---------------------------------------------------------------- */
static uint8_t ppu_pixel(int px, int py)
{
    int trow = py / TILE_W;
    int tcol = px / TILE_W;
    uint8_t tile;
    if (trow < 0 || trow >= SCREEN_ROWS || tcol < 0 || tcol >= SCREEN_COLS) return 0;
    tile = g_nt[trow * 256 + tcol];
    return g_pat[(unsigned)tile * TILE_BYTES + (py % TILE_W) * TILE_W + (px % TILE_W)];
}

static void dump_ascii(FILE *f)
{
    int r, c;
    fprintf(f, "+----------------------------------------+\n");
    for (r = 0; r < SCREEN_ROWS; r++) {
        fprintf(f, "%2d |", r);
        for (c = 0; c < SCREEN_COLS; c++) {
            int t = g_nt[r * 256 + c];
            char ch;
            if (t >= FONT_TILE_BASE && t < FONT_TILE_BASE + FONT_N_GLYPHS) {
                ch = FONT_CHARS[t - FONT_TILE_BASE];
                if (ch == ' ') ch = '.';
            } else if (t >= FONT8_TILE_BASE && t < FONT8_TILE_BASE + FONT8_N_GLYPHS) {
                ch = FONT8_CHARS[t - FONT8_TILE_BASE];
                if (ch == ' ') ch = '.';
            } else if (t >= FONT_CJK_TILE_BASE && t < FONT_CJK_TILE_BASE + FONT_CJK_N) {
                ch = 'C';                 /* 中文 3 字 */
            } else if (t >= RENDER_TILE_WINS_BASE && t <= RENDER_TILE_WINS_BASE + 3) {
                ch = 'G';                 /* 绿色 WINS（弹窗） */
            } else if (t >= 135 && t <= 140) {
                ch = '%';                 /* 绿色 16x16（THINKING） */
            } else if (t >= 141 && t <= 145) {
                ch = '$';                 /* 金色 16x16（GOMOKU 标题） */
            } else if ((t >= 129 && t <= 130) || (t >= 146 && t <= 149) ||
                       (t >= 178 && t <= 179)) {
                ch = 'm';                 /* 标题中灰 8x8（子菜单大标题） */
            } else if ((t >= 73 && t <= 86) || t == 127 || t == 128 || t == 251) {
                ch = 'g';                 /* 暗金 8x8（POWERED 行） */
            } else if (t == RENDER_TILE_FAINT_RULE) {
                ch = '_';
            } else if (t == RENDER_TILE_DESC_ARROW) {
                ch = '>';
            } else if (t >= RENDER_TILE_LOGO_BASE && t < RENDER_TILE_LOGO_BASE + 24) {
                ch = '#';
            } else if (t == RENDER_TILE_RULE) {
                ch = '=';
            } else if (t == RENDER_TILE_ARROW) {
                ch = '>';
            } else if (t == RENDER_TILE_BG_BAND) {
                ch = '-';
            } else if (t >= RENDER_TILE_BOARD2_BASE && t <= 255) {
                ch = 'o';                 /* 2x2 对局棋盘象限/星位/最后一手 */
            } else if (t == RENDER_TILE_FRAME_H || t == RENDER_TILE_FRAME_V ||
                       t == RENDER_TILE_ICON_BLACK || t == RENDER_TILE_ICON_WHITE) {
                ch = '*';
            } else if (t < 36) {
                ch = 'o';
            } else {
                ch = '?';
            }
            fputc(ch, f);
        }
        fprintf(f, "|\n");
    }
    fprintf(f, "+----------------------------------------+\n");
}

/* ---- 24 位 BMP（640x480，bottom-up，行宽 1920 正好 4 对齐）---------------- */
static void put16(FILE *f, unsigned v) { fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f); }
static void put32(FILE *f, unsigned v)
{
    fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f);
    fputc((v >> 16) & 0xFF, f); fputc((v >> 24) & 0xFF, f);
}

static int write_bmp(const char *path)
{
    FILE *f = fopen(path, "wb");
    unsigned row = SCREEN_W * 3;
    unsigned img = row * SCREEN_H;
    int x, y;
    if (!f) { perror(path); return -1; }

    /* BITMAPFILEHEADER */
    fputc('B', f); fputc('M', f);
    put32(f, 54 + img);
    put16(f, 0); put16(f, 0);
    put32(f, 54);
    /* BITMAPINFOHEADER */
    put32(f, 40);
    put32(f, SCREEN_W);
    put32(f, SCREEN_H);
    put16(f, 1);
    put16(f, 24);
    put32(f, 0);
    put32(f, img);
    put32(f, 2835); put32(f, 2835);
    put32(f, 0); put32(f, 0);

    /* BMP 是 bottom-up：先写屏幕最底行 */
    for (y = SCREEN_H - 1; y >= 0; y--) {
        for (x = 0; x < SCREEN_W; x++) {
            uint8_t idx = ppu_pixel(x, y);
            fputc(g_pal[(unsigned)idx * 4 + 0], f);   /* B */
            fputc(g_pal[(unsigned)idx * 4 + 1], f);   /* G */
            fputc(g_pal[(unsigned)idx * 4 + 2], f);   /* R */
        }
    }
    fclose(f);
    return 0;
}

static int scene_from_name(const char *s)
{
    if (!strcmp(s, "title"))   return 0;
    if (!strcmp(s, "submenu")) return 1;
    if (!strcmp(s, "game"))    return 2;
    if (!strcmp(s, "over"))    return 3;
    return atoi(s);
}

int main(int argc, char **argv)
{
    int scene = 0;
    const char *txt = NULL;
    const char *bmp = NULL;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--scene") && i + 1 < argc) {
            scene = scene_from_name(argv[++i]);
        } else if (!strcmp(argv[i], "--txt") && i + 1 < argc) {
            txt = argv[++i];
        } else if (!strcmp(argv[i], "--bmp") && i + 1 < argc) {
            bmp = argv[++i];
        } else {
            fprintf(stderr, "usage: %s --scene title|submenu|game|over [--txt out.txt] [--bmp out.bmp]\n", argv[0]);
            return 2;
        }
    }

    preview_render_scene(scene);

    if (txt) {
        FILE *f = fopen(txt, "w");
        if (!f) { perror(txt); return 1; }
        dump_ascii(f);
        fclose(f);
    }
    dump_ascii(stdout);

    if (bmp) {
        if (write_bmp(bmp) != 0) return 1;
        fprintf(stderr, "[preview] BMP -> %s\n", bmp);
    }
    return 0;
}
