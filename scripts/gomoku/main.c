/* ============================================================================
 * main.c —— 五子棋固件主程序（轨道 E1）
 * ----------------------------------------------------------------------------
 * 把 A/B/C/D 四个模块接起来，做成一个能烧进板子的固件：
 *
 *     上电 -> 填调色板与图块 -> 标题屏 -> 对局 <-> 胜负 -> 回标题
 *
 * 主循环**与帧同步**：每帧等一次 vblank，再采样按键、推状态机、全刷棋盘。
 * 这么做的两个理由：
 *   1) **防撕裂** —— 改显存要在 vblank 里做，否则可能上半屏新、下半屏旧
 *   2) **给主循环一个稳定节拍** —— 否则它会以几十万次/秒空转，白白耗电
 * 代价是按键采样周期从"微秒级"变成"帧级"（16.7ms），所以一次按压要
 * 2 帧（约 33ms）才认账。人按一下约 100ms，够用；长按 600ms 更是绰绰有余。
 *
 * [!] 全盘重画是 225 个字节/帧。60fps 下约 13.5KB/s，在 85MHz 上可以忽略 ——
 *     所以这里**不做增量更新**，每帧无脑全刷。省下的复杂度换可靠性，
 *     而且"闪一下但一定对"比"省几个周期但可能残留旧格"划算得多。
 *
 * 构建：scripts\gomoku\build.ps1        （出 mem.hex）
 * 上板：scripts\build_bitstream.ps1 gomoku
 * ==========================================================================*/
#include "board.h"
#include "ai.h"
#include "render.h"
#include "video_port.h"
#include "input.h"
#include "hw_port.h"
#include "game.h"
#include "cm_mailbox.h"     /* CoreMark -> 五子棋的跨复位邮箱（LAST COREMARK）*/
#include "coremark_screen.h" /* CoreMark 终端演示屏（SW6+SW7 复位彩蛋，T7）*/

#ifndef GOMOKU_AI_LEVEL
#define GOMOKU_AI_LEVEL AI_NORMAL      /* 上板默认：4 层，棋力够看 */
#endif

/* 光标闪烁半周期（毫秒）。300ms ⇒ 亮 300 / 灭 300，够醒目又不闪眼 */
#define BLINK_MS   300u

/* AI 对弈每手间隔的档位在标题屏菜单里选（step_ms：500/1000/2000ms，见
 * game.c 的 step_next/step_prev）；主循环每帧把 step_ms 换算成 demo_delay。 */

/* ---- 全局对象 ------------------------------------------------------------
 * 放静态区而不是栈上：栈顶只有 0xF000，而 game_t 里光 gomoku_t 就 232 字节，
 * 加上 AI 搜索的递归栈，放局部变量会把栈压穿。
 * [!] 它们会被 start.S 的 .bss 清零，所以显式初始化一次是必须的（见 main）。 */
static game_t  g_game;
static input_t g_input;

/* --------------------------------------------------------------------------- */
static void uart_putdec(unsigned v)
{
    char buf[12];
    int  n = 0;
    if (v == 0) { hw_uart_putc('0'); return; }
    while (v && n < 11) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) hw_uart_putc(buf[n]);
}

static void uart_puts(const char *s) { hw_uart_puts(s); }

/* ---------------------------------------------------------------------------
 * 上板自证：读【设计版本号】并打在串口第一行
 * ---------------------------------------------------------------------------
 * [!] 为什么要有这个（2026-10-10 实踩）：**两版位流可以装着完全相同的固件**，
 *     串口日志因此一模一样，事后分不出烧的是哪一版（见 doc/board/README.md 的
 *     A/B 那一节）。所以版本号必须来自【RTL 侧】—— 它由 `mimpid`（0xF13）读出，
 *     常量定义在 rtl/core/csr_file.v 的 DESIGN_REV。
 * [!] mimpid 是规范里的**只读** ID 寄存器：写它会抛非法指令（csr_file.v 的
 *     `wr_illegal`），只读不写。
 * [!] 这一行必须用**大写** `FW=GOMOKU` —— tb_rtthread.v 用小写 "gomoku"
 *     专门匹配 `[boot] gomoku render thread running`，这里写小写会让那条自检永远为真。 */
static uint32_t design_rev(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mimpid" : "=r"(v));
    return v;
}

static void uart_puthex32(uint32_t v)
{
    static const char hx[] = "0123456789abcdef";
    int i;
    for (i = 28; i >= 0; i -= 4) hw_uart_putc(hx[(v >> i) & 0xF]);
}

/* ---- 字符串拼接 / 数字格式化（固件没有 libc，自己写）---- */
/* 把 s 拷贝到 d 末尾，返回指向结束符的指针（便于链式拼字符串）。 */
static char *buf_append(char *d, const char *s)
{
    while (*s) *d++ = *s++;
    *d = '\0';
    return d;
}

/* 无符号十进制写进 buf（补结束符），返回指向结束符的指针。 */
static char *u32_to_str(char *buf, unsigned v)
{
    char tmp[11];
    int  n = 0;
    if (v == 0) { buf[0] = '0'; buf[1] = '\0'; return buf + 1; }
    while (v && n < 11) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) *buf++ = tmp[n];
    *buf = '\0';
    return buf;
}

/* ---- 串口棋盘快照 ---------------------------------------------------------
 * [!] **没有 HDMI 显示器时的唯一目视手段。** 板上跑的时候靠它验证棋局：
 *     棋盘对不对、光标在哪、轮到谁、AI 落哪了，全在串口里。
 * 15 列 A..O、15 行 1..15；X = 黑、O = 白、. = 空；`*` = 最后一手（覆盖颜色）。
 * 只在**棋子数变化**与**阶段变化**时打印，不刷屏 —— 于是串口留下的是一串
 * "每手一张棋盘"的记录，事后能逐手复盘。
 * [!] 别改成每帧打印：60fps 下会把串口灌爆，反而看不出东西。 */
/* [!] RT-Thread 宿主下不编译整盘镜像：15x15 字符棋盘一次 ~1KB，串口只有
 *     11.5KB/s，频繁打印会拖慢 UI 刷新（T7 实踩：日志被灌成乱码）。
 *     裸机版保留，用于无显示器调试。RT 构建的宏是 __RTTHREAD__。 */
#ifndef __RTTHREAD__
static void uart_dump_board(const game_t *gm)
{
    char line[3 + GOMOKU_N * 2 + 3];
    int  r, c;

    uart_puts("\r\n    A B C D E F G H I J K L M N O\r\n");
    for (r = 0; r < GOMOKU_N; r++) {
        int n = r + 1;
        line[0] = (char)(n >= 10 ? ('0' + n / 10) : ' ');
        line[1] = (char)('0' + n % 10);
        line[2] = ' ';
        for (c = 0; c < GOMOKU_N; c++) {
            uint8_t v  = gm->board.cell[r][c];
            char    ch = (v == GOMOKU_BLACK) ? 'X' :
                         (v == GOMOKU_WHITE) ? 'O' : '.';
            if (r == (int)gm->board.last_r && c == (int)gm->board.last_c) ch = '*';
            line[3 + c * 2]     = ch;
            line[3 + c * 2 + 1] = ' ';
        }
        line[3 + GOMOKU_N * 2]     = '\r';
        line[3 + GOMOKU_N * 2 + 1] = '\n';
        line[3 + GOMOKU_N * 2 + 2] = '\0';
        uart_puts(line);
    }
    uart_puts("cursor=");
    hw_uart_putc((char)('A' + gm->cursor_c));
    uart_putdec((unsigned)(gm->cursor_r + 1));
    uart_puts(" you=");
    uart_puts(gm->human == GOMOKU_BLACK ? "BLACK" : "WHITE");
    uart_puts(" turn=");
    uart_puts(gm->board.turn == GOMOKU_BLACK ? "BLACK" : "WHITE");
    uart_puts("\r\n");
}
#endif /* !__RTTHREAD__ */

/* ---- HUD 文字 ----
 * 把轮次/难度/AI 统计/胜负写到屏幕上下留白区（棋盘列 12..26、行 7..21 之外）。 */
static const char *level_name(int level)
{
    return level == AI_EASY   ? "EASY" :
           level == AI_NORMAL ? "NORMAL" : "HARD";
}

/* 菜单页名 / 选中项名 / 项文案 —— 只用字库里有字的字符（大写/数字/空格），见 font.h。 */

static const char *menu_page_name(int page)
{
    return page == MENU_PAGE_MAIN  ? "MAIN" :
           page == MENU_PAGE_HUMAN ? "HUMAN" : "AI";
}

static const char *menu_item_name(const game_t *gm)
{
    switch (gm->menu_page) {
    case MENU_PAGE_MAIN:  return gm->menu_cursor == 0 ? "HUMAN" : "AI";
    case MENU_PAGE_HUMAN: return gm->menu_cursor == 0 ? "DIFF" :
                                  gm->menu_cursor == 1 ? "COLOR" : "START";
    case MENU_PAGE_AI:    return gm->menu_cursor == 0 ? "BLACK" :
                                  gm->menu_cursor == 1 ? "WHITE" :
                                  gm->menu_cursor == 2 ? "STEP" : "START";
    }
    return "";
}

/* 菜单某一项的**选项名**（左对齐 X=6）。 */
static const char *menu_row_name(const game_t *gm, int i)
{
    switch (gm->menu_page) {
    case MENU_PAGE_MAIN:  return i == 0 ? "HUMAN VS AI" : "AI VS AI";
    case MENU_PAGE_HUMAN: return i == 0 ? "DIFFICULTY" :
                                 i == 1 ? "COLOR" : "START";
    case MENU_PAGE_AI:    return i == 0 ? "BLACK AI" :
                                 i == 1 ? "WHITE AI" :
                                 i == 2 ? "STEP" : "START";
    }
    return "";
}

/* 菜单某一项的**当前值**（< 固定 @18、值 @20 起左对齐、> 固定 @26 —— T6-R4）；START 返回空串。 */
static const char *menu_row_value(const game_t *gm, int i)
{
    static char buf[12];
    char *p = buf;

    switch (gm->menu_page) {
    case MENU_PAGE_MAIN:
        return "";
    case MENU_PAGE_HUMAN:
        if (i == 0) return level_name(gm->level_black);
        if (i == 1) return gm->human == GOMOKU_BLACK ? "BLACK" : "WHITE";
        return "";
    case MENU_PAGE_AI:
        if (i == 0) return level_name(gm->level_black);
        if (i == 1) return level_name(gm->level_white);
        if (i == 2) {
            p = u32_to_str(p, gm->step_ms);
            p = buf_append(p, "MS");
            *p = '\0';
            return buf;
        }
        return "";
    }
    return "";
}

static int level_depth(int level)
{
    return level == AI_HARD ? 6 : (level == AI_NORMAL ? 4 : 2);
}

/* ---------------------------------------------------------------------------
 * 标题屏（2026-10-18 改版，任务书 §2.2）
 * ---------------------------------------------------------------------------
 * 目标（v2 交接文档 §4）：深色 UI 底 + 4x 大 logo + 中文副标题 +
 *   5x5 自动对弈小棋盘 + 金色下划线选中态 + PRESS ANY KEY + 平台信息。
 *
 * [!] 三条容易踩的坑：
 *   1. 字库图块背景**不透明** ⇒ 不做整行金色底条/卡片；选中态用 ▶ + 下划线；
 *   2. 新美术**运行时合成**（render_init 里现算）⇒ 不写进 .rodata，镜像不涨；
 *   3. 小棋盘用**脚本走法**（下面的 DEMO_MOVES），不调 AI 线程 ⇒ 菜单不会被搜索卡住。
 *
 * [!] 标题屏只在「内容真的变了」时重画；左右键改值只重画当前行 + 说明行，
 *     闪烁那一行单独重画 —— 否则 60fps 全屏重绘会在 vblank 窗口外写显存。
 * ------------------------------------------------------------------------- */
/* ---- 标题屏布局（40x30，2026-10-19 T6-R4 重排：标题区拉开呼吸感）----------
 *   3~4   GOMOKU logo（2x12 tile）
 *   6     POWERED BY RISC-V & RT-THREAD（8x8 暗金，居中）
 *   8     五 子 棋（中文 3 字，金色；与 POWERED 行隔 1 行）
 *   11/13 主菜单 2 项；选中项 = ▶ + 金色下划线
 *   15    极暗分隔线（菜单区 / LAST COREMARK 区剥离，止于小棋盘左侧）
 *   16~18 LAST COREMARK / SCORE / CRC（8x8 暗灰；'|' 竖线锚 @5、文字 @7）
 *   12~16 右侧 5x5 小棋盘（cells，T6-R4 随菜单下移 1 行保持平齐），
 *         外框 11/17 行、27/33 列；网格四向出头伸向外框
 *   21    极暗分隔线
 *   22    UP/DN: SELECT | HOLD: OK（8x8 灰，左对齐）
 *   23    LEFT: START（8x8 灰，左对齐）
 *   27    PRESS ANY KEY（8x8 灰，闪烁，仅主菜单）
 * [!] 提示行拆两行是 T6-R2 的要求：按键组不与单行动作挤在一行。
 * [!] T6-R4：logo 5->3、POWERED 7->6、五子棋 9->8、菜单 10->11 ——
 *     标题三行与菜单之间都有空行；极暗线/CM 区/小棋盘随菜单整体下移 1 行，
 *     否则菜单第二项的下划线（row14）会压在极暗分隔线上。 */
#define TITLE_LOGO_ROW    3
#define TITLE_LOGO_COL    14
#define TITLE_POWERED_ROW 6          /* POWERED BY RISC-V & RT-THREAD（8x8 暗金） */
#define TITLE_SUB_ROW     8          /* 中文 五子棋（与 POWERED 行隔 1 行） */
#define TITLE_MENU_ROW0   11         /* 第一项菜单行 */
#define TITLE_MENU_GAP    2          /* 下划线占 1 行，所以项间空 2 行 */
#define TITLE_MENU_ARROW_X 4          /* 金色 ▶ */
#define TITLE_MENU_TEXT_X  6          /* 选项名左对齐 X=6 */
#define TITLE_MENU_CLEAR_W 27         /* 只清 0..26，右侧 5x5 小棋盘在 27..33 */
#define TITLE_VALUE_LT_X  18          /* 参数 < 固定列（T6-R4：不再随值长度漂移） */
#define TITLE_VALUE_X     20          /* 参数值左对齐起点（T6-R4） */
#define TITLE_VALUE_END    26         /* 参数 > 固定列 */
#define TITLE_FAINT1_ROW  15          /* 菜单区 / LAST COREMARK 区分隔（随菜单下移 1 行） */
#define TITLE_CM_ROW      16          /* LAST COREMARK 三行 16/17/18（8x8） */
#define TITLE_CM_BAR_X    5           /* '|' 竖线锚（三行同列，连成一条） */
#define TITLE_CM_COL      7           /* CoreMark 文字列（竖线右空 1 格） */
#define TITLE_SUB_DESC_ROW 18         /* 子菜单说明行（8x8 灰；AI 页 +1；随菜单下移 1 行） */
#define TITLE_DESC_COL    8           /* 子菜单说明文字列（'>' 锚 @6、空 1 格） */
#define TITLE_SUB_RULE_ROW 21         /* 子菜单极暗分隔线（提示行上方；随菜单下移，与主页 FAINT2 同行但不同页，不冲突） */
#define TITLE_FAINT2_ROW  21          /* LAST COREMARK 区 / 状态区分隔 */
#define TITLE_HINT_ROW    22          /* 操作提示第 1 行（8x8 灰，左对齐） */
#define TITLE_PROMPT_ROW  27          /* PRESS ANY KEY（8x8 灰，闪烁） */
#define TITLE_BAND_ROWS   0           /* row 0 / row 29 细带 */

/* 小棋盘：5x5 cells，cells 从 (12,28) 起；外框 11/17 行、27/33 列。
 * T6-R4 随菜单整体下移 1 行：框顶 row11 与菜单首项平齐、框底 row17 与
 * AI 页末项平齐，左右视觉平衡。极暗线 row15 只画到 col26，不与小棋盘相撞。 */
#define MINI_CELL_ROW     12
#define MINI_CELL_COL     28
#define TITLE_DEMO_N      5
#define TITLE_DEMO_MS     900u
typedef char title_layout_assert[(MINI_CELL_ROW + TITLE_DEMO_N <= TITLE_PROMPT_ROW - 1) ? 1 : -1];

/* 小棋盘的对局状态。放静态区（.bss 232 字节），不占栈 —— 栈顶只有 0xF000。 */
static gomoku_t s_demo;
static int      s_demo_i;      /* 下一手在表里的下标 */
static uint32_t s_demo_t;      /* 上一手落子时刻 */
static int      s_demo_gen;    /* 每落一子 +1；主循环据此判断要不要重画 */
static int      s_demo_ready;  /* 已放好开局 3 子（预览第一帧就能看到） */
static int      s_prompt_on = 1;   /* PRESS ANY KEY 当前是否亮着 */

/* 脚本走法：每两个字节一手 (行,列)，坐标是 5x5 子盘的 0..4。
 * 走完一轮就清盘重来 —— 录像里看起来像"两个 AI 一直在下"。
 * [!] 不调 AI：标题屏不该为装饰去抢 AI 线程/CPU（任务书 §2.3）。 */
static const uint8_t DEMO_MOVES[] = {
    2,2,  2,3,  3,3,  1,2,  3,2,  1,3,
    4,2,  0,2,  4,4,  0,4,  3,1,  1,1,
};
#define DEMO_N_MOVES  ((int)(sizeof(DEMO_MOVES) / 2))

static int text_len(const char *s)
{
    int n = 0;
    while (s[n]) n++;
    return n;
}

/* 选中项的说明行（仅二级菜单用；主菜单不再有说明行 —— T6 按示意稿删除，
 * 菜单区与 LAST COREMARK 区之间只留 row15 一条极暗线）。子菜单的难度说明跟着档位变。 */
static const char *menu_desc(const game_t *gm)
{
    static char buf[40];
    char *p;

    switch (gm->menu_page) {
    case MENU_PAGE_HUMAN:
        if (gm->menu_cursor == 0) {
            p = buf;
            p = buf_append(p, "AI SEARCH DEPTH: ");
            p = u32_to_str(p, (unsigned)level_depth(gm->level_black));
            p = buf_append(p, " PLY");
            *p = '\0';
            return buf;
        }
        return gm->menu_cursor == 1 ? "YOUR STONE COLOR" : "BEGIN THE MATCH";
    default:
        return gm->menu_cursor == 0 ? "BLACK SIDE STRENGTH" :
               gm->menu_cursor == 1 ? "WHITE SIDE STRENGTH" :
               gm->menu_cursor == 2 ? "DELAY BETWEEN MOVES" : "BEGIN THE MATCH";
    }
}

/* 菜单项在屏幕上的行号（0-based 第几项）。 */
#define MENU_ROW_OF(i)  (TITLE_MENU_ROW0 + (i) * TITLE_MENU_GAP)

/* AI 子菜单有 4 项（START 在 row17），说明行（AI 页）随之落到 19，避免贴着 START。 */
static int submenu_desc_row(void)
{
    return g_game.menu_page == MENU_PAGE_AI
           ? TITLE_SUB_DESC_ROW + 1 : TITLE_SUB_DESC_ROW;
}

/* 一行菜单项（v2 §5.3 + T6-R4）：
 *   选项名左对齐 X=6；值区固定列：< @18、值 @20 起左对齐、> @26 ——
 *   值长短不一时左尖括号保持整齐（原"< value >"整体拼接右对齐会让 < 参差）。
 *   选中项 = ▶ + 金色下划线。START 是按钮：选中时在上一行画金色分隔线。
 *   [!] 只清 0..26 列，右侧 5x5 小棋盘在 27..33，不能被整行清掉。 */
static void draw_menu_row(int row, const game_t *gm, int i, int selected)
{
    const char *name = menu_row_name(gm, i);
    const char *val  = menu_row_value(gm, i);

    render_clear_span(row, 0, TITLE_MENU_CLEAR_W);
    if (selected) render_put(row, TITLE_MENU_ARROW_X, RENDER_TILE_ARROW);
    render_text_span(row, TITLE_MENU_TEXT_X, name);

    if (val[0]) {
        /* [!] 边界已核：值最长 6 字（NORMAL/2000MS，占 20..25，不撞 > @26）；
         *     选项名最长 11 字（HUMAN VS AI，止于 col16，不撞 < @18）。 */
        render_text_span(row, TITLE_VALUE_LT_X, "<");
        render_text_span(row, TITLE_VALUE_X, val);
        render_text_span(row, TITLE_VALUE_END, ">");
    }

    if (selected) {
        int rule_len = (gm->menu_page == MENU_PAGE_MAIN)
                       ? text_len(name)
                       : TITLE_VALUE_END - TITLE_MENU_TEXT_X + 1;
        /* [!] 2026-10-19：原来最后一项画在 row-1，HUMAN 的 START(row15) 会让
         * 金线落在 row14（正好是 COLOR 的线），AI 的 START(row17) 落在 row16
         * （正好是 STEP 的线）—— 看起来光标移到 START 后线没动。
         * 一律画 row+1：HUMAN 16 / AI 18；AI 页说明行已下移到 19，不冲突。 */
        render_rule(row + 1, TITLE_MENU_TEXT_X, rule_len);
        /* [!] 2026-10-19 CPU 双发射 bug 绕行（RTL 暂不动）：
         *   JALR 在 BTB 未命中时 pair_now 仍可能把 jr 的下一条 fall-through
         *   配进 lane B 并真的执行。这里 render_rule 原本是尾调用，jr 后面
         *   恰好是 `lw a5,264(s3)`，用调用者旧的 s3(=2) 算出 0x10A ⇒
         *   load misaligned（mcause=4 / mtval=0x10A）。
         *   加一条 nop 后 GCC 不能再做尾调用，fall-through 变成无害的 nop。
         *   RTL 的正确修法（pair_now 排除 JALR）另行验证。 */
        __asm__ volatile("nop");
    }
}

/* LAST COREMARK：读 0xFF00 的共享邮箱（CoreMark 写、跨复位保留）。
 * 2026-10-19 T6：8x8 暗灰三行连续排（16/17/18，T6-R4 随菜单下移 1 行），
 * 最左侧 '|' 竖线锚 @5 三行同列连成一条，文字 @7（缩进 2 tile）
 * ——与上方菜单区用 row15 极暗线剥离。CRC 行补对齐空格让 ':' 与 SCORE 行
 * 对齐（排版对齐，不是撑长度）。 */
static void draw_last_coremark(void)
{
    volatile uint32_t *m = (volatile uint32_t *)CM_MBOX_BASE;
    char  buf[SCREEN_COLS + 1];
    char *p;
    uint32_t score;
    int    x = TITLE_CM_BAR_X;

    if (m[CM_MBOX_I_MAGIC] != CM_MBOX_MAGIC) return;

    score = m[CM_MBOX_I_SCORE];
    render_text8_span(TITLE_CM_ROW, x, "| LAST COREMARK");

    p = buf;
    p = buf_append(p, "| SCORE : ");
    p = u32_to_str(p, score / 100u);
    p = buf_append(p, ".");
    p = u32_to_str(p, (score % 100u) / 10u);
    *p = '\0';
    render_text8_span(TITLE_CM_ROW + 1, x, buf);

    p = buf;
    p = buf_append(p, "| CRC   : ");
    p = buf_append(p, (m[CM_MBOX_I_FLAGS] & CM_MBOX_FLAG_CRC_OK) ? "OK" : "BAD");
    *p = '\0';
    render_text8_span(TITLE_CM_ROW + 2, x, buf);
}

/* 小棋盘推进一手：走完一轮就清盘重来；落到已占的格子上就跳过（表写错了也不会崩）。 */
static void demo_advance(void)
{
    int guard = DEMO_N_MOVES;

    if (s_demo_i >= DEMO_N_MOVES) {
        gomoku_reset(&s_demo);
        s_demo_i = 0;
        s_demo_gen++;
        return;
    }
    while (guard-- > 0 && s_demo_i < DEMO_N_MOVES) {
        int r = DEMO_MOVES[s_demo_i * 2];
        int c = DEMO_MOVES[s_demo_i * 2 + 1];
        s_demo_i++;
        if (gomoku_place(&s_demo, r, c) == GOMOKU_OK) {
            s_demo_gen++;
            return;
        }
    }
}

/* 小棋盘开局放 3 子：预览第一帧就能看到 v2 §4.3 要的"3 颗黑白子"。 */
static void demo_seed(void)
{
    int i;
    if (s_demo_ready) return;
    gomoku_reset(&s_demo);
    for (i = 0; i < 3 && i < DEMO_N_MOVES; i++)
        gomoku_place(&s_demo, DEMO_MOVES[i * 2], DEMO_MOVES[i * 2 + 1]);
    s_demo_i = 3;
    s_demo_gen = 1;
    s_demo_ready = 1;
}

/* 只重画右侧 5x5 小棋盘（自动落子时用，不整屏刷新）。 */
static void title_redraw_mini(void)
{
    demo_seed();
    render_frame_at(MINI_CELL_ROW, MINI_CELL_COL, TITLE_DEMO_N);
    render_board_region(&s_demo, 0, 0, TITLE_DEMO_N, TITLE_DEMO_N,
                        MINI_CELL_ROW, MINI_CELL_COL);
}

/* PRESS ANY KEY：8x8 灰、左对齐到菜单文字列；只画这一行，不刷整屏。 */
static void title_prompt_draw(int on)
{
    if (on)
        render_text8_span(TITLE_PROMPT_ROW, TITLE_MENU_TEXT_X, "PRESS ANY KEY");
    else
        render_text(TITLE_PROMPT_ROW, 0, "");
}

/* 整屏重画标题页。只在页面/选中项/邮箱等"结构"变化时调。 */
static void title_draw_all(void)
{
    int i, n = game_menu_item_count(&g_game);

    render_clear();                    /* 深色 UI 底铺满 40x30 */

    /* 顶部/底部细带：给纯色底加一点层次（row 0 / row 29）。 */
    for (i = 0; i < SCREEN_COLS; i++) {
        render_put(0, i, RENDER_TILE_BG_BAND);
        render_put(SCREEN_ROWS - 1, i, RENDER_TILE_BG_BAND);
    }

    if (g_game.menu_page == MENU_PAGE_MAIN) {
        render_logo(TITLE_LOGO_ROW, TITLE_LOGO_COL);
        render_text8g_center(TITLE_POWERED_ROW, "Powered by RISC-V & RT-Thread");
        render_cjk(TITLE_SUB_ROW, 17, RENDER_CJK_WU);
        render_cjk(TITLE_SUB_ROW, 19, RENDER_CJK_ZI);
        render_cjk(TITLE_SUB_ROW, 21, RENDER_CJK_QI);

        for (i = 0; i < n; i++)
            draw_menu_row(MENU_ROW_OF(i), &g_game, i, i == g_game.menu_cursor);

        draw_last_coremark();
        render_faint_rule(TITLE_FAINT1_ROW, 1, TITLE_MENU_CLEAR_W - 1);
        title_redraw_mini();           /* 后画小棋盘：框/网格覆盖线尾区域 */

        render_faint_rule(TITLE_FAINT2_ROW, 1, SCREEN_COLS - 2);
        render_text(TITLE_HINT_ROW, 0, "");
        render_text8_span(TITLE_HINT_ROW, 1, "UP/DN: SELECT | HOLD: OK");
        render_text(TITLE_HINT_ROW + 1, 0, "");
        render_text8_span(TITLE_HINT_ROW + 1, 1, "LEFT: START");

        title_prompt_draw(1);
        s_prompt_on = 1;
    } else {
        /* 二级菜单：标题 row6 改用 16x16 亮白大字居中（T6-R4，原为中灰 8x8
         * 小字，作为页面标题没有区分度）；参数项 11/13/(15/17)；
         * 说明行 18/19；极暗线 row21；提示两行 22/23（与选项左对齐）。 */
        int drow = submenu_desc_row();

        render_text(6, 0, "");                         /* 标题行整行清 */
        render_text_center(6, g_game.menu_page == MENU_PAGE_HUMAN ? "HUMAN VS AI" : "AI VS AI");
        for (i = 0; i < n; i++)
            draw_menu_row(MENU_ROW_OF(i), &g_game, i, i == g_game.menu_cursor);
        render_text(drow, 0, "");                      /* 子菜单没有小棋盘，可整行清 */
        render_desc_arrow(drow, TITLE_MENU_TEXT_X);
        render_text8_span(drow, TITLE_DESC_COL, menu_desc(&g_game));

        render_faint_rule(TITLE_SUB_RULE_ROW, TITLE_MENU_TEXT_X, SCREEN_COLS - TITLE_MENU_TEXT_X - 2);
        render_text(TITLE_SUB_RULE_ROW + 1, 0, "");
        render_text8_span(TITLE_SUB_RULE_ROW + 1, TITLE_MENU_TEXT_X, "UP/DN: MOVE HOLD: OK");
        render_text(TITLE_SUB_RULE_ROW + 2, 0, "");
        render_text8_span(TITLE_SUB_RULE_ROW + 2, TITLE_MENU_TEXT_X, "LEFT: BACK");
        s_prompt_on = 0;
    }
}

/* 左右键改值：只重画当前项 + 说明行，不整屏刷新（v2 §5.3）。 */
static void title_redraw_value_rows(void)
{
    if (g_game.menu_page == MENU_PAGE_MAIN) {
        title_draw_all();
        return;
    }
    draw_menu_row(MENU_ROW_OF(g_game.menu_cursor), &g_game,
                  g_game.menu_cursor, 1);
    render_text(submenu_desc_row(), 0, "");
    render_desc_arrow(submenu_desc_row(), TITLE_MENU_TEXT_X);
    render_text8_span(submenu_desc_row(), TITLE_DESC_COL, menu_desc(&g_game));
}

/* 标题页的一拍：推进小棋盘、按需重画。返回 1 = 这一拍画了东西。 */
static int draw_title(uint32_t now, int force)
{
    static int s_page = -1, s_cursor = -1, s_mode = -1, s_human = -1;
    static int s_lb = -1, s_lw = -1, s_step = -1, s_demo = -1, s_cm = -1;
    volatile uint32_t *m = (volatile uint32_t *)CM_MBOX_BASE;
    int cm = (m[CM_MBOX_I_MAGIC] == CM_MBOX_MAGIC) ? (int)m[CM_MBOX_I_SCORE] : -1;
    int main_page = (g_game.menu_page == MENU_PAGE_MAIN);
    int structural, value_changed, demo_changed;
    int drew = 0;

    if (main_page &&
        (uint32_t)(now - s_demo_t) >= TITLE_DEMO_MS * hw_ticks_per_ms()) {
        s_demo_t = now;
        demo_advance();
    }

    structural = force || s_page != g_game.menu_page ||
                 s_cursor != g_game.menu_cursor || s_mode != g_game.mode ||
                 s_cm != cm;
    value_changed = (s_lb != g_game.level_black) ||
                    (s_lw != g_game.level_white) ||
                    (s_human != g_game.human) ||
                    (s_step != (int)g_game.step_ms);
    demo_changed = (s_demo != s_demo_gen);

    if (structural) {
        title_draw_all();
        drew = 1;
    } else if (value_changed) {
        title_redraw_value_rows();
        drew = 1;
    } else if (demo_changed && main_page) {
        title_redraw_mini();
        drew = 1;
    }

    s_page = g_game.menu_page;  s_cursor = g_game.menu_cursor;
    s_mode = g_game.mode;       s_human  = g_game.human;
    s_lb   = g_game.level_black; s_lw    = g_game.level_white;
    s_step = (int)g_game.step_ms; s_demo = s_demo_gen; s_cm = cm;

    /* PRESS ANY KEY：500ms 亮 / 500ms 灭；只重画这一行。子菜单不显示。 */
    if (main_page) {
        int on = ((now / (500u * hw_ticks_per_ms())) & 1u) == 0;
        if (on != s_prompt_on) {
            s_prompt_on = on;
            title_prompt_draw(on);
            drew = 1;
        }
    }

    return drew;
}

/* 对局 HUD：右侧 10 列（30..39），棋盘占 0..29。
 * [!] 不能用整行 render_text —— 它会把左侧棋盘一起铺成空格。
 * [!] T6 2026-10-19 行表（严格按坐标规范）：
 *      1  GOMOKU    16x16 金，居中（X=32）
 *      3  turn      8x8 暗灰 @32；4  图标 @31 + 16x16 值 @33
 *      6  level     8x8 @32；7  值 16x16 @33
 *      9  depth     8x8 @32；10 值 16x16 @33
 *      12 nodes     8x8 @32；13 值 16x16 @33
 *      15 time      8x8 @32；16 值 16x16 @33
 *      21 THINKING  16x16 绿（闪烁）X=32 / YOUR TURN 16x16 白 X=30
 *                   （T6-R3：18 -> 21，与 time 值之间留 4 行呼吸感；
 *                    T6-R4：THINKING 右移 2 列留白，不再贴棋盘网格；
 *                    YOUR TURN 9 字满宽，保持 X=30 不动）
 *      25 UP/DN MOVE 8x8 @30（横向一行写完）
 *      26 HOLD PLACE 8x8 @30
 *   AI vs AI 观战用同款节奏：black/white（带图标）/step/nodes/time 五组；
 *   depth 可由档位推出（EASY=2/NORMAL=4/HARD=6），不再单列。
 *   GAME_OVER 后胜负由棋盘中央弹窗负责，18 行清空。
 * [!] 提示行渲染为 "UP/DN MOVE" / "HOLD PLACE"：8x8 字库没有 [ ] 字模，
 *     且 HUD 宽 10 列放不下 12 字符 —— 去括号后各 10 字符正好满宽。 */
#define HUD_COL 30
#define HUD_W   10

static void hud_clear(int row)
{
    render_clear_span(row, HUD_COL, HUD_W);
}
static void hud_text8(int row, const char *s)
{
    hud_clear(row);
    render_text8_span(row, HUD_COL, s);
}
/* 8x8 灰标签：规范要求标签比值缩进 2 列（X=32）。 */
static void hud_label8(int row, const char *s)
{
    hud_clear(row);
    render_text8_span(row, HUD_COL + 2, s);
}
/* 16x16 亮白值：统一绝对左对齐 X=33 —— 与图标行（图标 @31、文字 @33）
 * 的文字列对齐。T6-R3：原来是 X=32，与图标行的 33 差 1 列，WHITE/HARD/
 * 6 PLY 左边缘不齐；现在所有值一概 X=33，无任何居中计算。 */
static void hud_value16(int row, const char *s)
{
    hud_clear(row);
    render_text_span(row, HUD_COL + 3, s);
}
/* 图标行：图标 @31、16x16 值 @33（规范 X=31 / X=33）。 */
static void hud_icon16(int row, uint8_t icon, const char *s)
{
    hud_clear(row);
    render_put(row, HUD_COL + 1, icon);
    render_text_span(row, HUD_COL + 3, s);
}

/* 节点数压缩：12874 -> "12.8K"，1234567 -> "1.2M"。无浮点。 */
static char *fmt_nodes(char *p, uint32_t v)
{
    if (v >= 1000000u) {
        uint32_t x = v / 100000u;                 /* 12.3M 的 123 */
        p = u32_to_str(p, x / 10u);
        p = buf_append(p, ".");
        p = u32_to_str(p, x % 10u);
        p = buf_append(p, "M");
    } else if (v >= 1000u) {
        uint32_t x = v / 100u;
        p = u32_to_str(p, x / 10u);
        p = buf_append(p, ".");
        p = u32_to_str(p, x % 10u);
        p = buf_append(p, "K");
    } else {
        p = u32_to_str(p, v);
    }
    return p;
}

/* 毫秒压缩：569 -> "569MS"，1234 -> "1.2S"。 */
static char *fmt_ms(char *p, uint32_t v)
{
    if (v >= 1000u) {
        uint32_t x = v / 100u;
        p = u32_to_str(p, x / 10u);
        p = buf_append(p, ".");
        p = u32_to_str(p, x % 10u);
        p = buf_append(p, "S");
    } else {
        p = u32_to_str(p, v);
        p = buf_append(p, "MS");
    }
    return p;
}

static void draw_hud(int think_on)
{
    char line[HUD_W + 2];
    char *p;
    int who = g_game.board.turn;
    int r;

    /* 先整块清 2..24 行（30..39 列），再按行表画 —— 行号调整不留残影。 */
    for (r = 2; r <= 24; r++) hud_clear(r);

    render_gold16_span(1, HUD_COL + (HUD_W - 6) / 2, "GOMOKU");   /* 16x16 金，X=32 */

    if (g_game.mode == GAME_MODE_AI) {
        /* AI vs AI 观战：同款节奏五组（Q2=A 决策），black/white 带图标。 */
        hud_label8(3, "BLACK");
        hud_icon16(4, RENDER_TILE_ICON_BLACK, level_name(g_game.level_black));
        hud_label8(6, "WHITE");
        hud_icon16(7, RENDER_TILE_ICON_WHITE, level_name(g_game.level_white));

        hud_label8(9, "STEP");
        p = line; p = u32_to_str(p, g_game.step_ms);
        p = buf_append(p, "MS"); *p = '\0';
        hud_value16(10, line);

        hud_label8(12, "NODES");
        p = line; p = fmt_nodes(p, g_game.ai_nodes); *p = '\0';
        hud_value16(13, line);

        hud_label8(15, "TIME");
        p = line; p = fmt_ms(p, g_game.ai_ms); *p = '\0';
        hud_value16(16, line);
    } else {
        /* 人类 vs AI：turn/level/depth/nodes/time 五组（坐标规范原样）。 */
        hud_label8(3, "TURN");
        hud_icon16(4,
                   who == GOMOKU_BLACK ? RENDER_TILE_ICON_BLACK : RENDER_TILE_ICON_WHITE,
                   who == GOMOKU_BLACK ? "BLACK" : "WHITE");

        hud_label8(6, "LEVEL");
        hud_value16(7, level_name(g_game.level_black));

        hud_label8(9, "DEPTH");
        p = line;
        p = u32_to_str(p, (unsigned)level_depth(g_game.level_black));
        p = buf_append(p, " PLY"); *p = '\0';
        hud_value16(10, line);

        hud_label8(12, "NODES");
        p = line; p = fmt_nodes(p, g_game.ai_nodes); *p = '\0';
        hud_value16(13, line);

        hud_label8(15, "TIME");
        p = line; p = fmt_ms(p, g_game.ai_ms); *p = '\0';
        hud_value16(16, line);
    }

    /* 21 行：AI 思考中 = THINKING（16x16 绿，500ms 闪）；轮到玩家 = YOUR TURN。
     * [T6-R3] 从 18 下移到 21：与 time/569MS（row16）之间隔 4 行留白，
     * 独立成一个提示区块；与底部按键提示（25/26）之间留 3 行。
     * 其它（含 GAME_OVER，胜负由弹窗显示）保持空。 */
    if (g_game.phase == GAME_PLAYING && game_ai_turn(&g_game)) {
        if (think_on) render_green16_span(21, HUD_COL + 2, "THINKING");  /* T6-R4：+2 列留白 */
    } else if (g_game.phase == GAME_PLAYING && g_game.mode != GAME_MODE_AI) {
        render_text_span(21, HUD_COL, "YOUR TURN");
    }

    /* 按键提示：横向一行一个，8x8 灰，HUD 最底（25/26）。 */
    hud_text8(25, "UP/DN MOVE");
    hud_text8(26, "HOLD PLACE");
}

/* 胜负弹窗（T6 2026-10-19）：棋盘正中央 16 列 x 5 行暗色底板
 * （rows 12..16 / cols 7..22；col0 = (30-16)/2、row0 = (30-5)/2）。
 * 文字两行，X 按公式 底板左 + (16 - 文字宽) / 2 完美居中：
 *   13  BLACK/WHITE WINS（名字 16x16 暖白 + WINS 绿字，宽 10 → X=10）
 *   15  HOLD TO TITLE（16x16 纯白，宽 13 → X=8；原 PRESS HOLD TO TITLE 精简，
 *       防止撑破 16 列底板） */
static void draw_overlay(void)
{
    int r;
    for (r = 12; r <= 16; r++) render_clear_span(r, 7, 16);

    if (g_game.winner == 0) {
        render_text_span(13, 13, "DRAW");              /* 宽 4 → 7+(16-4)/2 */
    } else {
        render_text_span(13, 10, g_game.winner == GOMOKU_BLACK ? "BLACK " : "WHITE ");
        render_wins(13, 16);
    }
    render_text_span(15, 8, "HOLD TO TITLE");
}

/* HUD 内容签名：只在变化时重画，避免每帧写 30..39 列。 */
static int hud_sig_changed(int think_on)
{
    static int s_phase = -1, s_turn = -1, s_stones = -1, s_winner = -1;
    static int s_mode = -1, s_nodes = -1, s_ms = -1, s_depth = -1;
    static int s_lb = -1, s_lw = -1, s_step = -1, s_think = -1;
    int changed =
        s_phase != (int)g_game.phase || s_turn != (int)g_game.board.turn ||
        s_stones != (int)g_game.board.stones || s_winner != g_game.winner ||
        s_mode != g_game.mode || s_nodes != (int)g_game.ai_nodes ||
        s_ms != (int)g_game.ai_ms || s_depth != g_game.ai_depth ||
        s_lb != g_game.level_black || s_lw != g_game.level_white ||
        s_step != (int)g_game.step_ms || s_think != think_on;
    s_phase = (int)g_game.phase; s_turn = (int)g_game.board.turn;
    s_stones = (int)g_game.board.stones; s_winner = g_game.winner;
    s_mode = g_game.mode; s_nodes = (int)g_game.ai_nodes;
    s_ms = (int)g_game.ai_ms; s_depth = g_game.ai_depth;
    s_lb = g_game.level_black; s_lw = g_game.level_white;
    s_step = (int)g_game.step_ms; s_think = think_on;
    return changed;
}

/* 画一帧。
 *   标题屏：按需重画（logo/菜单/小棋盘），不每帧全屏刷。
 *   对局屏：2x2 棋盘（30x30 tile）+ 右栏 HUD；只在落子/光标/回合变化时刷。
 * [!] 标题屏不画大棋盘，进出对局各要整屏抹一次，否则会留残影。 */
static void draw_frame(uint32_t now)
{
    static int last_phase = -1;
    static int s_stones = -1, s_cr = -2, s_cc = -2, s_on = -1;
    int cr = -1, cc = -1, on, board_changed;
    int think_on = 1;                 /* AI 思考闪烁相位：500ms 亮/灭 */

    if (g_game.phase == GAME_COREMARK) {
        cm_screen_tick(now);          /* 终端演示屏：闪烁/进度/收尾全在里面 */
        last_phase = GAME_COREMARK;
        return;
    }

    if (last_phase == GAME_COREMARK) {
        /* 离开演示屏（长按 SW6 → 标题）：把借走的图块与调色板全量恢复。
         * 随后的 draw_title(force=1) 会整屏重画，不会留残影。 */
        render_term_end();
    }

    if (g_game.phase == GAME_TITLE) {
        draw_title(now, last_phase != GAME_TITLE);
        last_phase = GAME_TITLE;
        return;
    }

    if (last_phase != (int)g_game.phase && last_phase == (int)GAME_TITLE) {
        render_clear();                 /* 抹掉标题屏；棋盘 + HUD 随后全画 */
    }

    on = game_cursor_shown(&g_game);
    if (on) { cr = g_game.cursor_r; cc = g_game.cursor_c; }

    if (g_game.phase == GAME_PLAYING && game_ai_turn(&g_game))
        think_on = (int)((now / (500u * hw_ticks_per_ms())) & 1u);

    board_changed = last_phase != (int)g_game.phase ||
                    s_stones != (int)g_game.board.stones ||
                    s_cr != cr || s_cc != cc || s_on != on;

    if (board_changed) render_full2(&g_game.board, cr, cc);
    if (hud_sig_changed(think_on) || last_phase != (int)g_game.phase)
        draw_hud(think_on);
    if (g_game.phase == GAME_OVER && (board_changed || last_phase != (int)g_game.phase))
        draw_overlay();

    s_stones = (int)g_game.board.stones;
    s_cr = cr; s_cc = cc; s_on = on;
    last_phase = g_game.phase;
}

/* ---------------------------------------------------------------------------
 * 主程序
 * ------------------------------------------------------------------------- */
/* [!] 入口【不叫 main】—— 叫 gomoku_run()。
 *     原因：五子棋要同时支持【裸机】和【RT-Thread】两种宿主，
 *     而 RT-Thread 自己也有一个 main()（入口线程）。两个 main() 在链接期必撞。
 *     所以把主循环摘成普通函数：
 *       · 裸机      -> main_entry.c 里的 main() 直接调它
 *       · RT-Thread -> app/main.c 建一个线程调它（见 scripts/rtthread/）
 *     本函数【不会返回】（for(;;)）。 */

/* ---------------------------------------------------------------------------
 * 宿主 AI 泵（弱函数）：每一帧 game_tick 之后调一次，负责「把该下的 AI 下掉」。
 *   裸机默认：同步算完（阻塞在 ai_choose_move）。
 *   RT-Thread 宿主：用强定义覆盖成「派单给低优先级 AI 线程 + 非阻塞收结果」。
 *   返回 1 = 这一帧真的落了 AI 的子。
 * ------------------------------------------------------------------------- */
__attribute__((weak))
int gomoku_ai_pump(game_t *gm, uint32_t now)
{
    ai_stats_t st;
    uint32_t   t0 = hw_mtime();

    if (game_ai_run_sync(gm, now, &st)) {
        gm->ai_ms = hw_ticks_to_ms(hw_mtime() - t0);
        return 1;
    }
    return 0;
}

void gomoku_run(void)
{
    int i;
    int prev_phase;
    int prev_stones;
    int prev_cr, prev_cc;      /* 上次打印时的光标位置 —— 短按移动要有串口反馈 */
    int prev_mode, prev_human; /* 菜单：模式 / 执子（变化要有串口反馈）*/
    int prev_level_black, prev_level_white;   /* 菜单：黑白难度 */
    int prev_step_ms;                         /* 菜单：间隔档 */
    int prev_page, prev_cursor;               /* 菜单：页 / 选中项 */
    int warned_no_video = 0;   /* vblank 超时只报一次，别把串口灌爆 */

    /* ---- 1) 显示初始化 ----------------------------------------------------
     * [!] 显存上电是**随机内容**（BRAM 未初始化），不填调色板和图块的话
     *     屏幕上是一片雪花。render_init 必须最先做。 */
    render_init();
    video_set_scroll(0, 0);      /* 棋类静态，滚动归零；但必须显式写一次 */
    render_clear();

    /* ---- 2) 输入与状态机 -------------------------------------------------- */
    input_init(&g_input, hw_mtime(), hw_key_raw(),
               INPUT_DEBOUNCE_MS * hw_ticks_per_ms(),
               INPUT_LONG_MS     * hw_ticks_per_ms());
    /* 难度可编译期覆盖 —— **仿真必须用 EASY**。
     * NORMAL(4 层) 一次搜索约 2 亿拍，仿真里要跑十几分钟真实时间；
     * EASY 是纯贪心、一次函数调用，秒出。见 build.ps1 -Sim。 */
    game_init(&g_game, GOMOKU_AI_LEVEL, GOMOKU_BLACK, BLINK_MS * hw_ticks_per_ms());
    /* demo_delay（AI 对弈每手间隔）在主循环里每帧按 step_ms 现算 —— 菜单可改档 */

    /* 标题屏右侧的 5x5 自动对弈小棋盘：开局 3 子 + 计时起点（脚本走法，见 DEMO_MOVES）*/
    demo_seed();
    s_demo_t = hw_mtime();

    /* ---- SW6+SW7 复位彩蛋（T7）：boot selector 写的演示标志（0xFF80）----
     * boot.S 三路径：SW6 按住 = 官方裸机跑分（不变）；SW6+SW7 = 写标志后进
     * RT-Thread。这里读到标志就【跳过标题屏】直接进 GAME_COREMARK 终端演示屏，
     * 读完【立即清零】—— 一次性语义，否则普通复位会被旧标志再次拽进演示屏。
     * 界面行为见 coremark_screen.c（A1：真实成绩的重放展示）。 */
    {
        volatile uint32_t *flag = (volatile uint32_t *)CM_BOOT_FLAG_ADDR;
        if (*flag == CM_BOOT_FLAG_MAGIC) {
            *flag = 0u;
            g_game.phase = GAME_COREMARK;
            cm_screen_begin();
            uart_puts("[boot] coremark demo screen (SW6+SW7)\r\n");
        }
    }

    /* 第一行就自证版本：FW=固件名，RTL=设计版本号（来自 mimpid）。
     * 两版位流装同一份固件时，靠 RTL= 那一段区分（见上面 design_rev 的说明）。 */
    uart_puts("\r\n[build] FW=GOMOKU RTL=0x");
    uart_puthex32(design_rev());
    uart_puts("\r\n");

    /* 版式自检：把关键锚点打到串口，上板时一眼能对。 */
    uart_puts("[title] menu_row0=");
    uart_putdec(TITLE_MENU_ROW0);
    uart_puts(" mini_cell=");
    uart_putdec(MINI_CELL_ROW);
    uart_puts(",");
    uart_putdec(MINI_CELL_COL);
    uart_puts(" gap=");
    uart_putdec(TITLE_MENU_GAP);
    uart_puts(" value_end=");
    uart_putdec(TITLE_VALUE_END);
    uart_puts("\r\n");

    uart_puts("=== GOMOKU on RV32I ===\r\n");
    uart_puts("keys: SW4/5/6/7 = left/right/up/down\r\n");
    uart_puts("      title menu: up/down = move, left/right = change value, hold = OK\r\n");
    uart_puts("      play: tap = move cursor, hold = place\r\n");
    uart_puts("      SW3 = reset\r\n");
#ifndef __RTTHREAD__
    uart_puts("board: X=black O=white .=empty *=last move  (serial mirror, no monitor needed)\r\n");
#endif

    prev_phase  = (int)g_game.phase;
    prev_stones = (int)g_game.board.stones;
    prev_cr     = g_game.cursor_r;
    prev_cc     = g_game.cursor_c;
    prev_mode        = -1;
    prev_human       = -1;
    prev_level_black = -1;
    prev_level_white = -1;
    prev_step_ms     = -1;
    prev_page        = -1;
    prev_cursor      = -1;     /* -1 保证上电第一圈就把菜单当前值全打一遍 */

    /* ---- 3) 主循环 -------------------------------------------------------- */
    for (;;) {
        uint32_t now;
        uint8_t  smask = 0, lmask = 0;

        /* 与帧同步。这一句同时也是主循环的节拍器。 */
        /* [!] 非 0 = 视频没在跑（vblank 超时）。**注意区分"偶发超时"和"一直超时"**：
         *     偶发一次可能是复位后视频刚起来，不必刷屏；一直超时才值得报。
         *     这里只在【第一次】超时时打一行串口 —— 之后不再刷，免得把串口灌爆。
         *     关键点：**超时也继续往下走**，所以按键、状态机、串口都还活着。 */
        if (video_wait_vblank() != 0) {
            if (!warned_no_video) {
                warned_no_video = 1;
                uart_puts("[!] vblank timeout -- video not running (check D18 video_locked)\r\n");
            }
        }
        now = hw_mtime();

        /* AI 对弈每手间隔：菜单里 step_ms 是毫秒，这里换算成 now 的单位。
         * 每帧现算 —— 菜单改档后下一局自然生效，不用在别处同步。 */
        g_game.demo_delay = g_game.step_ms * hw_ticks_per_ms();

        /* ---- 采样按键：4 个键逐个取事件 ---- */
        input_poll(&g_input, now, hw_key_raw());
        for (i = 0; i < INPUT_N_KEYS; i++) {
            if (input_take_short(&g_input, i)) smask |= (uint8_t)(1u << i);
            if (input_take_long(&g_input, i))  lmask |= (uint8_t)(1u << i);
        }

        /* ---- 推状态机。AI 在这里同步跑完（会阻塞几帧的时间）---- */
        /* [!] AI 是【同步阻塞】跑的（见文件头）。NORMAL 一手 0.4~0.7 秒无所谓，
         * 但 HARD(6 层) 实测一手要【14.5 秒】（开局那手 24,246 节点）——
         * 之前这段时间串口一片安静，玩家以为板子死了（2026-10-04 实测反馈）。
         *
         * [!] 但这里必须【先预测】再打，不能无脑打。只有"长按 + 轮到自己 +
         *     该点为空"三件事同时成立，game_tick 里的那次长按才会真的落子并触发 AI。
         *     2026-10-04 实踩：无脑打的话，往【已有子】的点长按会打出
         *     "AI thinking..." 却因为落子失败而没有下文 —— 看着比不打还糟，
         *     用户直接以为是卡死了（H6 已经有一颗黑子，实测复现）。
         *     所以落子失败也【必须】给一行话：串口上没有输出 = 用户以为按键没生效。 */
        if (g_game.mode != GAME_MODE_AI && lmask != 0 && g_game.phase == GAME_PLAYING && game_ai_turn(&g_game)) {
            if (g_game.board.cell[g_game.cursor_r][g_game.cursor_c] != GOMOKU_EMPTY) {
                uart_puts("occupied -- move the cursor and try again\r\n");
            } else {
                uart_puts("AI thinking (");
                uart_puts(level_name(game_ai_level(&g_game)));
                uart_puts(")...\r\n");
            }
        }
        game_tick(&g_game, now, smask, lmask);
        /* 宿主 AI 泵：裸机在这里同步算完并刷新 ai_ms；RT-Thread 宿主覆盖成
         * 「派单给低优先级 AI 线程 + 非阻塞收结果」（见 app/main.c）。
         * 只有真的落了 AI 子的那一帧才刷新 ai_ms —— 见 gomoku_ai_pump。 */
        gomoku_ai_pump(&g_game, now);

        /* ---- 刷屏 ---- */
        draw_frame(now);

        /* ---- 状态变化就打串口（一次性事件，不刷屏）---- */
        if (g_game.phase != (game_phase_t)prev_phase) {
            if (g_game.phase == GAME_PLAYING) {
                if (g_game.mode == GAME_MODE_AI) {
                    uart_puts("AI match: black=");
                    uart_puts(level_name(g_game.level_black));
                    uart_puts(" white=");
                    uart_puts(level_name(g_game.level_white));
                    uart_puts(" step=");
                    uart_putdec(g_game.step_ms);
                    uart_puts("ms\r\n");
                } else {
                    uart_puts("start, level=");
                    uart_puts(level_name(g_game.level_black));
                    uart_puts(" you=");
                    uart_puts(g_game.human == GOMOKU_BLACK ? "BLACK" : "WHITE");
                    uart_puts("\r\n");
                }
            } else if (g_game.phase == GAME_OVER) {
                uart_puts(g_game.winner == GOMOKU_BLACK ? "BLACK wins\r\n" :
                          g_game.winner == GOMOKU_WHITE ? "WHITE wins\r\n" :
                                                          "draw\r\n");
            } else {
                uart_puts("title\r\n");
            }
            /* [!] 开始一局时要把【空棋盘】也打出来。2026-10-04 实测反馈：
             * 只打一行 "start, level=N" 的话，玩家根本不知道游戏开没开、
             * 轮到谁、光标在哪 —— 因为开局时棋子数还是 0，不算"变化"，
             * 下面那段 stone-diff 的棋盘快照【不会触发】。 */
#ifndef __RTTHREAD__
            if (g_game.phase == GAME_PLAYING) uart_dump_board(&g_game);
#endif
            prev_phase = (int)g_game.phase;
        }
        if (g_game.board.stones != prev_stones) {
            int delta = g_game.board.stones - prev_stones;
            /* AI 落子时 stones 会 +2（人一手 + AI 一手）；单独打印 AI 那手的统计 */
            if (delta > 1 || g_game.board.turn == g_game.human || g_game.mode == GAME_MODE_AI) {
                uart_puts("AI moved, nodes=");
                uart_putdec((unsigned)g_game.ai_nodes);
                uart_puts(" depth=");
                uart_putdec((unsigned)g_game.ai_depth);
                uart_puts(" t=");
                uart_putdec((unsigned)g_game.ai_ms);
                uart_puts("ms\r\n");
            }
            /* 每变一次棋子就吐一张棋盘 —— 无显示器时靠它验证棋局（见 uart_dump_board）
             * [!] RT-Thread 宿主不打印（串口带宽不够，会拖慢 UI）。 */
#ifndef __RTTHREAD__
            uart_dump_board(&g_game);
#endif
            prev_stones = (int)g_game.board.stones;
        }

        /* [!] 标题屏菜单变化【本来是完全静默的】—— 2026-10-04 实测反馈：
         * 按了键却没有任何输出，只能靠开局那行反推，玩家根本不知道档位切没切。
         * 这里把菜单每一项的变化都打到串口。 */
        if (g_game.menu_page != prev_page) {
            prev_page = g_game.menu_page;
            uart_puts("menu=");
            uart_puts(menu_page_name(prev_page));
            uart_puts("\r\n");
        }
        if (g_game.menu_cursor != prev_cursor) {
            prev_cursor = g_game.menu_cursor;
            uart_puts("item=");
            uart_puts(menu_item_name(&g_game));
            uart_puts("\r\n");
        }
        if (g_game.mode != prev_mode) {
            prev_mode = g_game.mode;
            uart_puts("mode=");
            uart_puts(prev_mode == GAME_MODE_AI ? "AI" : "HUMAN");
            uart_puts("\r\n");
        }
        if (g_game.human != prev_human) {
            prev_human = g_game.human;
            uart_puts("you=");
            uart_puts(prev_human == GOMOKU_BLACK ? "BLACK" : "WHITE");
            uart_puts("\r\n");
        }
        if (g_game.level_black != prev_level_black) {
            prev_level_black = g_game.level_black;
            uart_puts("black=");
            uart_puts(level_name(prev_level_black));
            uart_puts("\r\n");
        }
        if (g_game.level_white != prev_level_white) {
            prev_level_white = g_game.level_white;
            uart_puts("white=");
            uart_puts(level_name(prev_level_white));
            uart_puts("\r\n");
        }
        if ((int)g_game.step_ms != prev_step_ms) {
            prev_step_ms = (int)g_game.step_ms;
            uart_puts("step=");
            uart_putdec(g_game.step_ms);
            uart_puts("ms\r\n");
        }

        /* 光标动了就报一行。短按移动在板上本来是"零反馈"的 ——
         * 没有这行，按住方向键完全不知道有没有生效（2026-10-04 实测反馈）。 */
        if (g_game.cursor_r != prev_cr || g_game.cursor_c != prev_cc) {
            prev_cr = g_game.cursor_r;
            prev_cc = g_game.cursor_c;
            uart_puts("cursor=");
            hw_uart_putc((char)('A' + prev_cc));
            uart_putdec((unsigned)(prev_cr + 1));
            uart_puts("\r\n");
        }
    }

    /* 不会走到（上面是 for(;;)）。函数返回 void，所以直接 return。 */
}
