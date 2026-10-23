/* ============================================================================
 * preview_coremark.c —— CoreMark 主机预览（x86，真实代码路径，无需板子/工具链）
 * ----------------------------------------------------------------------------
 * 与 preview_gomoku.c 同一思路：把**真实的** core_portme.c / ee_printf.c /
 * video_text.c / CoreMark 源码在 x86 上跑一遍（-DVIDEO_TEXT_HOST 把 MMIO 直写
 * 重定向到本文件的假内存），然后从假显存取像，输出两张图：
 *   1) <prefix>_report.{txt,bmp} —— 滚动报告（结果页清屏前那一瞬 = 跑分过程中
 *      屏幕的最后状态：banner + CoreMark 报告块，长行折行、满 40 列折行全真）；
 *   2) <prefix>_result.{txt,bmp} —— 结果页（draw_result_page 固定行版式 =
 *      跑完后的最终画面）。
 *
 * [!] 数字是合成的：HOST 模式下 mtime 按"ITER × 217,088 拍"（板级每迭代拍数）
 *     合成，四个 CRC 来自 x86 真实计算。版式/字模/颜色/折行/滚屏全真，
 *     数字仅供排版预览，不作为跑分证据。
 *
 * 用法（经 scripts\preview_coremark.ps1 调用；core_main.c 的 main 已被
 * -Dmain=coremark_main 改名）：
 *      preview_coremark.exe --out d:\...\doc\board\preview_cm
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "video_text.h"        /* VIDEO_TEXT_COLS/ROWS (-I scripts/coremark_port) */
#include "host_mmio.h"
#include "font_coremark.h"     /* FONT_* (-I scripts/gomoku) */

/* ---- 假内存（与 addr_map.vh 分区一致，见 host_mmio.h）-------------------- */
#define VIDEO_NT_OFF   0x10000u        /* 0x80010000 */
#define VIDEO_PAT_OFF  0x20000u        /* 0x80020000 */
#define VIDEO_PAL_OFF  0x30000u        /* 0x80030000 */

static unsigned char compat[0x100];    /* 0xFF00..0xFFFF（邮箱/mtime/UART） */
static unsigned char mm[0x31000];      /* 0x80000000..0x80030FFF */

unsigned char *host_mmio_ptr(uintptr_t addr)
{
    uintptr_t a = addr;
    if (a >= 0xFF00u && a <= 0xFFFFu)
        return &compat[a - 0xFF00u];
    if (a >= 0x80000000u && a < 0x80000000u + sizeof(mm))
        return &mm[a - 0x80000000u];
    fprintf(stderr, "[host] unmapped MMIO access: 0x%08x\n", (unsigned)a);
    exit(3);
}

/* ---- 清屏前快照（video_text_clear 每次清屏前回调）------------------------
 * 第 1 次 = video_text_init 的开机清屏（空白，无信息）；
 * 第 2 次 = draw_result_page 抹掉滚动报告之前 —— 即"跑分过程中"的画面。 */
static unsigned char snap_nt[VIDEO_TEXT_ROWS * 256];
static int           snap_ready = 0;

void host_video_snapshot(void)
{
    static int nth = 0;
    nth++;
    if (nth >= 2) {
        memcpy(snap_nt, &mm[VIDEO_NT_OFF], sizeof(snap_nt));
        snap_ready = 1;
    }
}

int coremark_main(void);   /* CoreMark 入口（core_main.c 被 -Dmain=coremark_main 改名） */

/* ---- 取像（照搬 preview_gomoku.c 的 PPU 逐像素取法）---------------------- */
static unsigned char *pat(void) { return &mm[VIDEO_PAT_OFF]; }
static unsigned char *pal(void) { return &mm[VIDEO_PAL_OFF]; }

static uint8_t ppu_pixel(const unsigned char *nt, int px, int py)
{
    int trow = py / 16, tcol = px / 16;
    unsigned tile;
    if (trow < 0 || trow >= VIDEO_TEXT_ROWS || tcol < 0 || tcol >= VIDEO_TEXT_COLS)
        return 0;
    tile = nt[trow * 256 + tcol];
    return pat()[tile * 256u + (unsigned)(py % 16) * 16u + (unsigned)(px % 16)];
}

static void dump_ascii(const unsigned char *nt, FILE *f)
{
    int r, c;
    fprintf(f, "+----------------------------------------+\n");
    for (r = 0; r < VIDEO_TEXT_ROWS; r++) {
        fprintf(f, "%2d |", r);
        for (c = 0; c < VIDEO_TEXT_COLS; c++) {
            unsigned t = nt[r * 256 + c];
            int ch = '?';
            if (t >= FONT_TILE_BASE && t < FONT_TILE_BASE + FONT_N_GLYPHS) {
                ch = (int)(t - FONT_TILE_BASE + FONT_BASE);
                if (ch == ' ') ch = '.';
            }
            fputc(ch, f);
        }
        fprintf(f, "|\n");
    }
    fprintf(f, "+----------------------------------------+\n");
}

static void put16(FILE *f, unsigned v) { fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f); }
static void put32(FILE *f, unsigned v)
{
    fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f);
    fputc((v >> 16) & 0xFF, f); fputc((v >> 24) & 0xFF, f);
}

static void write_bmp(const unsigned char *nt, const char *path)
{
    FILE *f = fopen(path, "wb");
    unsigned row = 640u * 3u, img = row * 480u;
    int x, y;
    if (!f) { perror(path); exit(1); }

    fputc('B', f); fputc('M', f);
    put32(f, 54 + img); put16(f, 0); put16(f, 0); put32(f, 54);
    put32(f, 40); put32(f, 640); put32(f, 480); put16(f, 1); put16(f, 24);
    put32(f, 0); put32(f, img); put32(f, 2835); put32(f, 2835); put32(f, 0); put32(f, 0);

    for (y = 479; y >= 0; y--) {              /* BMP bottom-up */
        for (x = 0; x < 640; x++) {
            uint8_t idx = ppu_pixel(nt, x, y);
            fputc(pal()[(unsigned)idx * 4u + 0], f);   /* B */
            fputc(pal()[(unsigned)idx * 4u + 1], f);   /* G */
            fputc(pal()[(unsigned)idx * 4u + 2], f);   /* R */
        }
    }
    fclose(f);
}

static void emit_txt(const unsigned char *nt, const char *path)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    dump_ascii(nt, f);
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *prefix = NULL;
    char path[1024];
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc)
            prefix = argv[++i];
        else {
            fprintf(stderr, "usage: %s --out <prefix>\n", argv[0]);
            return 2;
        }
    }

    coremark_main();   /* banner + 跑分 + 报告 + 结果页，全部在这里发生 */

    if (prefix) {
        if (snap_ready) {
            sprintf(path, "%s_report.txt", prefix);
            emit_txt(snap_nt, path);
            sprintf(path, "%s_report.bmp", prefix);
            write_bmp(snap_nt, path);
            fprintf(stderr, "[preview] report -> %s_report.{txt,bmp}\n", prefix);
        } else {
            fprintf(stderr, "[preview] no report snapshot (video_text_clear called < 2 times)\n");
        }
        sprintf(path, "%s_result.txt", prefix);
        emit_txt(&mm[VIDEO_NT_OFF], path);
        sprintf(path, "%s_result.bmp", prefix);
        write_bmp(&mm[VIDEO_NT_OFF], path);
        fprintf(stderr, "[preview] result -> %s_result.{txt,bmp}\n", prefix);
    }

    if (snap_ready) {
        printf("=== screen: report (during run, before result page) ===\n");
        dump_ascii(snap_nt, stdout);
    }
    printf("=== screen: result page (final) ===\n");
    dump_ascii(&mm[VIDEO_NT_OFF], stdout);
    return 0;
}
