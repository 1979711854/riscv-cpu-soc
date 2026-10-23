/* ============================================================================
 * coremark_screen.c —— CoreMark 终端演示屏的实现（A1：真实成绩重放展示）
 * ----------------------------------------------------------------------------
 * 布局（40x30，2026-10-19 T7-R3 精修：绝对 X 定位，禁止空格凑长度）：
 *   0     分隔线（8x8 暗灰 '-'）
 *   1     COREMARK 1.0 BENCHMARK @4     16x16 暖白 | RT-THREAD @30  8x8
 *   2     [ RUNNING ] @4 → [ PASS ]     16x16 亮绿 | THREADS: 4 @29 8x8
 *   3     分隔线
 *   5~9   TARGET CPU / PIPELINE / CLOCK / COMPILER / MEMORY
 *         标签 @4、冒号 @18、数值 @21（全部 8x8 暗灰）
 *   10    分隔线
 *   12    ITERATIONS / TOTAL TICKS / TIME SEC：标签 @4、冒号 @18、数值 @21
 *   16    [ @2 + 29 格 + ] @32 + 100% @36    16x16 亮绿 + 8x8 百分比
 *   18    分隔线
 *   19    SYSTEM MONITOR // RT-THREAD @4      8x8 暗灰
 *   20    UI TICK   : nnn    标签 @4、冒号 @14、数值 @16（亮金 16x16）
 *   21    UPTIME    : nn SEC 同上
 *   22    HEAP FREE : n/mB   剩余/总量字节（rt_memory_info 实时值，不取整）
 *   23    分隔线
 *   24    COREMARK SCORE : 352.45           16x16 亮金（屏上最大字号）
 *   25    COREMARK/MHZ   : 4.6076           16x16 亮金
 *   26    CRC VALIDATION : OK               8x8，OK 亮绿
 *   27    HOLD SW6 TO RETURN TO MENU        8x8 暗灰
 *   28    RV32IMA | RT-THREAD | 76.5MHZ     8x8 暗灰
 *   29    分隔线
 *
 * [!] 监控区三行**全部是 RT-Thread 官方 API 的实时值**（tick/uptime/heap），
 *     没有写死的 99% 之类假数据。数值用现有 GOLD16 子集（16x16），不新增图块。
 * [!] 全部数字来自 0xFF00 邮箱快照（上次官方 SW6 跑分的真实结果）；
 *     主频/编译器等静态信息按当前固件口径现算/常量。
 * [!] 没有 64 位除法（-nostdlib 无 libgcc）：所有换算都拆成 32 位安全式
 *     （ms×iter ≤ 12,000×3,900 ≈ 4.7e7 < 2^32；cmMHz 用 score_x100×1e5/kHz）。
 * ==========================================================================*/
#include <stdint.h>
#include "render.h"
#include "font.h"
#include "hw_port.h"            /* hw_mtime / hw_ticks_per_ms */
#include "cm_mailbox.h"
#include "coremark_screen.h"

/* [!] 监控区在 RT-Thread 宿主下用官方 API 取真实值；裸机构建（gomoku 位流）
 *     也要编这个文件，所以 RT 头文件必须包在宏里。RT 构建的宏是
 *     **__RTTHREAD__**（见 rtthread/build.ps1 的 -D），不是 RT_USING_RTTHREAD。 */
#ifdef __RTTHREAD__
#include <rtthread.h>
#endif

/* [!] 主频【不写死也不 include board.h】：RT-Thread 构建里有两个 board.h
 *     （RT 的 bsp vs 五子棋的棋盘），include 会歧义。ticks/ms ≡ kHz，
 *     直接从 hw_port 现算 —— 仿真口径（100MHz）与板级口径（76.5MHz）自动都对。 */
#define CM_FREQ_KHZ()   (hw_ticks_per_ms())

/* ---- 版式行号（与文件头示意图一一对应）------------------------------------ */
#define CM_ROW_SEP0   0
#define CM_ROW_TITLE  1
#define CM_ROW_STATE  2
#define CM_ROW_SEP1   3
#define CM_ROW_INFO   5     /* 信息块 5..9 共 5 行 */
#define CM_ROW_SEP2   10
#define CM_ROW_ITER   12
#define CM_ROW_TICKS  13
#define CM_ROW_TIME   14
#define CM_ROW_BAR    16
#define CM_ROW_SEP3   18
#define CM_ROW_MON    19    /* 系统监控区 19..22 */
#define CM_ROW_TICK   20
#define CM_ROW_UPTIME 21
#define CM_ROW_HEAP   22
#define CM_ROW_SEP4   23
#define CM_ROW_SCORE  24
#define CM_ROW_MHZ    25
#define CM_ROW_CRC    26
#define CM_ROW_HINT   27
#define CM_ROW_FOOTER 28
#define CM_ROW_SEP5   29

/* 进度条：'[' 在 col2、29 格填充（col3..31）、']' 在 col32、百分比 col36..39 */
#define CM_BAR_CELLS  29
#define CM_BAR_COL0   3
#define CM_BLINK_MS   500u
#define CM_MON_MS     100u   /* 监控区刷新周期（毫秒） */

/* 绝对值定位：标签 / 冒号 / 数值的列（禁止字符串里打空格凑长度） */
#define CM_KV_LABEL_COL   4
#define CM_KV_COLON_COL   18
#define CM_KV_VALUE_COL   21
#define CM_MON_LABEL_COL  4
#define CM_MON_COLON_COL  14
#define CM_MON_VALUE_COL  16

/* ---- 状态（静态区，不占栈）---------------------------------------------- */
static uint32_t s_mb[CM_MBOX_N_WORDS];  /* 邮箱快照（begin 时读一次） */
static uint32_t s_iter;                 /* 该次跑分的 ITER（来自邮箱） */
static uint32_t s_total;                /* 该次跑分的 Total ticks */
static uint32_t s_t0;                   /* 重放起点（hw_mtime） */
static int      s_have;                 /* 邮箱 magic/数值合法 */
static int      s_done;                 /* 重放完成（[ PASS ] 已画） */
static int      s_last_sec;             /* 上次画动态行的秒数（-1 = 未画） */
static int      s_last_pct;             /* 上次画的百分比 */
static int      s_blink_on;             /* [ RUNNING ] 当前亮灭 */
static uint32_t s_last_mon;             /* 上次刷新监控区的 hw_mtime */
static char     s_freqstr[12];          /* "76.5MHZ"（由 BOARD_SYSTEM_CLOCK_HZ 现算） */

/* ---- 小工具（固件没有 libc；与 main.c 的同名逻辑等价，各自静态）---------- */
static char *cm_str(char *p, const char *s)
{
    while (*s) *p++ = *s++;
    return p;
}

static char *cm_dec(char *p, uint32_t v, int width)
{
    char tmp[12];
    int  n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (n < width) tmp[n++] = '0';
    while (n--) *p++ = tmp[n];
    return p;
}

/* 信息块：标签 @4、冒号 @18、数值 @21 —— 绝对定位，字符串里不打空格。 */
static void cm_kv8(int row, const char *label, const char *value)
{
    render_text8_span(row, CM_KV_LABEL_COL, label);
    render_text8_span(row, CM_KV_COLON_COL, ":");
    render_text8_span(row, CM_KV_VALUE_COL, value);
}

/* 动态数值行：只清/写 Col21 之后，标签和冒号保持不动。 */
static void cm_kv_value8(int row, const char *value)
{
    render_clear_span(row, CM_KV_VALUE_COL, SCREEN_COLS - CM_KV_VALUE_COL);
    render_text8_span(row, CM_KV_VALUE_COL, value);
}

/* ---- 监控区数据源：RT-Thread 宿主用官方 API，裸机用 hw_mtime 兜底 --------- */
static uint32_t cm_mon_tick(void)
{
#ifdef __RTTHREAD__
    return (uint32_t)rt_tick_get();          /* 1ms 系统滴答 */
#else
    return hw_mtime() / hw_ticks_per_ms();   /* 裸机：开机毫秒数 */
#endif
}

static uint32_t cm_mon_uptime(void)
{
#ifdef __RTTHREAD__
    return cm_mon_tick() / (uint32_t)RT_TICK_PER_SECOND;
#else
    return cm_mon_tick() / 1000u;
#endif
}

/* 堆余量：返回剩余字节，可选回填 total（字节）。
 * [!] 不再按 KB 取整 —— 本系统堆总量只有约 1.4 KB，"0.0K" 会被误读成假数据/分配失败；
 *     屏上写成 "剩余/总量B"，量纲和真实值都可核对。 */
static uint32_t cm_mon_heap_free(uint32_t *total_out)
{
#ifdef __RTTHREAD__
    rt_size_t total = 0, used = 0, max_used = 0;
    rt_memory_info(&total, &used, &max_used);
    if (total_out != 0) *total_out = (uint32_t)total;
    return (uint32_t)(total - used);
#else
    if (total_out != 0) *total_out = 0u;
    return 0u;                               /* 裸机没有 RT-Thread 堆 */
#endif
}

/* 终端变色字：按 set 逐字符写；空格/该子集没有的字跳过（保底色）。
 * [!] 查表统一走 render_term_tile()：生成表是 **ord(ch)-FONT_BASE** 索引，
 *     直接按 ASCII 原值下标会整体错位 32 格（'O' 读成 'o' 的槽位 ⇒ 0xFF）。 */
static void term_span(int row, int col, const char *s, int set)
{
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        uint8_t t = render_term_tile(set, s[i]);
        if (t != 0xFF) render_put(row, col + i, t);
    }
}

/* 监控区三行数值：全部来自 RT-Thread 官方 API（tick/uptime/heap）。
 * 数值用 GREEN8 子集（8x8 亮绿），不新增图块；只清/写数值列。 */
static void cm_update_monitor(void)
{
    char b[20];
    char *p;
    int   n;
    uint32_t heap_total = 0;
    uint32_t heap_free  = cm_mon_heap_free(&heap_total);

    p = cm_dec(b, cm_mon_tick(), 0);
    *p = '\0';
    render_clear_span(CM_ROW_TICK, CM_MON_VALUE_COL, 10);
    term_span(CM_ROW_TICK, CM_MON_VALUE_COL, b, RENDER_TERM_SET_GREEN8);

    p = cm_dec(b, cm_mon_uptime(), 0);
    p = cm_str(p, " SEC");
    *p = '\0';
    render_clear_span(CM_ROW_UPTIME, CM_MON_VALUE_COL, 10);
    term_span(CM_ROW_UPTIME, CM_MON_VALUE_COL, b, RENDER_TERM_SET_GREEN8);

    /* 剩余字节用亮绿 GREEN8 画；"/总量B" 里 '/' 和 'B' 不在 GREEN8 子集
     * （只有 0-9 . K S E C），用通用 8x8 暗灰字补，量纲一眼可读。 */
    p = cm_dec(b, heap_free, 0);
    n = (int)(p - b);
    *p = '\0';
    render_clear_span(CM_ROW_HEAP, CM_MON_VALUE_COL, 16);
    term_span(CM_ROW_HEAP, CM_MON_VALUE_COL, b, RENDER_TERM_SET_GREEN8);

    p = cm_str(b, "/");
    p = cm_dec(p, heap_total, 0);
    p = cm_str(p, "B");
    *p = '\0';
    render_text8_span(CM_ROW_HEAP, CM_MON_VALUE_COL + n, b);
}

/* 8x8 暗灰分隔线：40 个 '-' 铺满一行。 */
static void cm_sep(int row)
{
    char line[41];
    int  i;
    for (i = 0; i < 40; i++) line[i] = '-';
    line[40] = '\0';
    render_text8_span(row, 0, line);
}

/* ---- 静态版式（begin 时画一次；主频串用 begin 现算好的 s_freqstr）------- */
static void cm_draw_static(void)
{
    char  b[40];
    char *p;

    cm_sep(CM_ROW_SEP0);
    render_text_span(CM_ROW_TITLE, CM_KV_LABEL_COL, "COREMARK 1.0 BENCHMARK");
    render_text8_span(CM_ROW_TITLE, 30, "RT-THREAD");
    cm_sep(CM_ROW_SEP1);

    /* 状态行右侧：固定 4 个线程（main/render/ai/idle），仅展示 */
#ifdef __RTTHREAD__
    render_text8_span(CM_ROW_STATE, 29, "THREADS: 4");
#else
    render_text8_span(CM_ROW_STATE, 29, "THREADS: 1");
#endif

    /* 信息块：标签 @4 / 冒号 @18 / 数值 @21（绝对定位，不靠空格） */
    cm_kv8(CM_ROW_INFO + 0, "TARGET CPU", "RISC-V RV32IMA");
    cm_kv8(CM_ROW_INFO + 1, "PIPELINE",   "5-STAGE DUAL-ISSUE");
    cm_kv8(CM_ROW_INFO + 2, "CLOCK",      s_freqstr);
    /* [!] 编译器一行描述的是【被重放的那次官方跑分】的构建口径
     *     （core_portme.h COMPILER_FLAGS 的前缀），不是本演示固件的 -Os。 */
    cm_kv8(CM_ROW_INFO + 3, "COMPILER",   "GCC 15.2.0 -O3");
    cm_kv8(CM_ROW_INFO + 4, "MEMORY",     "STATIC SRAM");
    cm_sep(CM_ROW_SEP2);

    /* 动态行的标签/冒号只画一次；数值由 cm_draw_dyn 局部更新 */
    render_text8_span(CM_ROW_ITER,  CM_KV_LABEL_COL, "ITERATIONS");
    render_text8_span(CM_ROW_ITER,  CM_KV_COLON_COL, ":");
    render_text8_span(CM_ROW_TICKS, CM_KV_LABEL_COL, "TOTAL TICKS");
    render_text8_span(CM_ROW_TICKS, CM_KV_COLON_COL, ":");
    render_text8_span(CM_ROW_TIME,  CM_KV_LABEL_COL, "TIME SEC");
    render_text8_span(CM_ROW_TIME,  CM_KV_COLON_COL, ":");
    cm_sep(CM_ROW_SEP3);

    /* 系统监控区：三行真实数据（数值由 cm_update_monitor 局部刷新） */
    render_text8_span(CM_ROW_MON,    CM_MON_LABEL_COL, "SYSTEM MONITOR // RT-THREAD");
    render_text8_span(CM_ROW_TICK,   CM_MON_LABEL_COL, "UI TICK");
    render_text8_span(CM_ROW_TICK,   CM_MON_COLON_COL, ":");
    render_text8_span(CM_ROW_UPTIME, CM_MON_LABEL_COL, "UPTIME");
    render_text8_span(CM_ROW_UPTIME, CM_MON_COLON_COL, ":");
    render_text8_span(CM_ROW_HEAP,   CM_MON_LABEL_COL, "HEAP FREE");
    render_text8_span(CM_ROW_HEAP,   CM_MON_COLON_COL, ":");
    cm_sep(CM_ROW_SEP4);

    render_text8_span(CM_ROW_HINT, CM_KV_LABEL_COL, "HOLD SW6 TO RETURN TO MENU");
    p = cm_str(b, "RV32IMA | RT-THREAD | ");
    p = cm_str(p, s_freqstr);
    *p = '\0';
    render_text8_span(CM_ROW_FOOTER, CM_KV_LABEL_COL, b);
    cm_sep(CM_ROW_SEP5);
}

/* ---- 动态行（每秒跳动）：只改 Col21 之后的数值，标签/冒号不动 ---------- */
static void cm_draw_dyn(uint32_t elapsed, uint32_t iters)
{
    char  b[40];
    char *p;
    uint32_t ms = elapsed / hw_ticks_per_ms();

    p = cm_dec(b, iters, 0);
    p = cm_str(p, "/");
    p = cm_dec(p, s_iter, 0);
    *p = '\0';
    cm_kv_value8(CM_ROW_ITER, b);

    p = cm_dec(b, elapsed, 0);
    *p = '\0';
    cm_kv_value8(CM_ROW_TICKS, b);

    p = cm_dec(b, ms / 1000u, 0);
    p = cm_str(p, ".");
    p = cm_dec(p, (ms % 1000u) / 10u, 2);
    *p = '\0';
    cm_kv_value8(CM_ROW_TIME, b);
}

/* ---- 进度条 + 百分比 ---------------------------------------------------- */
static void cm_draw_bar(int filled, int pct)
{
    char b[8];
    char *p;
    int  col;

    /* 绝对定位：[ @2、29 格 @3..31、] @32、百分比 @36..39 */
    render_put(CM_ROW_BAR, 2, render_term_tile(RENDER_TERM_SET_GREEN16, '['));
    for (col = 0; col < CM_BAR_CELLS; col++)
        render_put(CM_ROW_BAR, CM_BAR_COL0 + col,
                   (col < filled) ? RENDER_TILE_TERM_FILL : RENDER_TILE_TERM_TRACK);
    render_put(CM_ROW_BAR, CM_BAR_COL0 + CM_BAR_CELLS,
               render_term_tile(RENDER_TERM_SET_GREEN16, ']'));

    /* 百分比：数字右对齐到 38、% 固定在 39（不补前导 0，49% 就是 "49%"） */
    render_clear_span(CM_ROW_BAR, 36, 4);
    p = cm_dec(b, (uint32_t)pct, 0);
    *p = '\0';
    {
        int len = (int)(p - b);
        int start = 39 - len;
        if (start < 36) start = 36;
        render_text8_span(CM_ROW_BAR, start, b);
    }
    render_put(CM_ROW_BAR, 39, RENDER_TILE_TERM_PCT);
}

/* ---- 状态行：[ RUNNING ] 闪烁 / [ PASS ] 常亮 --------------------------- */
static void cm_draw_state(int on)
{
    /* 状态文字统一 @4（绝对定位）；右侧 "THREADS: 4" 是静态信息，不参与闪烁 */
    if (s_done) {
        term_span(CM_ROW_STATE, 4, "[ PASS ]", RENDER_TERM_SET_GREEN16);
        /* "[ PASS ]" 到第 11 列（']'）为止；12 列起清掉 "[ RUNNING ]" 的残字 */
        render_clear_span(CM_ROW_STATE, 12, 4);
    } else if (on) {
        term_span(CM_ROW_STATE, 4, "[ RUNNING ]", RENDER_TERM_SET_GREEN16);
    } else {
        render_clear_span(CM_ROW_STATE, 4, 14);
    }
}

/* ---- 收尾：金色两行大分数 + CRC 判定 ------------------------------------ */
static void cm_finish(void)
{
    char  b[40];
    char *p;
    uint32_t score_x100 = s_mb[CM_MBOX_I_SCORE];
    uint32_t khz = CM_FREQ_KHZ();
    uint32_t mhz_x10000;

    s_done = 1;
    cm_draw_state(1);
    cm_draw_dyn(s_total, s_iter);
    cm_draw_bar(CM_BAR_CELLS, 100);

    /* Score：score_x100 -> "SSSS.cc"（两位小数，整数拼接，无浮点） */
    p = cm_str(b, "COREMARK SCORE : ");
    p = cm_dec(p, score_x100 / 100u, 0);
    p = cm_str(p, ".");
    p = cm_dec(p, score_x100 % 100u, 2);
    *p = '\0';
    term_span(CM_ROW_SCORE, CM_KV_LABEL_COL, b, RENDER_TERM_SET_GOLD16);

    /* CoreMark/MHz = score / freq_MHz，32 位安全式：
     *   x10000 = score_x100 * 1e5 / freq_kHz
     *   （score_x100=35250、kHz=76505 ⇒ 3.525e9 < 2^32，结果 46076 = 4.6076）。
     * [!] 有效范围 score_x100 ≤ 42949（score ≤ 429.49）—— 本平台 ~352，余量足；
     *     真要上更高分就得换 64 位除法（-nostdlib 无 libgcc，别随手加）。 */
    mhz_x10000 = (score_x100 * 100000u) / (khz ? khz : 1u);
    p = cm_str(b, "COREMARK/MHZ   : ");
    p = cm_dec(p, mhz_x10000 / 10000u, 0);
    p = cm_str(p, ".");
    p = cm_dec(p, mhz_x10000 % 10000u, 4);
    *p = '\0';
    term_span(CM_ROW_MHZ, CM_KV_LABEL_COL, b, RENDER_TERM_SET_GOLD16);

    /* CRC 判定：标签 @4、冒号 @19、数值 @21；OK 亮绿、BAD 暗灰 */
    render_text8_span(CM_ROW_CRC, CM_KV_LABEL_COL, "CRC VALIDATION : ");
    if (s_mb[CM_MBOX_I_FLAGS] & CM_MBOX_FLAG_CRC_OK) {
        /* 绿 O/K 只有两块，直接用常量（不引整张 95B 终端 8x8 表）。 */
        render_put(CM_ROW_CRC, 21, RENDER_TILE_TERM_OK_O);
        render_put(CM_ROW_CRC, 22, RENDER_TILE_TERM_OK_K);
        /* 清掉 begin 时 "WAIT" 留在后面的残字（否则显示成 "OKIT"）。 */
        render_clear_span(CM_ROW_CRC, 23, 2);
    } else {
        render_text8_span(CM_ROW_CRC, 21, "BAD");
        render_clear_span(CM_ROW_CRC, 24, 1);
    }
}

/* ---- 对外：进入演示屏 ---------------------------------------------------- */
void cm_screen_begin(void)
{
    volatile uint32_t *mb = (volatile uint32_t *)CM_MBOX_BASE;
    uint32_t khz = CM_FREQ_KHZ();
    char *p;
    int   i;

    render_term_begin();                       /* 调色板换黑 + 借图块合成 + 清屏 */

    for (i = 0; i < CM_MBOX_N_WORDS; i++) s_mb[i] = mb[i];
    s_iter  = s_mb[CM_MBOX_I_ITER];
    s_total = s_mb[CM_MBOX_I_TICKS];
    s_have  = (s_mb[CM_MBOX_I_MAGIC] == CM_MBOX_MAGIC) &&
              (s_iter > 0u) && (s_total > 1000u);

    /* 页脚主频字符串（由板级宏现算，不写死） */
    p = s_freqstr;
    p = cm_dec(p, khz / 1000u, 0);
    p = cm_str(p, ".");
    p = cm_dec(p, (khz % 1000u) / 100u, 1);
    p = cm_str(p, "MHZ");
    *p = '\0';

    s_done = 0;
    s_last_sec = -1;
    s_last_pct = -1;
    s_blink_on = 1;
    s_last_mon = hw_mtime();

    cm_draw_static();
    cm_update_monitor();                       /* 监控区先填一帧真实值 */

    if (s_have) {
        s_t0 = hw_mtime();                     /* 重放起点 */
        cm_draw_dyn(0, 0);
        cm_draw_bar(0, 0);
        cm_draw_state(1);
        render_text8_span(CM_ROW_CRC, CM_KV_LABEL_COL, "CRC VALIDATION : WAIT");
    } else {
        /* 没有可重放的成绩：说明这台板子上官方 SW6 跑分从没跑过。
         * 这一行比状态文字长，先清掉整行（含右侧 THREADS 徽标），避免叠字。 */
        render_clear_span(CM_ROW_STATE, CM_KV_LABEL_COL, SCREEN_COLS - CM_KV_LABEL_COL);
        render_text8_span(CM_ROW_STATE, CM_KV_LABEL_COL, "NO DATA - RUN SW6 PATH FIRST");
        render_clear_span(CM_ROW_ITER, 0, 40);
        render_clear_span(CM_ROW_TICKS, 0, 40);
        render_clear_span(CM_ROW_TIME, 0, 40);
        cm_draw_bar(0, 0);
        render_text8_span(CM_ROW_CRC, CM_KV_LABEL_COL, "CRC VALIDATION : N/A");
    }
}

/* ---- 对外：每帧推进 ------------------------------------------------------ */
void cm_screen_tick(uint32_t now)
{
    uint32_t tpm = hw_ticks_per_ms();
    int on = ((now / (CM_BLINK_MS * tpm)) & 1u) == 0;

    if (on != s_blink_on) {
        s_blink_on = on;
        cm_draw_state(on);
    }

    /* 监控区每 100ms 局部刷新一次；PASS 收尾后仍继续跳（证明系统还活着） */
    if ((uint32_t)(now - s_last_mon) >= CM_MON_MS * tpm) {
        s_last_mon = now;
        cm_update_monitor();
    }

    if (!s_have || s_done) return;

    {
        uint32_t elapsed = now - s_t0;
        uint32_t total_ms, ms, sec, pct, iters;

        if (elapsed >= s_total) {
            cm_finish();
            return;
        }

        total_ms = s_total / tpm;
        if (total_ms == 0u) total_ms = 1u;
        ms  = elapsed / tpm;
        sec = ms / 1000u;
        pct = ms * 100u / total_ms;
        iters = ms * s_iter / total_ms;

        if ((int)sec != s_last_sec) {
            s_last_sec = (int)sec;
            cm_draw_dyn(elapsed, iters);
        }
        if ((int)pct != s_last_pct) {
            s_last_pct = (int)pct;
            cm_draw_bar((int)(pct * CM_BAR_CELLS / 100u), (int)pct);
        }
    }
}
