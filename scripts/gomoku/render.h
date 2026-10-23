/* ============================================================================
 * render.h —— 五子棋渲染层（轨道 A3）
 * ----------------------------------------------------------------------------
 * 干什么：把"棋盘 + 棋子 + 光标"翻译成**显存里的字节**。它不碰 RTL、不碰 PPU，
 *         只按 addr_map 的约定写三块显存：
 *             nametable  = 每格放哪个图块号（8KB，字节寻址 r*256+c）
 *             pattern    = 每个图块的 16x16 像素（64KB，字节寻址 T*256+py*16+px）
 *             palette    = 256 项 24bit RGB（1KB，字寻址 i*4）
 *
 * [!] 关键约束（来自显示硬件的现状）：**没有精灵层**。
 *     所以"光标"不是叠上去的，而是**换图块** —— 把那一格换成"带光标的图块"。
 *     同理棋子也是烤进图块的。因此：
 *         移动光标 = 写 2 个字节（旧格换回普通、新格换成光标）
 *         落子     = 写 1 个字节
 *     这也是本模块存在的意义：把"该换成哪一块"这件事集中到一处，
 *     免得棋盘逻辑里散落一堆 tile 号算术。
 *
 * 平台无关：唯一的外部依赖是 vid_bulk_write()，固件侧是 MMIO、x86 测试侧是假数组，
 *          所以 render.c 两边跑同一份（见 test_render.c）。
 * ==========================================================================*/
#ifndef GOMOKU_RENDER_H
#define GOMOKU_RENDER_H

#include <stdint.h>
#include "board.h"
#include "board2_map.h"   /* gen_tiles.py 生成的 2x2 棋盘象限映射（只读表，~300B） */

/* ---- 显存分区（vid_bulk_write 的 region 参数）---- */
#define VID_REGION_NT   0
#define VID_REGION_PAT  1
#define VID_REGION_PAL  2

/* 由【平台】实现：把 len 个字节写进显存对应分区的 offset 处。
 *   固件侧  -> MMIO 直写（scripts/gomoku/video_port.c）
 *   x86 测试 -> 写进假 VRAM 数组（test_render.c）
 * 这是本模块唯一的平台依赖 —— 有了它，render.c 才能在 PC 上被逐字节验证。 */
void vid_bulk_write(uint8_t region, uint16_t offset, const uint8_t *data, uint16_t len);

/* ---- 棋盘在屏幕上的位置 ----------------------------------------------------
 * 屏幕是 40 列 × 30 行图块（640×480 像素）。15×15 的棋盘居中：
 *   列起点 (40-15)/2 = 12，行起点 (30-15)/2 = 7
 * 剩下的边角留给 HUD。scroll 保持 0（棋类是静态的，不需要滚动）。 */
#define SCREEN_COLS  40
#define SCREEN_ROWS  30
#define BOARD_COL0   ((SCREEN_COLS - GOMOKU_N) / 2)   /* 12 */
#define BOARD_ROW0   ((SCREEN_ROWS - GOMOKU_N) / 2)   /* 7  */

/* ---- 图块编号：必须与 gen_tiles.py 的 TILE_OF 一致 ---- */
#define RENDER_SHAPE_N   9
#define RENDER_TILE(shape, state)  ((uint8_t)((shape) * 4 + (state)))
#define RENDER_ST_EMPTY   0
#define RENDER_ST_BLACK   1
#define RENDER_ST_WHITE   2
#define RENDER_ST_CURSOR  3

/* ---- 2026-10-19 T6-R2：图块编号重整 ----------------------------------------
 *   36..72    16x16 UI 子集（37 字，font.h；J/Q/X/Z 与 11 个零使用符号已回收）
 *   73..86    暗金 8x8（POWERED 行 14 字，font.h）
 *   87..89    中文 3 字 五/子/棋（font.h）
 *   90..126   8x8 提示子集（37 字，font.h，暗灰；Z/- 已回收，F 保留给 LEFT）
 *   127/128   暗金 8x8（POWERED 行）
 *   129/130   标题中灰 8x8（AHIMNSUV 前 2 字，font.h，前景 PAL_UI_MID）
 *   131..134  绿色 WINS（W/I/N/S；原绿色 OK 已回收——弹窗 WINS 独用）
 *   135..140  绿色 16x16（THINGK，HUD THINKING，font.h）
 *   141..145  金色 16x16（GOMKU，HUD 标题，font.h）
 *   146..149 / 178/179  标题中灰 8x8（后 6 字）
 *   150/151   外框横/竖线
 *   152/153   黑/白子图标
 *   154..177  4x 大 logo
 *   180..185  空闲
 *   186       金色分隔线
 *   187       金色右三角
 *   188..249  对局 2x2 棋盘（57 象限 + 4 星位 + 黑子最后一手）
 *   250       标题屏顶部/底部细带
 *   251       暗金 8x8（POWERED 行）
 *   252       白子最后一手
 *   253       极暗分隔线（1px）
 *   254       暗金说明锚点 >
 * 180..185 空闲；255 为测试哨兵（不得写入）。
 * -------------------------------------------------------------------------- */
#define RENDER_TILE_FRAME_H    150   /* 外框横线 */
#define RENDER_TILE_FRAME_V    151   /* 外框竖线 */
#define RENDER_TILE_ICON_BLACK 152   /* 纯底黑子图标 */
#define RENDER_TILE_ICON_WHITE 153   /* 纯底白子图标 */

#define RENDER_TILE_LOGO_BASE  154
#define RENDER_TILE_RULE       186
#define RENDER_TILE_ARROW      187   /* 金色右三角：选中项左侧的选择标记 */
#define RENDER_TILE_WINS_BASE  131   /* W/I/N/S 绿字（131..134） */

/* ---- 对局 2x2 棋盘（2026-10-18）：每格 32x32，拆 4 个 16x16 象限 ----
 * 去重后 BOARD2_N_UNIQUE 块（当前 57），编号接在 188；
 * 星位 4 块；最后一手黑/白 2 块（249 黑 / 252 白）。
 * 全部在 render_init 里运行时合成，不占 .rodata。 */
#define RENDER_TILE_BOARD2_BASE 188
#define RENDER_TILE_BOARD2_STAR (RENDER_TILE_BOARD2_BASE + BOARD2_N_UNIQUE)
#define RENDER_TILE_BOARD2_LAST (RENDER_TILE_BOARD2_STAR + 4)
#define RENDER_TILE_BOARD2_LAST_W 252  /* 白子最后一手（72 已被 16x16 主字库占用） */
#define RENDER_TILE_BG_BAND     250   /* 标题屏顶部/底部细带（纯色 16x16） */
#define RENDER_TILE_FAINT_RULE  253   /* 极暗分隔线（1px） */
#define RENDER_TILE_DESC_ARROW  254   /* 暗金说明锚点 > */

/* ---- CoreMark 终端演示屏（GAME_COREMARK，T7 2026-10-19）--------------------
 * 「借图块」策略：终端屏需要 亮绿/亮金 字形与实心块，256 个图块号只剩个位数
 * 空闲 —— 不够。演示屏是独占屏，借主（4x logo、WINS、中文、GOMOKU、THINKING
 * 的前两块）在它显示期间都不在屏上，所以 render_term_begin() 把终端字形直接
 * 合成进借主的图块号；render_term_end() 调 render_init() 一次性全量恢复。
 * [!] begin/end 必须配对（coremark_screen.c 负责时序），否则标题屏会花。
 * [!] begin 会把调色板 7（UI 底）临时换成纯黑 —— 全部字库图块的底跟着变黑，
 *     这正是终端风要的纯黑背景；字形前景不变。 */
#define RENDER_TILE_TERM_FILL   135   /* 进度条填充：亮绿实心块（借 THINKING 的 T） */
#define RENDER_TILE_TERM_TRACK  136   /* 进度条空轨：极暗实心块（借 THINKING 的 H） */
/* 8x8 终端小子的借图块号（与 gen_tiles.py 的 TERM_GREEN8/GRAY8 表一致）。
 * 直接给常量而不用 FONT_TERM_*_TILE 表：这些表只为 2~3 个字生成，
 * 一旦被 term_span 当指针传就会在 coremark_screen.o 里整份驻留 95B。 */
#define RENDER_TILE_TERM_OK_O   143   /* 绿 O（GOMKU 第 2 块） */
#define RENDER_TILE_TERM_OK_K   144   /* 绿 K */
#define RENDER_TILE_TERM_PCT    145   /* 灰 %（GOMKU 末块） */

/* 终端借图块查询：生成侧表是 **ord(ch)-FONT_BASE**（0..94）索引，别按 ASCII
 * 原值直接下标（那会整体错位 32 格）。返回 0xFF = 该子集没有这个字符。 */
#define RENDER_TERM_SET_GREEN16 0
#define RENDER_TERM_SET_GOLD16  1
#define RENDER_TERM_SET_GREEN8  2   /* 监控区数值：0-9 . K S E C，8x8 亮绿 */
uint8_t render_term_tile(int set, char ch);

void render_term_begin(void);
void render_term_end(void);
#define RENDER_TILE_MAX         255   /* 0..254 已用，255 空闲 */
typedef char render_tile_budget_assert[(RENDER_TILE_MAX <= 256) ? 1 : -1];

/* 大 logo 的几何：字模 5x7 放大 4 倍 = 20x28 像素，占 2x2 个图块（32x32）。 */
#define RENDER_LOGO_SCALE      4
#define RENDER_LOGO_TILE_W     2
#define RENDER_LOGO_TILE_H     2

/* 交叉点 (r,c) 的网格线形状（0..8）—— 由"四条边有没有线"决定，见 gen_tiles.py */
uint8_t render_shape(int r, int c);

/* (r,c) 该显示哪一块图块。光标位置用 (cr,cc) 传，(-1,-1) 表示没有光标。
 * **光标的优先级高于棋子** —— 光标只在空交叉点上（落子合法性已经保证），
 * 所以正常情况下两者不会同时出现在一格。 */
uint8_t render_tile_for(const gomoku_t *g, int r, int c, int cr, int cc);

/* 上电调一次：把调色板 + 全部图块（棋盘/字库/中文/8x8/绿字/装饰/2x2）写进显存。
 * [!] 显存上电是**随机内容**，不调这个函数屏幕上就是雪花。 */
void render_init(void);

/* 铺满整张棋盘（含光标）。落子/悔棋后直接全刷最省事：225 字节，
 * 在 62MHz 上就是几十微秒，比维护增量状态可靠得多。 */
void render_full(const gomoku_t *g, int cr, int cc);

/* 对局屏专用：15x15 格 × 2x2 tile = 30x30 tile = 480x480，原点 (0,0)。
 * 每格写 4 个 nametable 字节；右侧 30..39 列留给 HUD。
 * 标题屏的小棋盘仍用 render_board_region()（16x16 一格）。 */
void render_full2(const gomoku_t *g, int cr, int cc);

/* 只重画一格 —— 光标移动时用它，省掉一次全刷 */
void render_cell(const gomoku_t *g, int r, int c, int cr, int cc);

/* 移动光标：只写 2 个字节（旧格重画成普通，新格画成带光标） */
void render_move_cursor(const gomoku_t *g, int oldr, int oldc, int newr, int newc);

/* 清屏成纯底色（用【空格字模】铺满）。标题画面之前调一次。
 * 空格字模是 16x16 的纯底色图块 —— 比原来的"内部形状空格"干净，
 * 后者带网格线，会让 HUD 留白区看起来像网格底。 */
void render_clear(void);

/* ---- HUD 文字 ----
 * 字库见 font.h：render_init() 已把紧凑 5x7 位图放大成 16x16 图块写到
 * tile FONT_TILE_BASE .. FONT_TILE_BASE+FONT_N_GLYPHS-1。这里按【绝对】屏幕
 * 行/列（0..29 / 0..39）写 nametable。小写自动折叠到大写，未定义字符落空格。 */
void render_text(int row, int col, const char *s);

/* 同一行水平居中写一段文字。 */
void render_text_center(int row, const char *s);

/* 只写这几个格子，**不铺整行**。给"和其他内容共享同一行"的短标签用：
 * 标题屏的 "AI VS AI"、LAST COREMARK 三行 —— 用 render_text 会把整行铺成空格，
 * 把同一行上的选中框/说明行抹掉。 */
void render_text_span(int row, int col, const char *s);

/* ---- 8x8 提示文字（灰）----------------------------------------------------
 * 字库见 font.h 的 FONT8_*：一个字符一块 16x16，字模 5x7 按 1x 居中。
 * 只写实际字符，不铺整行；调用方先用 render_clear_span() 清出区域。 */
void render_text8_span(int row, int col, const char *s);
void render_text8_center(int row, const char *s);

/* ---- 暗金 8x8（标题屏 POWERED 行专用子集，font.h 的 FONT8G_*）----
 * 几何与 8x8 提示字库相同，前景是暗金（PAL_GOLD_DIM）；
 * 子集只有 17 个字形，其它字符（含空格）落灰色空格图块（纯底，颜色无关）。 */
void render_text8g_span(int row, int col, const char *s);
void render_text8g_center(int row, const char *s);

/* [T7] 标题中灰 8x8（render_text_tgray_* / FONT_TITLE_GRAY_*）已整集退役：
 * 痛点二把二级菜单大标题改用 render_text_center（16x16 亮白）后无使用者；
 * 图块号 129/130/146..149/178..179 释放为空闲。 */

/* ---- 金色 16x16（HUD 标题）/ 绿色 16x16（HUD THINKING）----
 * 同 16x16 字库几何（5x7 放大 2x），前景分别是 PAL_GOLD / PAL_OK。
 * 子集见 font.h 的 FONT_GOLD16_* / FONT_GREEN16_*；未收录字符落暖白空格图块。 */
void render_gold16_span(int row, int col, const char *s);
void render_green16_span(int row, int col, const char *s);

/* 极暗分隔线：横画 len 块，颜色只比 UI 底亮一丁点。 */
void render_faint_rule(int row, int col, int len);

/* 暗金说明锚点：一个 8x8 的 '>'，放在说明行左侧。 */
void render_desc_arrow(int row, int col);

/* 清一段（row, col..col+n-1）为纯底色（16x16 空格图块）。
 * HUD 只用 30..39 列，标题菜单只用 0..26 列 —— 不能用 render_text 整行清，
 * 那会把左侧棋盘/右侧小棋盘一起抹掉。 */
void render_clear_span(int row, int col, int n);

/* ---- 中文 3 字（16x16 金色）----------------------------------------------
 * 只支持 五(0x4E94) / 子(0x5B50) / 棋(0x68CB)；其它码点忽略。 */
#define RENDER_CJK_WU  0x4E94
#define RENDER_CJK_ZI  0x5B50
#define RENDER_CJK_QI  0x68CB
void render_cjk(int row, int col, int code);

/* ---- 绿色 WINS（胜负弹窗）-------------------------------------------------
 * [T6-R2] 原 OK 绿字（O/K，129/130 块）回收：LAST COREMARK 区的 CRC 状态
 * 改用 8x8 文字渲染后 render_ok 再无调用者；129/130 让给标题中灰子集。 */
void render_wins(int row, int col);     /* 写 4 格：W I N S */

/* 写一个 nametable 字节（【绝对】行/列 0..29 / 0..39）。给 HUD 图标、坐标轴用。 */
void render_put(int row, int col, uint8_t tile);

/* ---- 标题屏专用（2026-10-18）--------------------------------------------
 * 这几个函数只被标题屏用；对局画面一个都不调，所以"对局不受影响"是结构性的。 */

/* 画 4x 大 logo "GOMOKU"：从 (row,col) 起占 2 行 × 12 列的图块区。
 * 两个 "O" 画成黑/白棋子（黑在前、白在后），带深色投影。图块已在 render_init 合成。 */
void render_logo(int row, int col);

/* 画一条金色分隔线（1 行 × len 个图块）。 */
void render_rule(int row, int col, int len);

/* 只画棋盘的某个子区域（r0/c0 起 rows×cols 个交叉点），落到屏幕上
 * (sr,sc) 起的图块区。标题屏右侧的 5x5 自动对弈小棋盘用它；
 * **不画光标、不画星位、不画最后一手标记**（小盘只要素净的棋子）。 */
void render_board_region(const gomoku_t *g, int r0, int c0, int rows, int cols,
                         int sr, int sc);

/* 在 (r0,c0) 起画一个 n×n 交叉点的棋盘外框（四角复用棋盘边角图块）。
 * 标题屏 5x5 小棋盘用它。 */
void render_frame_at(int r0, int c0, int n);

#endif /* GOMOKU_RENDER_H */
