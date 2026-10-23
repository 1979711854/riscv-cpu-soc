/* ============================================================================
 * render.c —— 五子棋渲染层的实现（轨道 A3）
 * ----------------------------------------------------------------------------
 * [!] 不用 libc（没有 memset/memcpy），要能原样编进 RV32 固件。
 *     唯一的平台依赖是 vid_bulk_write()，在 render.h 里声明、由平台实现。
 * ==========================================================================*/
#include "render.h"
#include "tiles.h"
#include "font.h"

/* 调色板下标 —— 与 gen_tiles.py 的 PAL 顺序、palette.h 的 TILE_PALETTE 一致。
 * 合成图块（红标/星位/外框/图标/logo/选中框）用这些常量取色，不硬编码数字。
 * [!] 2026-10-18 起调色板拆到 palette.h（CoreMark 的文本控制台也 include 它），
 *     所以这里不再自己 #define，直接由 tiles.h -> palette.h 提供。 */

/* 四条边哪几条有线（up<<3 | down<<2 | left<<1 | right）-> shape 0..8
 * 只有 9 种组合会出现在 15x15 的棋盘上：
 *   15=内部  7=上边 11=下边 13=左边 14=右边  5=左上 6=右上 9=左下 10=右下
 * 其余（1x1 棋盘之类的退化情况）落到 0（内部形状），反正不会出现。
 * [!] 这张表必须与 gen_tiles.py 的 SHAPES 顺序一致。 */
static const uint8_t SHAPE_LUT[16] = {
    /* 0 0000 */ 0,
    /* 1 0001 */ 0,
    /* 2 0010 */ 0,
    /* 3 0011 */ 0,
    /* 4 0100 */ 0,
    /* 5 0101 */ 5,   /* 上 + 左  = 左上角 */
    /* 6 0110 */ 6,   /* 上 + 右  = 右上角 */
    /* 7 0111 */ 1,   /* 上边 */
    /* 8 1000 */ 0,
    /* 9 1001 */ 7,   /* 下 + 左  = 左下角 */
    /*10 1010 */ 8,   /* 下 + 右  = 右下角 */
    /*11 1011 */ 2,   /* 下边 */
    /*12 1100 */ 0,
    /*13 1101 */ 3,   /* 左边 */
    /*14 1110 */ 4,   /* 右边 */
    /*15 1111 */ 0    /* 内部 */
};

/* 16x16 系字形 = 5x7 放大 FONT_SCALE 倍。换算字模坐标时**不能直接除**：
 * C 的整数除法向零截断，p < o 时的 -1 / 2 会变成 0，把左上角多画一条
 * （字模第 0 列/行），几何就不是居中的 10x14 了。 */
static int glyph_coord(int p, int o)
{
    return (p >= o) ? (p - o) / FONT_SCALE : -1;
}

uint8_t render_shape(int r, int c)
{
    uint8_t m = 0;
    if (r > 0)              m |= 8u;   /* 上 */
    if (r < GOMOKU_N - 1)   m |= 4u;   /* 下 */
    if (c > 0)              m |= 2u;   /* 左 */
    if (c < GOMOKU_N - 1)   m |= 1u;   /* 右 */
    return SHAPE_LUT[m];
}

/* [T6-R2] 小棋盘网格四向出头：原 shape_dim（按边缘位置挑"上边/下边/角"
 * 图块）退役 —— 小棋盘所有交叉点一律用"内部十字"图块（shape 0，四向线
 * 贯通到图块边缘），边缘交叉点向四个方向各出头约 7px（半个图块），
 * 网格伸向木色外框，框与网格间隙从 15px 缩到 7px，视觉上铺满框内区域，
 * 角部呈闭合的"+"形。 */

/* 星位点：天元 + 四个小目（15x15 交叉点）。2x2 棋盘用它选 245..248 四个象限。 */
static int render_is_star(int r, int c)
{
    return (r == 3 && c == 3) || (r == 3 && c == 11) ||
           (r == 7 && c == 7) ||
           (r == 11 && c == 3) || (r == 11 && c == 11);
}

/* 字符 → 16x16 字库图块号。小写折叠到大写；不在子集里的字符落空格图块。 */
static uint8_t glyph_tile(int ch)
{
    int idx;
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch < FONT_BASE || ch > 0x7E) return (uint8_t)FONT_TILE_BASE;
    idx = (int)FONT_INDEX[ch - FONT_BASE];
    if (idx < 0 || idx >= FONT_N_GLYPHS) return (uint8_t)FONT_TILE_BASE;
    return (uint8_t)(FONT_TILE_BASE + idx);
}

/* 字符 → 16x16 子集的 5x7 位图行指针（logo 合成用）。 */
static const uint8_t *glyph_rows(int ch)
{
    int idx;
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch < FONT_BASE || ch > 0x7E) return FONT_GLYPH[0];
    idx = (int)FONT_INDEX[ch - FONT_BASE];
    if (idx < 0 || idx >= FONT_N_GLYPHS) return FONT_GLYPH[0];
    return FONT_GLYPH[idx];
}

/* 字符 → 暗金 8x8 图块号（POWERED 行专用子集，17 字）。
 * 空格/未收录字符落灰色 8x8 空格图块 —— 空格图块是纯底色，颜色无关。 */
static uint8_t glyph8g_tile(int ch)
{
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch < FONT_BASE || ch > 0x7E) return (uint8_t)FONT8_TILE_BASE;
    if (FONT8G_TILE[ch - FONT_BASE] == 0xFF)
        return (uint8_t)FONT8_TILE_BASE;
    return (uint8_t)FONT8G_TILE[ch - FONT_BASE];
}

/* 字符 → 金色 16x16 图块号（HUD 标题 GOMOKU，5 字）。未收录落暖白空格图块。 */
static uint8_t glyph_gold16_tile(int ch)
{
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch < FONT_BASE || ch > 0x7E) return (uint8_t)FONT_TILE_BASE;
    if (FONT_GOLD16_TILE[ch - FONT_BASE] == 0xFF)
        return (uint8_t)FONT_TILE_BASE;
    return (uint8_t)FONT_GOLD16_TILE[ch - FONT_BASE];
}

/* 字符 → 绿色 16x16 图块号（HUD THINKING，6 字）。未收录落暖白空格图块。 */
static uint8_t glyph_green16_tile(int ch)
{
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch < FONT_BASE || ch > 0x7E) return (uint8_t)FONT_TILE_BASE;
    if (FONT_GREEN16_TILE[ch - FONT_BASE] == 0xFF)
        return (uint8_t)FONT_TILE_BASE;
    return (uint8_t)FONT_GREEN16_TILE[ch - FONT_BASE];
}

/* 字符 → 8x8 提示图块号。不在 8x8 子集里就落空格图块。 */
static uint8_t glyph8_tile(int ch)
{
    int idx;
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    if (ch < FONT_BASE || ch > 0x7E) return (uint8_t)FONT8_TILE_BASE;
    idx = (int)FONT8_INDEX[ch - FONT_BASE];
    if (idx < 0 || idx >= FONT8_N_GLYPHS) return (uint8_t)FONT8_TILE_BASE;
    return (uint8_t)(FONT8_TILE_BASE + idx);
}

uint8_t render_tile_for(const gomoku_t *g, int r, int c, int cr, int cc)
{
    uint8_t shape = render_shape(r, c);

    if (r == cr && c == cc)                         /* 光标优先 */
        return RENDER_TILE(shape, RENDER_ST_CURSOR);
    if (g->cell[r][c] == GOMOKU_BLACK)
        return RENDER_TILE(shape, RENDER_ST_BLACK);
    if (g->cell[r][c] == GOMOKU_WHITE)
        return RENDER_TILE(shape, RENDER_ST_WHITE);
    return RENDER_TILE(shape, RENDER_ST_EMPTY);
}

/* 写一个 nametable 字节。地址 = (BOARD_ROW0+r)*256 + (BOARD_COL0+c) */
static void put_nt(int r, int c, uint8_t tile)
{
    uint16_t off = (uint16_t)((BOARD_ROW0 + r) * 256 + (BOARD_COL0 + c));
    vid_bulk_write(VID_REGION_NT, off, &tile, 1);
}

/* 写一个 nametable 字节（【绝对】行/列 0..29 / 0..39）。HUD 图标/坐标轴/外框逐格写用它。 */
static void put_abs(int row, int col, uint8_t tile)
{
    uint16_t off = (uint16_t)(row * 256 + col);
    vid_bulk_write(VID_REGION_NT, off, &tile, 1);
}

void render_put(int row, int col, uint8_t tile)
{
    if (row < 0 || row >= SCREEN_ROWS || col < 0 || col >= SCREEN_COLS) return;
    put_abs(row, col, tile);
}

void render_cell(const gomoku_t *g, int r, int c, int cr, int cc)
{
    if (r < 0 || r >= GOMOKU_N || c < 0 || c >= GOMOKU_N) return;
    put_nt(r, c, render_tile_for(g, r, c, cr, cc));
}

void render_full(const gomoku_t *g, int cr, int cc)
{
    int r, c;
    for (r = 0; r < GOMOKU_N; r++)
        for (c = 0; c < GOMOKU_N; c++)
            put_nt(r, c, render_tile_for(g, r, c, cr, cc));
}

/* 对局屏：15x15 格 × 2x2 tile = 30x30 tile（480x480），原点 (0,0)。
 * 每格写 4 个 nametable 字节（TL/TR/BL/BR），右侧 30..39 列留给 HUD。 */
void render_full2(const gomoku_t *g, int cr, int cc)
{
    int r, c, q;
    for (r = 0; r < GOMOKU_N; r++) {
        for (c = 0; c < GOMOKU_N; c++) {
            int shape = render_shape(r, c);
            uint8_t v  = g->cell[r][c];
            int st     = (v == GOMOKU_BLACK) ? RENDER_ST_BLACK :
                         (v == GOMOKU_WHITE) ? RENDER_ST_WHITE : RENDER_ST_EMPTY;
            int star   = 0;

            if (r == cr && c == cc && st == RENDER_ST_EMPTY) {
                st = RENDER_ST_CURSOR;
            } else if (st == RENDER_ST_EMPTY && render_is_star(r, c)) {
                star = 1;
            }

            for (q = 0; q < 4; q++) {
                uint8_t tile = star
                    ? (uint8_t)(RENDER_TILE_BOARD2_STAR + q)
                    : (uint8_t)(RENDER_TILE_BOARD2_BASE + BOARD2_MAP[shape][st][q]);
                put_abs(r * 2 + (q >> 1), c * 2 + (q & 1), tile);
            }

            /* 最后一手：右上象限盖红三角。黑/白各一张专用图块，底是真实棋子，
             * 不再用“木色底”把棋子右上角擦掉。 */
            if (v != GOMOKU_EMPTY && r == (int)g->last_r && c == (int)g->last_c)
                put_abs(r * 2, c * 2 + 1,
                        (st == RENDER_ST_WHITE) ? RENDER_TILE_BOARD2_LAST_W
                                                : RENDER_TILE_BOARD2_LAST);
        }
    }
}

void render_move_cursor(const gomoku_t *g, int oldr, int oldc, int newr, int newc)
{
    /* 旧位置按"没有光标"重画，新位置带上光标 —— 正好 2 个字节。
     * 注意别用 render_cell(..., newr, newc) 去重画旧位置：那样光标会跟过去。 */
    render_cell(g, oldr, oldc, -1, -1);
    render_cell(g, newr, newc, newr, newc);
}

void render_clear(void)
{
    /* 用【空格字模】（16x16 纯底色图块）铺满整屏 40x30。HUD 文字画在上面，
     * 底色干净才好看 —— 原来的"内部形状空格"带网格线，会让留白区变成网格底。 */
    uint8_t row[SCREEN_COLS];
    int r, c;
    for (c = 0; c < SCREEN_COLS; c++) row[c] = (uint8_t)FONT_TILE_BASE;
    for (r = 0; r < SCREEN_ROWS; r++)
        vid_bulk_write(VID_REGION_NT, (uint16_t)(r * 256), row, (uint16_t)SCREEN_COLS);
}

/* ---------------------------------------------------------------------------
 * 棋盘外框 + 坐标轴（阶段 1 静态装饰）。都画在 15x15 之外，上电各调一次即可；
 * render_full 每帧全刷只碰棋盘区，不会覆盖它们。
 * ------------------------------------------------------------------------- */
void render_frame_at(int r0, int c0, int n)
{
    int i;
    /* 四角复用棋盘边角图块（shape 5/6/7/8 空状态）—— 与棋盘边角同款，不另做图块。 */
    put_abs(r0 - 1, c0 - 1, RENDER_TILE(TILE_SHAPE_TOPLEFT,  RENDER_ST_EMPTY));
    put_abs(r0 - 1, c0 + n, RENDER_TILE(TILE_SHAPE_TOPRIGHT, RENDER_ST_EMPTY));
    put_abs(r0 + n, c0 - 1, RENDER_TILE(TILE_SHAPE_BOTLEFT,  RENDER_ST_EMPTY));
    put_abs(r0 + n, c0 + n, RENDER_TILE(TILE_SHAPE_BOTRIGHT, RENDER_ST_EMPTY));
    /* 上下横边 */
    for (i = 0; i < n; i++) {
        put_abs(r0 - 1,    c0 + i, RENDER_TILE_FRAME_H);
        put_abs(r0 + n,    c0 + i, RENDER_TILE_FRAME_H);
    }
    /* 左右竖边 */
    for (i = 0; i < n; i++) {
        put_abs(r0 + i, c0 - 1, RENDER_TILE_FRAME_V);
        put_abs(r0 + i, c0 + n, RENDER_TILE_FRAME_V);
    }
}

/* 子盘区域：只有棋子/空格，没有光标、星位、最后一手标记。
 * [T6-R2] 所有交叉点用"内部十字"图块（shape 0）：边缘交叉点的线向四外
 * 出头约 7px，网格伸向木色外框（框与网格间隙 15px -> 7px）。
 * 一行一次 vid_bulk_write（cols 个字节），比逐格写少 cols-1 次调用。 */
void render_board_region(const gomoku_t *g, int r0, int c0, int rows, int cols,
                         int sr, int sc)
{
    uint8_t line[GOMOKU_N];
    int r, c;

    if (rows > SCREEN_COLS) rows = SCREEN_COLS;
    for (r = 0; r < rows; r++) {
        for (c = 0; c < cols; c++) {
            uint8_t st = RENDER_ST_EMPTY;
            uint8_t v  = g->cell[r0 + r][c0 + c];
            if (v == GOMOKU_BLACK)      st = RENDER_ST_BLACK;
            else if (v == GOMOKU_WHITE) st = RENDER_ST_WHITE;
            line[c] = RENDER_TILE(0u, st);      /* 十字图块：四向线全画 */
        }
        vid_bulk_write(VID_REGION_NT, (uint16_t)((sr + r) * 256 + sc), line, (uint16_t)cols);
    }
}

/* ---------------------------------------------------------------------------
 * HUD 文字
 * ------------------------------------------------------------------------- */
/* ---------------------------------------------------------------------------
 * 把 (col, s) 摊成【整行】图块索引：先铺满空格，再把文字盖上去。
 * [!] 必须整行铺，不能"只写字符串本身" —— 那样会留下上一次的残字，而且【左端也留】：
 *     2026-10-07 板上实踩，标题屏从 "LEVEL: NORMAL"(13 字) 切到 "LEVEL: EASY"(11 字)，
 *     居中起点由列 13 变成 14、终点由 25 变成 24，两端各留一个 'L'
 *     ⇒ 屏幕显示成 "LLEVEL: EASYL"。（第一版只补了行尾，测试当场抓出左端还漏。）
 * ------------------------------------------------------------------------- */
static void build_line(uint8_t *line, int col, const char *s)
{
    int i;
    for (i = 0; i < SCREEN_COLS; i++) line[i] = (uint8_t)FONT_TILE_BASE;
    i = 0;
    while (s[i] != '\0' && col + i < SCREEN_COLS) {
        int ch = (int)(unsigned char)s[i];
        if (col + i >= 0) line[col + i] = glyph_tile(ch);
        i++;
    }
}

void render_text(int row, int col, const char *s)
{
    /* 整行一次 vid_bulk_write 比逐字符写快得多。 */
    uint8_t line[SCREEN_COLS];
    build_line(line, col, s);
    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256), line, (uint16_t)SCREEN_COLS);
}

void render_text_span(int row, int col, const char *s)
{
    /* [!] 只写这几个格子，**不铺整行**。
     *     用途：和其他内容共享同一行的短标签（标题屏的 "AI VS AI"、LAST COREMARK
     *     那三行）。用 render_text 会把整行先铺成空格，把同一行上的选中框/说明行
     *     一起抹掉 —— 2026-10-18 第二轮反馈里"选中框缺一段"就是这么来的。 */
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        int c = col + i;
        if (c < 0 || c >= SCREEN_COLS) break;
        put_abs(row, c, glyph_tile((int)(unsigned char)s[i]));
    }
}

void render_text_center(int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text(row, (SCREEN_COLS - len) / 2, s);
}

void render_text8_span(int row, int col, const char *s)
{
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        int c = col + i;
        if (c < 0 || c >= SCREEN_COLS) break;
        put_abs(row, c, glyph8_tile((int)(unsigned char)s[i]));
    }
}

void render_text8_center(int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text8_span(row, (SCREEN_COLS - len) / 2, s);
}

void render_text8g_span(int row, int col, const char *s)
{
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        int c = col + i;
        if (c < 0 || c >= SCREEN_COLS) break;
        put_abs(row, c, glyph8g_tile((int)(unsigned char)s[i]));
    }
}

void render_text8g_center(int row, const char *s)
{
    int len = 0;
    while (s[len] != '\0' && len < SCREEN_COLS) len++;
    render_text8g_span(row, (SCREEN_COLS - len) / 2, s);
}

/* [T7] 标题中灰 8x8 子集已整集退役（痛点二后无使用者）—— glyph_tgray_tile /
 * render_text_tgray_span/center 与 render_init 里的合成循环一并删除；
 * 图块号 129/130/146..149/178..179 释放为空闲。 */

void render_gold16_span(int row, int col, const char *s)
{
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        int c = col + i;
        if (c < 0 || c >= SCREEN_COLS) break;
        put_abs(row, c, glyph_gold16_tile((int)(unsigned char)s[i]));
    }
}

void render_green16_span(int row, int col, const char *s)
{
    int i;
    for (i = 0; s[i] != '\0'; i++) {
        int c = col + i;
        if (c < 0 || c >= SCREEN_COLS) break;
        put_abs(row, c, glyph_green16_tile((int)(unsigned char)s[i]));
    }
}

void render_faint_rule(int row, int col, int len)
{
    int i;
    for (i = 0; i < len; i++) render_put(row, col + i, RENDER_TILE_FAINT_RULE);
}

void render_desc_arrow(int row, int col)
{
    render_put(row, col, RENDER_TILE_DESC_ARROW);
}

void render_clear_span(int row, int col, int n)
{
    uint8_t line[SCREEN_COLS];
    int i;
    if (row < 0 || row >= SCREEN_ROWS) return;
    if (n > SCREEN_COLS) n = SCREEN_COLS;
    for (i = 0; i < n; i++) line[i] = (uint8_t)FONT_TILE_BASE;
    if (col < 0) { n += col; col = 0; }
    if (col + n > SCREEN_COLS) n = SCREEN_COLS - col;
    if (n <= 0) return;
    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256 + col), line, (uint16_t)n);
}

void render_cjk(int row, int col, int code)
{
    int idx;
    if (code == RENDER_CJK_WU)      idx = 0;
    else if (code == RENDER_CJK_ZI) idx = 1;
    else if (code == RENDER_CJK_QI) idx = 2;
    else return;
    render_put(row, col, (uint8_t)(FONT_CJK_TILE_BASE + idx));
}

void render_wins(int row, int col)
{
    render_put(row, col,     RENDER_TILE_WINS_BASE);
    render_put(row, col + 1, (uint8_t)(RENDER_TILE_WINS_BASE + 1));
    render_put(row, col + 2, (uint8_t)(RENDER_TILE_WINS_BASE + 2));
    render_put(row, col + 3, (uint8_t)(RENDER_TILE_WINS_BASE + 3));
}

/* ---- 阶段 1 合成图块：在 render_init 里现算，不占固件 .rodata ---------------
 * 刻意【不用 libc】（没有 memcpy），用显式循环搬像素。 */

/* 棋盘图块的合成函数（定义在下面 render_init 之前，这里先声明）。 */
static void synth_board_tile(uint8_t *buf, int shape, int state);

/* 外框纯横线 / 纯竖线（2px，与棋盘线同色）。四角复用棋盘边角图块。
 * [!] 2026-10-18 保留 **PAL_BG（木色）底**，不要改成 UI 深色：
 *     外框四角复用的是棋盘边角图块（木色），只把横/竖线改成深色底，
 *     棋盘四周就会出现 4 个"木色小方块"角块，看着像画错了。
 *     木框 + 木棋盘 = 一整块木色棋盘，外面才是深色 UI —— 这正是任务书
 *     §2.2.1 要的"深色 UI + 木色棋盘"两色体系。 */
static void synth_frame_h(uint8_t *buf)
{
    int i, x;
    for (i = 0; i < TILE_BYTES; i++) buf[i] = PAL_BG;
    for (x = 0; x < TILE_W; x++) { buf[7 * TILE_W + x] = PAL_LINE; buf[8 * TILE_W + x] = PAL_LINE; }
}

static void synth_frame_v(uint8_t *buf)
{
    int i, y;
    for (i = 0; i < TILE_BYTES; i++) buf[i] = PAL_BG;
    for (y = 0; y < TILE_W; y++) { buf[y * TILE_W + 7] = PAL_LINE; buf[y * TILE_W + 8] = PAL_LINE; }
}

/* 纯底棋子图标（无网格线）。color/hi_color 与 gen_tiles.py 的 draw_stone 同义；
 * 用 2x 整数坐标替代浮点（dx = x-7.5 ⇒ 2dx = 2x-15），避免链接 libm。 */
static void synth_icon(uint8_t *buf, int color, int hi_color)
{
    int y, x;
    for (y = 0; y < TILE_W; y++) {
        for (x = 0; x < TILE_W; x++) {
            int dx = 2 * x - (TILE_W - 1);
            int dy = 2 * y - (TILE_W - 1);
            int d2 = dx * dx + dy * dy;
            if (d2 <= 144) {                              /* (2*STONE_R)^2 = 144 */
                int hx = dx + 4, hy = dy + 4;             /* 高光圆心左/上偏 2px */
                buf[y * TILE_W + x] = (uint8_t)((hx * hx + hy * hy <= 16) ? hi_color : color);
            } else {
                /* 2026-10-18：图标现在只出现在深色 UI 上（标题屏菜单 + 对局 HUD），
                 * 背景跟着 FONT_BG 走，否则会出现一个个木色小方块。 */
                buf[y * TILE_W + x] = PAL_UI_BG;
            }
        }
    }
}

/* ---------------------------------------------------------------------------
 * 标题屏装饰：4x 大 logo / 金色选中框 / 金色分隔线（2026-10-18）
 * ---------------------------------------------------------------------------
 * [!] 全部在 render_init() 里现算，源码里只有一小段循环，**没有 24 块 × 256B
 *     的常量表**（那会把 RT-Thread 镜像顶爆，见任务书 §2.4）。
 * [!] 图块是 16x16，没有精灵层、没有半透明 —— 所以"投影"是在合成时把
 *     字模/棋子整体往右下偏 2 像素再画一遍，不是运行时叠加。
 * ------------------------------------------------------------------------- */

/* logo 一个字母（或一颗棋子）占 2x2 图块 = 32x32 像素。 */
#define LOGO_CELL (RENDER_LOGO_TILE_W * TILE_W)          /* 32 */
#define LOGO_OX   ((LOGO_CELL - FONT_W * RENDER_LOGO_SCALE) / 2)   /* 6  */
#define LOGO_OY   ((LOGO_CELL - FONT_H * RENDER_LOGO_SCALE) / 2)   /* 2  */
#define LOGO_SHADOW 2                                    /* 投影偏移（像素） */

/* 字模像素：gx/gy 是 0..31 的 logo 内坐标。1 = 亮。 */
static int logo_glyph_px(const uint8_t *rows, int gx, int gy)
{
    int fx, fy;
    if (gx < LOGO_OX || gy < LOGO_OY) return 0;           /* 先挡住负下标 —— C 的
                                                          * 负数除法朝 0 截断，
                                                          * 会错误地落回 fx=0 */
    fx = (gx - LOGO_OX) / RENDER_LOGO_SCALE;
    fy = (gy - LOGO_OY) / RENDER_LOGO_SCALE;
    if (fx >= FONT_W || fy >= FONT_H) return 0;
    return (rows[fy] >> (FONT_W - 1 - fx)) & 1;
}

/* 棋子像素：stone = 1 黑 / 2 白。返回该像素该用的调色板下标，0xFF = 不属于棋子。 */
static uint8_t logo_stone_px(int gx, int gy, int stone)
{
    int dx = 2 * gx - (LOGO_CELL - 1);
    int dy = 2 * gy - (LOGO_CELL - 1);
    int d2 = dx * dx + dy * dy;
    int hx, hy;

    if (d2 > 900) return 0xFF;                            /* r = 15 之外 */
    if (d2 >= 676) return (uint8_t)PAL_GOLD;              /* r 13..15：金边
                                                           * （深底上黑子没有边
                                                           *  就看不见） */
    hx = dx + 8; hy = dy + 8;                             /* 高光偏左上 4px */
    if (hx * hx + hy * hy <= 64)
        return (uint8_t)(stone == 1 ? PAL_BLACK_HI : PAL_WHITE_EDGE);
    return (uint8_t)(stone == 1 ? PAL_BLACK : PAL_WHITE);
}

/* 合成一块 logo 图块：ch 为字符；stone != 0 时忽略字模、画棋子。 */
static void synth_logo_tile(uint8_t *buf, char ch, int stone, int qx, int qy)
{
    const uint8_t *rows = glyph_rows(ch);
    int x, y;

    for (y = 0; y < TILE_W; y++) {
        for (x = 0; x < TILE_W; x++) {
            int gx = qx * TILE_W + x;
            int gy = qy * TILE_W + y;
            uint8_t v = (stone ? logo_stone_px(gx, gy, stone)
                               : (logo_glyph_px(rows, gx, gy) ? (uint8_t)PAL_GOLD : 0xFF));
            if (v == 0xFF) {
                /* 投影：本像素的左上 LOGO_SHADOW 处有笔画 ⇒ 这里落阴影。
                 * 效果 = 笔画整体往右下偏 2px 的那一份。 */
                int sgx = gx - LOGO_SHADOW, sgy = gy - LOGO_SHADOW;
                int ink = 0;
                if (sgx >= 0 && sgy >= 0)
                    ink = stone ? (logo_stone_px(sgx, sgy, stone) != 0xFF)
                                : logo_glyph_px(rows, sgx, sgy);
                v = (uint8_t)(ink ? PAL_SHADOW : PAL_UI_BG);
            }
            buf[y * TILE_W + x] = v;
        }
    }
}

/* 金色分隔线：中间两行金色，其余 UI 底。 */
static void synth_rule(uint8_t *buf)
{
    int x, y;
    for (y = 0; y < TILE_W; y++)
        for (x = 0; x < TILE_W; x++)
            buf[y * TILE_W + x] = (uint8_t)((y == 7 || y == 8) ? PAL_GOLD : PAL_UI_BG);
}

/* 选中项左侧的金色右三角（指向文字）。背景 = UI 底，和标题屏融为一体。 */
static void synth_arrow(uint8_t *buf)
{
    int x, y;
    for (y = 0; y < TILE_W; y++)
        for (x = 0; x < TILE_W; x++)
            buf[y * TILE_W + x] = PAL_UI_BG;
    for (y = 3; y <= 12; y++) {
        int span = (y <= 7 ? (y - 2) : (13 - y)) * 2;   /* 2,4,..,10,10,..,2 */
        for (x = 4; x <= 4 + span; x++)
            buf[y * TILE_W + x] = PAL_GOLD;
    }
}

/* 把一块图块写进显存（合成一遍写一次，只在 init 调）。 */
static void put_pat(uint16_t tile, const uint8_t *buf)
{
    vid_bulk_write(VID_REGION_PAT, (uint16_t)(tile * TILE_BYTES), buf, (uint16_t)TILE_BYTES);
}

/* T6 新增的三个变色子集与 8x8 提示字库同几何，只换前景色：
 *   暗金 8x8（POWERED 行，FONT8G_*，独立位图表——'&'/'-' 不在灰色子集里）
 *   金 16x16 / 绿 16x16（5x7 放大 2x，字形用 FONT_INDEX -> FONT_GLYPH 取） */

/* 极暗横线：1px，只比 UI 底亮一丁点。 */
static void synth_faint_rule(uint8_t *buf)
{
    int x, y;
    for (y = 0; y < TILE_W; y++)
        for (x = 0; x < TILE_W; x++)
            buf[y * TILE_W + x] = (uint8_t)(y == 7 ? PAL_UI_FAINT : PAL_UI_BG);
}

/* 暗金说明锚点：5x7 的 '>'，1x 居中。 */
static void synth_desc_arrow(uint8_t *buf)
{
    const uint8_t *rows = glyph_rows('>');
    int x, y;
    int ox = (TILE_W - FONT_W) / 2;      /* 5 */
    int oy = (TILE_W - FONT_H) / 2;      /* 4 */
    for (y = 0; y < TILE_W; y++) {
        for (x = 0; x < TILE_W; x++) {
            uint8_t v = (uint8_t)PAL_UI_BG;
            int fx = x - ox, fy = y - oy;
            if (fx >= 0 && fx < FONT_W && fy >= 0 && fy < FONT_H &&
                ((rows[fy] >> (FONT_W - 1 - fx)) & 1u))
                v = (uint8_t)PAL_GOLD_DIM;
            buf[y * TILE_W + x] = v;
        }
    }
}

/* ---------------------------------------------------------------------------
 * CoreMark 终端演示屏（GAME_COREMARK，2026-10-19 T7）—— 见 render.h 的说明。
 * 字形表（FONT_TERM_*）由 gen_tiles.py 生成进 font.h；图块号「借」标题屏
 * 专用块（logo/WINS/中文/GOMKU/THINKING 前两块），退出时 render_init 恢复。
 * ------------------------------------------------------------------------- */

/* 变色子集（绿/金 16x16 + 各 8x8 系）的合成逻辑同构，抽成一个通用助手：
 *   wide8=0 → 5x7 放大 2x（16x16 系）；wide8=1 → 8x7 按 1x（8x8 系）。
 * glyphs 是 [n][FONT_H] 位表摊平传进来；图块号二选一：
 *   tiles != NULL → 查 ASCII→图块号映射表；tiles == NULL → 连续编号 base+g
 *   （chars 此时可为 NULL，仅用于映射模式）。render_init 与终端屏共用。 */
static void synth_glyph_set(const char *chars, const uint8_t *glyphs,
                              const uint8_t *tiles, int base, int n,
                              int fg, int bg, int wide8)
{
    uint8_t tile[TILE_BYTES];
    int g, x, y;
    int ox = wide8 ? (TILE_W - FONT8_W) / 2
                   : (TILE_W - FONT_W * FONT_SCALE) / 2;
    /* [!] 16x16 系是 5x7 **放大 2x**（10x14），垂直方向也要按 FONT_SCALE 居中；
     *     1x 的 oy 会让字形只剩半高、整体偏下（T7 重构时漏掉的一处）。 */
    int oy = wide8 ? (TILE_W - FONT_H) / 2
                   : (TILE_W - FONT_H * FONT_SCALE) / 2;
    int fw = wide8 ? FONT8_W : FONT_W;

    for (g = 0; g < n; g++) {
        int tn = tiles ? (int)tiles[(int)(unsigned char)chars[g]] : base + g;
        for (y = 0; y < TILE_W; y++) {
            for (x = 0; x < TILE_W; x++) {
                int fx = wide8 ? (x - ox) : glyph_coord(x, ox);
                int fy = wide8 ? (y - oy) : glyph_coord(y, oy);
                uint8_t v = (uint8_t)bg;
                if (fx >= 0 && fx < fw && fy >= 0 && fy < FONT_H) {
                    int bit = wide8 ? (FONT8_W - 1 - fx) : (FONT_W - 1 - fx);
                    if ((glyphs[g * FONT_H + fy] >> bit) & 1u)
                        v = (uint8_t)fg;
                }
                tile[y * TILE_W + x] = v;
            }
        }
        put_pat((uint16_t)tn, tile);
    }
}

/* 生成侧的字形图块表（FONT8G_TILE / FONT_TERM_*_TILE）按 **ord(ch)-FONT_BASE**
 * 索引（95 项，对应 ASCII 32..126）；而 synth_glyph_set 的映射模式按 **ASCII 原值**
 * 取表。这里把表摊到栈上的 ASCII 索引表再传，图块号不再整体错位 32 格。
 * [!] 栈表必须开 127 项（不是 95）：GREEN16 含 '['(91) / ']'(93)，按 95 项开表
 *     会越界。**不扩生成侧表** —— RT-Thread 镜像 rodata 已 99.7% 满。 */
static void synth_glyph_set_ord32(const char *chars, const uint8_t *glyphs,
                                  const uint8_t *tiles, int n,
                                  int fg, int bg, int wide8)
{
    uint8_t m[127];
    int i;

    for (i = 0; i < 127; i++) m[i] = 0xFF;
    for (i = 0; i < 95; i++) m[FONT_BASE + i] = tiles[i];
    synth_glyph_set(chars, glyphs, m, 0, n, fg, bg, wide8);
}

/* 终端监控区 8x8 绿字（15 字）。图块号借 **对局 2x2 棋盘区 188..202**：
 * 演示屏期间这些棋盘图块不用，且 render_init 会全量重建它们 ⇒
 * render_term_end 后逐字节还原（test_render §G 的 memcmp 判据）。
 * **不用 255**（测试哨兵），也不动 GOLD16/GREEN16 正在用的号段。 */
static const char    TERM_G8_CHARS[16] = "0123456789.KSEC";
static const uint8_t TERM_G8_TILES[15] = {
    188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202
};

/* 把 8x8 的 0-9 / . / K / S / E / C 合成成亮绿字块（16x16 居中，wide8=1）。 */
static void synth_term_green8(void)
{
    uint8_t m[95];
    uint8_t g[15][FONT_H];
    int i, j, ci, gi;

    for (i = 0; i < 95; i++) m[i] = 0xFF;
    for (i = 0; i < 15; i++) {
        ci = (int)(unsigned char)TERM_G8_CHARS[i] - FONT_BASE;
        gi = (ci >= 0 && ci < 95) ? (int)FONT8_INDEX[ci] : 0xFF;
        /* [!] m 是 synth_glyph_set 的 **ASCII 原值**索引表（与 m8 同）；
         *     ci 是 font.h 表的 ord-32 索引，只用于取位图。两者别混。 */
        m[(int)(unsigned char)TERM_G8_CHARS[i]] = TERM_G8_TILES[i];
        for (j = 0; j < FONT_H; j++)
            g[i][j] = (gi >= 0 && gi < FONT8_N_GLYPHS) ? FONT8_GLYPH[gi][j] : 0;
    }
    synth_glyph_set(TERM_G8_CHARS, (const uint8_t *)g, m, 0, 15,
                    PAL_OK, PAL_UI_BG, 1);
}

/* 终端借图块查询（见 render.h）。核心作用是**只在这一个 TU 里引用生成表**：
 * coremark_screen.c 若自己拿表当指针传，同一张 95B 表会在两个 .o 里各驻留一份。 */
uint8_t render_term_tile(int set, char ch)
{
    const uint8_t *map;
    int c = (int)(unsigned char)ch;
    int i;

    if (c >= 'a' && c <= 'z') c -= 32;              /* 子集只收大写 */
    if (set == RENDER_TERM_SET_GREEN8) {
        for (i = 0; i < 15; i++)
            if (TERM_G8_CHARS[i] == (char)c) return TERM_G8_TILES[i];
        return 0xFF;
    }
    if (c < FONT_BASE || c > 0x7E) return 0xFF;     /* 空格/控制字符 */
    map = (set == RENDER_TERM_SET_GREEN16) ? FONT_TERM_GREEN16_TILE
                                           : FONT_TERM_GOLD16_TILE;
    return map[c - FONT_BASE];
}

void render_term_begin(void)
{
    uint8_t pal4[4];
    uint8_t tile[TILE_BYTES];
    int i;

    /* 1) UI 底（调色板 7）换纯黑：演示屏期间所有字库图块的底跟着变黑。
     *    只动这一项；render_term_end() -> render_init() 会写回原值。 */
    pal4[0] = 0x00; pal4[1] = 0x00; pal4[2] = 0x00; pal4[3] = 0;
    vid_bulk_write(VID_REGION_PAL, (uint16_t)(PAL_UI_BG * 4), pal4, 4);

    /* 2) 终端字形：亮绿/亮金 16x16 + 亮绿/暗灰 8x8（借主图块号在 font.h 表里）
     * [T7] 两个 8x8 小子集（OK / %）只用 3 个图块号 —— 映射表在栈上现造，
     *      不占 2×95 字节的 .rodata。 */
    synth_glyph_set_ord32(FONT_TERM_GREEN16_CHARS, (const uint8_t *)FONT_TERM_GREEN16_GLYPH,
                          FONT_TERM_GREEN16_TILE, FONT_TERM_GREEN16_N,
                          FONT_TERM_GREEN16_FG, FONT_TERM_GREEN16_BG, 0);
    synth_glyph_set_ord32(FONT_TERM_GOLD16_CHARS, (const uint8_t *)FONT_TERM_GOLD16_GLYPH,
                          FONT_TERM_GOLD16_TILE, FONT_TERM_GOLD16_N,
                          FONT_TERM_GOLD16_FG, FONT_TERM_GOLD16_BG, 0);
    {
        uint8_t m8[95];
        for (i = 0; i < 95; i++) m8[i] = 0xFF;
        m8['O'] = RENDER_TILE_TERM_OK_O; m8['K'] = RENDER_TILE_TERM_OK_K;
        synth_glyph_set("OK", (const uint8_t *)FONT_TERM_GREEN8_GLYPH,
                        m8, 0, FONT_TERM_GREEN8_N,
                        FONT_TERM_GREEN8_FG, FONT_TERM_GREEN8_BG, 1);
        m8['O'] = 0xFF; m8['K'] = 0xFF; m8['%'] = RENDER_TILE_TERM_PCT;
        synth_glyph_set("%", (const uint8_t *)FONT_TERM_GRAY8_GLYPH,
                        m8, 0, FONT_TERM_GRAY8_N,
                        FONT_TERM_GRAY8_FG, FONT_TERM_GRAY8_BG, 1);
    }
    synth_term_green8();          /* 监控区数值：8x8 亮绿 */

    /* 3) 进度条实心块：填充 = 亮绿，空轨 = 极暗（借 THINKING 的 T/H，见 render.h）*/
    for (i = 0; i < TILE_BYTES; i++) tile[i] = (uint8_t)PAL_OK;
    put_pat(RENDER_TILE_TERM_FILL, tile);
    for (i = 0; i < TILE_BYTES; i++) tile[i] = (uint8_t)PAL_UI_FAINT;
    put_pat(RENDER_TILE_TERM_TRACK, tile);

    render_clear();                      /* 纯黑铺满 40x30 */
}

void render_term_end(void)
{
    render_init();                       /* 调色板 + 全部图块一次性恢复 */
}

/* ---------------------------------------------------------------------------
 * 36 块棋盘图块：**运行时合成**（2026-10-18 从 .rodata 搬到这里）
 * ---------------------------------------------------------------------------
 * 为什么：那张 36 × 256B 的常量表 = 9,216 字节，跟着 RT-Thread 镜像一起驻留
 *   RAM。镜像已经到 96.8%，堆只剩一百多字节 —— 把表换成这段几何代码，
 *   .rodata 少 9KB、代码多几百字节，堆立刻回到 8KB 以上。
 *
 * [!] 几何必须与 gen_tiles.py 逐像素一致（那边是 Python 参考实现）：
 *     线宽 2px 在 7..8 行列；棋子半径 6、高光半径 2 偏左上；光标是 5.5..7 的空心圈。
 *     `test_render.c` 用 tiles_data.h 的参考表逐像素对拍，画歪了会当场 FAIL。
 * ------------------------------------------------------------------------- */

/* 9 种形状的四条边（上/下/左/右）有没有线 —— 顺序与 gen_tiles.py 的 SHAPES 一致 */
static const uint8_t SHAPE_EDGES[TILE_N_SHAPE][4] = {
    {1, 1, 1, 1},   /* 0 内部 */
    {0, 1, 1, 1},   /* 1 上边 */
    {1, 0, 1, 1},   /* 2 下边 */
    {1, 1, 0, 1},   /* 3 左边 */
    {1, 1, 1, 0},   /* 4 右边 */
    {0, 1, 0, 1},   /* 5 左上角 */
    {0, 1, 1, 0},   /* 6 右上角 */
    {1, 0, 0, 1},   /* 7 左下角 */
    {1, 0, 1, 0},   /* 8 右下角 */
};

static void synth_board_tile(uint8_t *buf, int shape, int state)
{
    const uint8_t *e = SHAPE_EDGES[shape];
    int up = e[0], dn = e[1], lf = e[2], rt = e[3];
    int i, x, y;

    for (i = 0; i < TILE_BYTES; i++) buf[i] = PAL_BG;

    /* 横线：两端都有线就贯穿，只有一端就从中心画到那一端（必须画到边界，
     * 否则相邻两块之间会断开，整张棋盘看起来是虚线）。 */
    if (lf || rt) {
        int x0 = lf ? 0 : 8;
        int x1 = rt ? (TILE_W - 1) : 7;
        for (y = 7; y <= 8; y++)
            for (x = x0; x <= x1; x++) buf[y * TILE_W + x] = PAL_LINE;
    }
    /* 竖线（同上）*/
    if (up || dn) {
        int y0 = up ? 0 : 8;
        int y1 = dn ? (TILE_W - 1) : 7;
        for (x = 7; x <= 8; x++)
            for (y = y0; y <= y1; y++) buf[y * TILE_W + x] = PAL_LINE;
    }

    if (state == TILE_ST_BLACK || state == TILE_ST_WHITE) {
        /* 实心圆 + 左上高光。用 2x 整数坐标代替浮点（dx = x-7.5 ⇒ 2dx = 2x-15），
         * 这样不用链接 libm，且与 gen_tiles.py 的 float 版本逐像素等价。 */
        int color    = (state == TILE_ST_BLACK) ? PAL_BLACK : PAL_WHITE;
        int hi_color = (state == TILE_ST_BLACK) ? PAL_BLACK_HI : PAL_WHITE_EDGE;
        for (y = 0; y < TILE_W; y++) {
            for (x = 0; x < TILE_W; x++) {
                int dx = 2 * x - (TILE_W - 1);
                int dy = 2 * y - (TILE_W - 1);
                if (dx * dx + dy * dy <= 144) {          /* (2*STONE_R)^2 = 144 */
                    int hx = dx + 4, hy = dy + 4;        /* 高光圆心左/上偏 2px */
                    buf[y * TILE_W + x] = (uint8_t)((hx * hx + hy * hy <= 16) ? hi_color : color);
                }
            }
        }
    } else if (state == TILE_ST_CURSOR) {
        /* 空心圈：5.5..7 像素（不能挡中心，否则看不见底下的交叉点）*/
        for (y = 0; y < TILE_W; y++) {
            for (x = 0; x < TILE_W; x++) {
                int dx = 2 * x - (TILE_W - 1);
                int dy = 2 * y - (TILE_W - 1);
                int d2 = dx * dx + dy * dy;
                if (d2 >= 121 && d2 <= 196)              /* (2*5.5)^2 .. (2*7)^2 */
                    buf[y * TILE_W + x] = PAL_RED;
            }
        }
    }
}

/* ---------------------------------------------------------------------------
 * 对局 2x2 棋盘：32x32 格 → 4 个 16x16 象限
 * ---------------------------------------------------------------------------
 * 几何必须与 gen_tiles.py 的 make_cell32() 逐像素一致 —— 那边负责去重并生成
 * BOARD2_MAP/BOARD2_DESC/BOARD2_QUAD；这边按描述表重新合成唯一图块。
 * 这样 .rodata 只多一张 ~300B 的映射表，不会多出 62 x 256B 的像素表。
 * ------------------------------------------------------------------------- */
static void synth_cell32(uint8_t *buf, int shape, int state)
{
    const uint8_t *e = SHAPE_EDGES[shape];
    int up = e[0], dn = e[1], lf = e[2], rt = e[3];
    int i, x, y;

    for (i = 0; i < 32 * 32; i++) buf[i] = PAL_BG;

    /* 网格线 4px，中心行列 14..17；两端有线才画到边界 */
    if (lf || rt) {
        int x0 = lf ? 0 : 16;
        int x1 = rt ? 31 : 15;
        for (y = 14; y <= 17; y++)
            for (x = x0; x <= x1; x++) buf[y * 32 + x] = PAL_LINE;
    }
    if (up || dn) {
        int y0 = up ? 0 : 16;
        int y1 = dn ? 31 : 15;
        for (x = 14; x <= 17; x++)
            for (y = y0; y <= y1; y++) buf[y * 32 + x] = PAL_LINE;
    }

    if (state == 1 || state == 2) {                 /* 黑/白子，半径 12px */
        int color    = (state == 1) ? PAL_BLACK : PAL_WHITE;
        int hi_color = (state == 1) ? PAL_BLACK_HI : PAL_WHITE_EDGE;
        for (y = 0; y < 32; y++) {
            for (x = 0; x < 32; x++) {
                int dx = 2 * x - 31;
                int dy = 2 * y - 31;
                if (dx * dx + dy * dy <= 576) {      /* (2*12)^2 */
                    int hx = dx + 8, hy = dy + 8;     /* 高光偏移 4px */
                    buf[y * 32 + x] = (uint8_t)((hx * hx + hy * hy <= 64) ? hi_color : color);
                }
            }
        }
    } else if (state == 3) {
        /* 金色对焦角标（v2 §5.5.8），与 gen_tiles.py 的 make_cell32() 逐像素一致。 */
        int arm = 8, th = 3;
        for (y = 0; y < 32; y++) {
            for (x = 0; x < 32; x++) {
                int tl = (x >= 2 && x < 2 + arm && y >= 2 && y < 2 + th) ||
                         (x >= 2 && x < 2 + th && y >= 2 && y < 2 + arm);
                int tr = (x >= 32 - 2 - arm && x < 30 && y >= 2 && y < 2 + th) ||
                         (x >= 32 - 2 - th && x < 30 && y >= 2 && y < 2 + arm);
                int bl = (x >= 2 && x < 2 + arm && y >= 32 - 2 - th && y < 30) ||
                         (x >= 2 && x < 2 + th && y >= 32 - 2 - arm && y < 30);
                int br = (x >= 32 - 2 - arm && x < 30 && y >= 32 - 2 - th && y < 30) ||
                         (x >= 32 - 2 - th && x < 30 && y >= 32 - 2 - arm && y < 30);
                if (tl || tr || bl || br) buf[y * 32 + x] = PAL_GOLD;
            }
        }
    }
}

static void split_quad32(const uint8_t *cell, int q, uint8_t *out)
{
    int qy = q >> 1, qx = q & 1;
    int x, y;
    for (y = 0; y < 16; y++)
        for (x = 0; x < 16; x++)
            out[y * 16 + x] = cell[(qy * 16 + y) * 32 + qx * 16 + x];
}

/* 星位：内部空格的 4 个象限 + 中心 8x8 点 */
static void synth_star_cell32(uint8_t *buf)
{
    int x, y;
    synth_cell32(buf, 0, 0);
    for (y = 12; y <= 19; y++)
        for (x = 12; x <= 19; x++) buf[y * 32 + x] = PAL_LINE;
}

/* 最后一手标记不再单独画一张“木色底 + 红三角”的图块 —— 那会把棋子的右上
 * 四分之一整块擦成木色（2026-10-19 实拍：棋子缺右上角）。改在 render_init 里
 * 用真实棋子格（synth_cell32(shape=0, 黑/白)）叠红三角，只取右上象限。 */

void render_init(void)
{
    uint8_t  pal[TILE_N_PALETTE * 4];
    uint8_t  tile[TILE_BYTES];
    uint16_t i;

    /* ---- 调色板：24bit RGB 存成字（小端）⇒ 字节序 B,G,R,0 ---- */
    for (i = 0; i < TILE_N_PALETTE; i++) {
        uint32_t rgb = TILE_PALETTE[i];
        pal[i * 4 + 0] = (uint8_t)(rgb & 0xFF);          /* B */
        pal[i * 4 + 1] = (uint8_t)((rgb >> 8) & 0xFF);   /* G */
        pal[i * 4 + 2] = (uint8_t)((rgb >> 16) & 0xFF);  /* R */
        pal[i * 4 + 3] = 0;
    }
    vid_bulk_write(VID_REGION_PAL, 0, pal, (uint16_t)(TILE_N_PALETTE * 4));

    /* ---- 图块像素：36 块棋盘图块**运行时合成**（省 9,216 字节 .rodata，
     *      见上面 synth_board_tile 的说明）。 ---- */
    {
        int shape, state;
        for (shape = 0; shape < TILE_N_SHAPE; shape++) {
            for (state = 0; state < TILE_N_STATE; state++) {
                synth_board_tile(tile, shape, state);
                vid_bulk_write(VID_REGION_PAT,
                               (uint16_t)(TILE_OF(shape, state) * TILE_BYTES),
                               tile, (uint16_t)TILE_BYTES);
            }
        }
    }

    /* ---- 16x16 子集：5x7 放大 2x，写到 tile 36..72（T7 复用通用合成助手）----
     * [!] 图块是写进【显存】的；固件只存 37 x 7 字节的紧凑位图。 ---- */
    synth_glyph_set(0, (const uint8_t *)FONT_GLYPH, 0, FONT_TILE_BASE,
                    FONT_N_GLYPHS, FONT_FG, FONT_BG, 0);

    /* ---- 中文 3 字（87..89）：16x16 1bit，金色 ---- */
    {
        int g, x, y;
        for (g = 0; g < FONT_CJK_N; g++) {
            for (y = 0; y < TILE_W; y++) {
                for (x = 0; x < TILE_W; x++) {
                    int on = (FONT_CJK_BITS[g][y] >> (15 - x)) & 1u;
                    tile[y * TILE_W + x] = (uint8_t)(on ? PAL_GOLD : PAL_UI_BG);
                }
            }
            vid_bulk_write(VID_REGION_PAT,
                           (uint16_t)((FONT_CJK_TILE_BASE + g) * TILE_BYTES),
                           tile, (uint16_t)TILE_BYTES);
        }
    }

    /* ---- 8x8 提示子集（90..127，T7 补 '-','Z'）：8x7 按 1x 居中，暗灰 ----
     * [T6-R3] 字模生成器已拉宽到 8 位（FONT8_W）：字距 16-8=8px=字宽，
     * 消除 "P O W E R E D" 式的松散观感；笔画加粗（竖线 2px）。
     * [T7] 合成复用通用助手（连续编号模式）。 */
    synth_glyph_set(0, (const uint8_t *)FONT8_GLYPH, 0, FONT8_TILE_BASE,
                    FONT8_N_GLYPHS, FONT8_FG, FONT8_BG, 1);

    /* ---- 暗金 8x8 子集（17 字，POWERED 行专用）：8x7 1x 居中，暗金 ----
     * [T7] 合成逻辑与终端子集同构，复用 synth_glyph_set。 */
    synth_glyph_set_ord32(FONT8G_CHARS, (const uint8_t *)FONT8G_GLYPH,
                          FONT8G_TILE, FONT8G_N_GLYPHS,
                          FONT8G_FG, FONT8G_BG, 1);

    /* ---- 金色 / 绿色 16x16 子集：5x7 放大 2x，前景 PAL_GOLD / PAL_OK ----
     * [T6] 金色给 HUD 标题 GOMOKU、绿色给 THINKING。字形都在 16x16 主
     * 子集里（FONT_INDEX 有效），故直接复用 FONT_GLYPH 取位图。 */
    {
        int g, x, y;
        int ox = (TILE_W - FONT_W * FONT_SCALE) / 2;
        int oy = (TILE_W - FONT_H * FONT_SCALE) / 2;

        for (g = 0; g < FONT_GOLD16_N + FONT_GREEN16_N; g++) {
            int ch = (g < FONT_GOLD16_N) ? (int)(unsigned char)FONT_GOLD16_CHARS[g]
                                         : (int)(unsigned char)FONT_GREEN16_CHARS[g - FONT_GOLD16_N];
            int gi = (int)FONT_INDEX[ch - FONT_BASE];
            int fg = (g < FONT_GOLD16_N) ? (int)FONT_GOLD16_FG : (int)FONT_GREEN16_FG;
            int tn = (g < FONT_GOLD16_N) ? (int)FONT_GOLD16_TILE[ch - FONT_BASE]
                                         : (int)FONT_GREEN16_TILE[ch - FONT_BASE];
            if (gi < 0) continue;                 /* 防御：子集字符必须都在主子集里 */

            for (y = 0; y < TILE_W; y++) {
                for (x = 0; x < TILE_W; x++) {
                    int fx = glyph_coord(x, ox);
                    int fy = glyph_coord(y, oy);
                    uint8_t v = (uint8_t)FONT_BG;
                    if (fx >= 0 && fx < FONT_W && fy >= 0 && fy < FONT_H &&
                        ((FONT_GLYPH[gi][fy] >> (FONT_W - 1 - fx)) & 1u))
                        v = (uint8_t)fg;
                    tile[y * TILE_W + x] = v;
                }
            }
            put_pat((uint16_t)tn, tile);
        }
    }

    /* [T7] 标题中灰 8x8 子集已整集退役（痛点二后无使用者）—— 合成循环删除，
     * 图块号 129/130/146..149/178..179 释放为空闲（不再被任何路径写入）。 */

    /* ---- 绿色 WINS（131..134）：2x 字模，前景 PAL_OK ----
     * [T6-R2] 原 OK 绿字（129/130）回收：render_ok 无调用者。 */
    {
        static const char WINSCH[4] = { 'W', 'I', 'N', 'S' };
        int  k, x, y;
        int  ox = (TILE_W - FONT_W * FONT_SCALE) / 2;
        int  oy = (TILE_W - FONT_H * FONT_SCALE) / 2;

        for (k = 0; k < 4; k++) {
            const uint8_t *rows = glyph_rows(WINSCH[k]);
            for (y = 0; y < TILE_W; y++) {
                for (x = 0; x < TILE_W; x++) {
                    int fx = glyph_coord(x, ox);
                    int fy = glyph_coord(y, oy);
                    uint8_t v = (uint8_t)PAL_UI_BG;
                    if (fx >= 0 && fx < FONT_W && fy >= 0 && fy < FONT_H &&
                        ((rows[fy] >> (FONT_W - 1 - fx)) & 1u))
                        v = (uint8_t)PAL_OK;
                    tile[y * TILE_W + x] = v;
                }
            }
            vid_bulk_write(VID_REGION_PAT,
                           (uint16_t)((RENDER_TILE_WINS_BASE + k) * TILE_BYTES),
                           tile, (uint16_t)TILE_BYTES);
        }
    }

    /* ---- 外框 / 棋子图标（150..153） ---- */
    synth_frame_h(tile);
    vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_FRAME_H * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
    synth_frame_v(tile);
    vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_FRAME_V * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
    synth_icon(tile, PAL_BLACK, PAL_BLACK_HI);
    vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_ICON_BLACK * TILE_BYTES), tile, (uint16_t)TILE_BYTES);
    synth_icon(tile, PAL_WHITE, PAL_WHITE_EDGE);
    vid_bulk_write(VID_REGION_PAT, (uint16_t)(RENDER_TILE_ICON_WHITE * TILE_BYTES), tile, (uint16_t)TILE_BYTES);

    /* ---- 标题屏装饰（编号 154..186，运行时合成）---- */
    {
        /* 4x 大 logo："GOMOKU"，两个 O 换成黑/白棋子（第 2 个字母黑、第 4 个白）。 */
        static const char LOGO[] = "GOMOKU";
        int gi, qx, qy;

        for (gi = 0; gi < 6; gi++) {
            int stone = 0;
            if (LOGO[gi] == 'O') stone = (gi == 1) ? 1 : 2;
            for (qy = 0; qy < RENDER_LOGO_TILE_H; qy++) {
                for (qx = 0; qx < RENDER_LOGO_TILE_W; qx++) {
                    synth_logo_tile(tile, LOGO[gi], stone, qx, qy);
                    put_pat((uint16_t)(RENDER_TILE_LOGO_BASE + gi * 4 + qy * 2 + qx), tile);
                }
            }
        }

        synth_rule(tile);
        put_pat((uint16_t)RENDER_TILE_RULE, tile);

        synth_arrow(tile);
        put_pat((uint16_t)RENDER_TILE_ARROW, tile);

        synth_faint_rule(tile);
        put_pat((uint16_t)RENDER_TILE_FAINT_RULE, tile);

        synth_desc_arrow(tile);
        put_pat((uint16_t)RENDER_TILE_DESC_ARROW, tile);
    }

    /* ---- 对局 2x2 棋盘象限（188..249，运行时合成）----
     * [!] cell32 用**栈**（1KB），不要 static：render_init 只在上电跑一次，
     *     跑完就返回；放 .bss 会白白吃掉 1KB 堆（RT-Thread 启动时 heap 只有几 KB）。 */
    {
        uint8_t cell32[32 * 32];
        uint8_t quad[TILE_BYTES];
        int i, q, x, y;

        for (i = 0; i < BOARD2_N_UNIQUE; i++) {
            int desc = BOARD2_DESC[i];
            synth_cell32(cell32, desc >> 2, desc & 3);
            split_quad32(cell32, BOARD2_QUAD[i], quad);
            put_pat((uint16_t)(RENDER_TILE_BOARD2_BASE + i), quad);
        }

        synth_star_cell32(cell32);
        for (q = 0; q < 4; q++) {
            split_quad32(cell32, q, quad);
            put_pat((uint16_t)(RENDER_TILE_BOARD2_STAR + q), quad);
        }

        /* 最后一手：黑/白各一张。用真实棋子格做底，只把右上角的红三角
         * 盖上去，棋子右上边缘完整保留（旧版整块木色会擦掉四分之一）。 */
        for (i = 1; i <= 2; i++) {
            synth_cell32(cell32, 0, i);          /* 1=黑 2=白，内部格 */
            for (y = 0; y < 6; y++)
                for (x = 26 + y; x < 32; x++)
                    cell32[y * 32 + x] = PAL_RED;
            split_quad32(cell32, 1, quad);       /* 右上象限 */
            put_pat((uint16_t)((i == 1) ? RENDER_TILE_BOARD2_LAST
                                        : RENDER_TILE_BOARD2_LAST_W), quad);
        }
    }

    /* ---- 标题屏顶部/底部细带：16x16 纯色 ---- */
    {
        int i;
        for (i = 0; i < TILE_BYTES; i++) tile[i] = PAL_UI_BAND;
        put_pat((uint16_t)RENDER_TILE_BG_BAND, tile);
    }
}

/* ---------------------------------------------------------------------------
 * 标题屏绘制原语（只写 nametable，图块在 render_init 已经合成好）
 * ------------------------------------------------------------------------- */
void render_logo(int row, int col)
{
    uint8_t line[RENDER_LOGO_TILE_W * 6];
    int i, half;

    /* 一行 12 格 = 6 个字母 × 每字 2 格；qy=half 决定取上半还是下半图块。 */
    for (half = 0; half < RENDER_LOGO_TILE_H; half++) {
        for (i = 0; i < 6 * RENDER_LOGO_TILE_W; i++)
            line[i] = (uint8_t)(RENDER_TILE_LOGO_BASE + (i / RENDER_LOGO_TILE_W) * 4
                                + half * RENDER_LOGO_TILE_W + (i % RENDER_LOGO_TILE_W));
        vid_bulk_write(VID_REGION_NT, (uint16_t)((row + half) * 256 + col),
                       line, (uint16_t)sizeof(line));
    }
}

void render_rule(int row, int col, int len)
{
    uint8_t line[SCREEN_COLS];
    int i;
    if (len > SCREEN_COLS) len = SCREEN_COLS;
    for (i = 0; i < len; i++) line[i] = (uint8_t)RENDER_TILE_RULE;
    vid_bulk_write(VID_REGION_NT, (uint16_t)(row * 256 + col), line, (uint16_t)len);
}

