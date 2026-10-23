/* ============================================================================
 * 视频彩条固件 —— HDMI 首次上板点亮 + 显存读回自检
 * ----------------------------------------------------------------------------
 * 干什么：
 *   1) 填调色板：索引 0..7 = 8 条标准彩条色
 *   2) 填 8 个图块（tile 0..7），每块 16×16 像素全是同一个颜色索引 = 图块号
 *   3) 填整张图块表：世界 256 列，列 c → 图块 (c/5)%8
 *      ⇒ 每 5 列 = 5×16px = 80px 一条竖条，屏上 640px 正好 8 条
 *   4) scroll_x / scroll_y 归零
 *   5) 把刚写进去的显存【读回来】经串口打印 —— 这一步是黑屏时的分诊器：
 *        自检 OK   → CPU→mem_bus→显存 这一段是对的，黑屏就该去查 PPU→TMDS
 *        自检 FAIL → 问题在 CPU 侧写/读显存，与 TMDS 无关
 *
 * 期望画面：8 条等宽竖条铺满整屏，从左到右 白 黄 青 绿 品 红 蓝 黑。
 *
 * 画面是【静止】的。本版故意不做滚动动画：首次点亮要的是可判定的静止图案，
 * 动起来会把"跨时钟域/同步真有问题"和"程序故意在动"混在一起，反而难判。
 *
 * 以后拿它当滚动演示的底图也没问题：12 位世界宽 4096px = 256 列，图块表
 * 整张填满，滚到哪都是彩条；只有世界首尾相接处会有一条不齐的缝（预期行为，
 * 因为 8 条×80px = 640px 不整除 4096px）。
 *
 * 显存映射见 rtl/bus/addr_map.vh 的视频区小节，软件侧定义在 demo/addr_map.h。
 * 布局：tile T 的第 py 行第 px 列 = VIDEO_PAT + T*256 + py*16 + px
 *       第 r 行第 c 块             = VIDEO_NT  + r*256 + c
 * ==========================================================================*/
#include "addr_map.h"

#define REG32(a) (*(volatile unsigned int   *)(a))
#define REG8(a)  (*(volatile unsigned char  *)(a))

/* 显存尺寸（与 video_core.v 的 vram_b32 例化参数一致）：
 *   nametable 8KB = 32 行 × 256 列；pattern 64KB = 256 块 × 256 字节 */
#define NT_ROWS   32u
#define NT_COLS   256u
#define PAT_TILES 8u          /* 彩条只用到前 8 块 */

/* 8 条竖条的颜色（24bit RGB，高 8 位忽略） */
static const unsigned bar_rgb[8] = {
    0xFFFFFFu,   /* 0 白 */
    0xFFFF00u,   /* 1 黄 */
    0x00FFFFu,   /* 2 青 */
    0x00FF00u,   /* 3 绿 */
    0xFF00FFu,   /* 4 品红 */
    0xFF0000u,   /* 5 红 */
    0x0000FFu,   /* 6 蓝 */
    0x000000u    /* 7 黑 */
};

/* ------------------------------------------------------------------ */
/* 串口输出                                                            */
/* ------------------------------------------------------------------ */
static void uart_putc(char c)
{
    REG8(UART_TX) = (unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex8(unsigned v)
{
    unsigned hi = (v >> 4) & 0xFu;
    unsigned lo = v & 0xFu;
    uart_putc(hi < 10u ? (char)('0' + hi) : (char)('A' + hi - 10u));
    uart_putc(lo < 10u ? (char)('0' + lo) : (char)('A' + lo - 10u));
}

static void uart_puthex32(unsigned v)
{
    int i;
    for (i = 28; i >= 0; i -= 4) {
        unsigned d = (v >> i) & 0xFu;
        uart_putc(d < 10u ? (char)('0' + d) : (char)('A' + d - 10u));
    }
}

/* ------------------------------------------------------------------ */
/* 自检：读回一项就打印，并把不符的计数（每行都打实际值，FAIL 时能直接看差在哪）*/
/* ------------------------------------------------------------------ */
static unsigned bad = 0;

static void chk32(const char *name, unsigned got, unsigned want)
{
    uart_puts(name);
    uart_puts("=");
    uart_puthex32(got);
    if (got != want) {
        uart_puts(" want=");
        uart_puthex32(want);
        uart_puts(" FAIL");
        bad++;
    }
    uart_puts("\r\n");
}

static void chk8(const char *name, unsigned got, unsigned want)
{
    uart_puts(name);
    uart_puts("=");
    uart_puthex8(got);
    if (got != want) {
        uart_puts(" want=");
        uart_puthex8(want);
        uart_puts(" FAIL");
        bad++;
    }
    uart_puts("\r\n");
}

/* ------------------------------------------------------------------ */
int main(void)
{
    unsigned i, t, k, r, c;

    /* 1) 调色板：索引 i → 第 i 条竖条的颜色 */
    for (i = 0; i < 8u; i++)
        REG32(VIDEO_PAL + i * 4u) = bar_rgb[i];

    /* 2) 图块：tile t 的 256 个像素全部 = t（t 即调色板索引） */
    for (t = 0; t < PAT_TILES; t++)
        for (k = 0; k < 256u; k++)
            REG8(VIDEO_PAT + t * 256u + k) = (unsigned char)t;

    /* 3) 图块表：整张填满。列 c 用图块 (c/5)%8 —— 每 5 列一块，即 80px 一条 */
    for (r = 0; r < NT_ROWS; r++)
        for (c = 0; c < NT_COLS; c++)
            REG8(VIDEO_NT + r * 256u + c) = (unsigned char)((c / 5u) % 8u);

    /* 4) 世界坐标归零 */
    REG32(VIDEO_SCROLL_X) = 0;
    REG32(VIDEO_SCROLL_Y) = 0;

    /* 5) 读回自检（每项都打实际值） */
    uart_puts("VIDEO colorbar ready\r\n");

    chk32("PAL[1]", REG32(VIDEO_PAL + 1u * 4u), 0x00FFFF00u);   /* 黄 */
    chk32("PAL[5]", REG32(VIDEO_PAL + 5u * 4u), 0x00FF0000u);   /* 红 */
    chk32("PAL[7]", REG32(VIDEO_PAL + 7u * 4u), 0x00000000u);   /* 黑 */

    /* 图块表：c=0 → 0，c=5 → 1，c=35 → 7，c=39 → 7，末行 c=200 → 0 */
    chk8("NT[0][0]",   REG8(VIDEO_NT + 0u * 256u + 0u),   0u);
    chk8("NT[0][5]",   REG8(VIDEO_NT + 0u * 256u + 5u),   1u);
    chk8("NT[0][35]",  REG8(VIDEO_NT + 0u * 256u + 35u),  7u);
    chk8("NT[0][39]",  REG8(VIDEO_NT + 0u * 256u + 39u),  7u);
    chk8("NT[31][200]", REG8(VIDEO_NT + 31u * 256u + 200u), 0u);

    /* 图块像素：tile 7 首字节 = 7，tile 3 末字节 = 3 */
    chk8("PAT[7][0]",   REG8(VIDEO_PAT + 7u * 256u + 0u),    7u);
    chk8("PAT[3][255]", REG8(VIDEO_PAT + 3u * 256u + 255u),  3u);

    if (bad == 0u)
        uart_puts("SELFCHECK OK\r\n");
    else {
        uart_puts("SELFCHECK FAIL n=");
        uart_puthex8(bad);
        uart_puts("\r\n");
    }

    /* 程序到此为止：画面已经填好，停下即可。
     * 不写 0xFFF8 拉 done —— 那是 CoreMark 的结束标志语义。 */
    for (;;)
        ;
}
