/* ============================================================================
 * test_board.c —— 轨道 C 的 x86 单测（只在 PC 上跑，不进固件）
 * ----------------------------------------------------------------------------
 * 编译运行：  scripts\gomoku\run_test.ps1
 * 或手动：    gcc -std=c99 -O2 -Wall -Wextra board.c test_board.c -o test_board.exe && test_board.exe
 *
 * 为什么值得写：工作清单 §6 明说"C 轨道的判胜是安全的，建议用 gcc 在 x86 上把核心
 * 函数先单测透（横/竖/两斜/贴边/满盘平局/反向连子），再上板"。而且没板子也能推进。
 *
 * [!] 落子序列一律用 MV(...) 宏写，它自己算数组长度 —— 早先版本的 place_seq
 *     要手动数"几手"，写这个测试时连错了 10 处，每处都只落了一半的棋。
 *     教训：这种"必须人肉数对"的接口不该出现在测试里。
 * ==========================================================================*/
#include <stdio.h>
#include "board.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                            \
    do {                                                            \
        if (cond) { g_pass++; }                                     \
        else {                                                      \
            g_fail++;                                               \
            printf("  [FAIL] %s:%d  %s\n", __FILE__, __LINE__, msg); \
        }                                                           \
    } while (0)

/* 落子序列：写成 MV(r0,c0, r1,c1, ...)，长度由宏算出来。 */
#define MV(...)  (const int[]){ __VA_ARGS__ }, (int)(sizeof((const int[]){ __VA_ARGS__ }) / sizeof(int))

/* 按顺序落子，颜色由 g->turn 自动黑白交替。全部成功返回 GOMOKU_OK，
 * 否则返回第一个失败那手的错误码（此时棋盘停在那一手之前的状态）。 */
static int place_seq(gomoku_t *g, const int *rc, int n_ints)
{
    int i;
    for (i = 0; i + 1 < n_ints; i += 2) {
        int ret = gomoku_place(g, rc[i], rc[i + 1]);
        if (ret != GOMOKU_OK) return ret;
    }
    return GOMOKU_OK;
}

/* ---------------------------------------------------------------------------
 * A. 基本状态
 * ------------------------------------------------------------------------- */
static void test_reset(void)
{
    gomoku_t g;
    int r, c, all_empty = 1;

    printf("---- A. reset 后的初始状态 ----\n");
    gomoku_reset(&g);

    CHECK(g.turn == GOMOKU_BLACK,  "黑先");
    CHECK(g.stones == 0,           "stones 应为 0");
    CHECK(g.winner == 0,           "winner 应为 0");
    CHECK(gomoku_is_full(&g) == 0, "不应是满盘");
    CHECK((int)g.last_r == -1,     "last_r 应为 -1（还没落过子）");
    CHECK((int)g.last_c == -1,     "last_c 应为 -1");

    for (r = 0; r < GOMOKU_N; r++)
        for (c = 0; c < GOMOKU_N; c++)
            if (g.cell[r][c] != GOMOKU_EMPTY) all_empty = 0;
    CHECK(all_empty, "全盘应为空");
}

/* ---------------------------------------------------------------------------
 * B. 四个方向各一条五连（黑胜）
 * ------------------------------------------------------------------------- */
static void test_win_directions(void)
{
    gomoku_t g;

    printf("---- B. 四个方向成五（黑胜）----\n");

    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  0,2,  7,6,  0,3,  7,7)) == GOMOKU_OK,
          "横：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "横：黑应胜");
    CHECK(g.run_len >= 5,           "横：run_len 应 >= 5");
    CHECK(g.last_r == 7 && g.last_c == 7, "横：最后一手应在 (7,7)");

    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 3,7,  0,0,  4,7,  0,1,  5,7,  0,2,  6,7,  0,3,  7,7)) == GOMOKU_OK,
          "竖：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "竖：黑应胜");

    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 3,3,  0,0,  4,4,  0,1,  5,5,  0,2,  6,6,  0,3,  7,7)) == GOMOKU_OK,
          "斜\\：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "斜\\：黑应胜");

    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 3,11, 0,0,  4,10, 0,1,  5,9,  0,2,  6,8,  0,3,  7,7)) == GOMOKU_OK,
          "斜/：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "斜/：黑应胜");
}

/* 反向连子：决定性的那一手在**左端**，连子往右延伸。
 * 这条专门抓"只往正方向数"的实现 bug。 */
static void test_reverse_order_win(void)
{
    gomoku_t g;
    printf("---- B2. 反向连子（最后落左端，连子往右）----\n");
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,7,  0,0,  7,6,  0,1,  7,5,  0,2,  7,4,  0,3,  7,3)) == GOMOKU_OK,
          "落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "黑应胜");
    CHECK(g.last_c == 3,            "最后一手应在 (7,3)");
    CHECK(g.run_len == 5,           "run_len 应恰好 5");
}

/* ---------------------------------------------------------------------------
 * C. 贴边 / 贴角
 * ------------------------------------------------------------------------- */
static void test_edges(void)
{
    gomoku_t g;

    printf("---- C. 贴边与贴角 ----\n");

    /* 第 0 行横五，同时贴左上角 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 0,0, 14,14,  0,1, 14,13,  0,2, 14,12,  0,3, 14,11,  0,4)) == GOMOKU_OK,
          "贴左上角：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "贴左上角横五：黑应胜");

    /* 最后一列竖五 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 0,14, 7,0,  1,14, 7,1,  2,14, 7,2,  3,14, 7,3,  4,14)) == GOMOKU_OK,
          "贴右边界：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "贴右边界竖五：黑应胜");

    /* 贴着右下角的斜 "\" */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 10,10, 0,0,  11,11, 0,1,  12,12, 0,2,  13,13, 0,3,  14,14)) == GOMOKU_OK,
          "贴右下角：落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK, "贴右下角斜五：黑应胜");
}

/* ---------------------------------------------------------------------------
 * D. 反向用例：**不该**判胜的情形
 * ------------------------------------------------------------------------- */
static void test_not_win(void)
{
    gomoku_t g;

    printf("---- D. 不该判胜的情形 ----\n");

    /* 只有四连 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  0,2,  7,6,  0,3)) == GOMOKU_OK,
          "四连：落子应全成功");
    CHECK(g.winner == 0,  "四连不该判胜");
    CHECK(g.run_len == 4, "run_len 应为 4");

    /* 被对方隔断：黑 7,3 7,4 7,5 _ 7,7，白占 7,6 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  7,6,  7,7,  0,2)) == GOMOKU_OK,
          "隔断：落子应全成功");
    CHECK(g.winner == 0, "被隔断不该判胜");
    CHECK(gomoku_run_len(&g, 7, 3, GOMOKU_BLACK) == 3, "断点左侧应只有 3 连");

    /* 五连中间被对方夹一个子：黑 7,3 7,4 _ 7,6 7,7，白占 7,5 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  7,5,  7,6,  0,1,  7,7,  0,2)) == GOMOKU_OK,
          "夹子：落子应全成功");
    CHECK(g.winner == 0, "被夹住的两段都不该判胜");
    CHECK(gomoku_run_len(&g, 7, 6, GOMOKU_BLACK) == 2, "右侧一段应只有 2 连");
}

/* 长连：五连判胜后就不再接受落子；单看 run_len 时 6 连能数得出来。 */
static void test_long_run(void)
{
    gomoku_t g;
    int i;

    printf("---- D2. 长连（6 子）也算胜 ----\n");

    /* 正常路径：第 5 颗黑子落下即判胜，第 6 颗被拒 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  0,2,  7,6,  0,3,  7,7)) == GOMOKU_OK,
          "落子应全成功");
    CHECK(g.winner == GOMOKU_BLACK,                  "第 5 子时就应判胜");
    CHECK(gomoku_place(&g, 7, 8) == GOMOKU_ERR_OVER, "胜负已分后应拒绝落子");

    /* 白盒：直接铺 6 颗黑子，验证 run_len 数得出 6（>=5 依然算胜） */
    gomoku_reset(&g);
    for (i = 3; i <= 8; i++) g.cell[7][i] = GOMOKU_BLACK;
    CHECK(gomoku_run_len(&g, 7, 4, GOMOKU_BLACK) == 6, "6 连应数得出 6");
    CHECK(gomoku_scan_winner(&g) == GOMOKU_BLACK,      "全盘扫描也应判黑胜");
}

/* ---------------------------------------------------------------------------
 * E. 非法落子：必须被拒且**不改动任何状态**
 * ------------------------------------------------------------------------- */
static void test_illegal(void)
{
    gomoku_t g, before;

    printf("---- E. 非法落子 ----\n");

    gomoku_reset(&g);
    CHECK(gomoku_place(&g, 7, 7) == GOMOKU_OK, "黑应能落在 (7,7)");

    CHECK(gomoku_place(&g, -1, 7) == GOMOKU_ERR_RANGE, "负坐标应被拒");
    CHECK(gomoku_place(&g, 7, 15) == GOMOKU_ERR_RANGE, "越上界应被拒");
    CHECK(gomoku_place(&g, 15, 7) == GOMOKU_ERR_RANGE, "越下界应被拒");

    before = g;
    CHECK(gomoku_place(&g, 7, 7) == GOMOKU_ERR_OCCUPIED, "重复落子应被拒");
    CHECK(g.stones == before.stones,                     "被拒后 stones 不应变");
    CHECK(g.turn   == before.turn,                       "被拒后 turn 不应变");
    CHECK(g.last_r == before.last_r && g.last_c == before.last_c,
          "被拒后 last_* 不应变");

    CHECK(g.turn == GOMOKU_WHITE,                          "黑走完应轮到白");
    CHECK(gomoku_place(&g, 7, 8) == GOMOKU_OK,             "白应能落子");
    CHECK(g.turn == GOMOKU_BLACK,                          "白走完应轮到黑");
    CHECK(g.stones == 2,                                   "应有 2 个子");
}

/* ---------------------------------------------------------------------------
 * F. gomoku_run_len 是"只读"的（AI 会大量调用它来假想落子）
 * ------------------------------------------------------------------------- */
static void test_run_len_is_readonly(void)
{
    gomoku_t g, before;

    printf("---- F. gomoku_run_len 不改变状态 ----\n");

    /* 黑 7,6 7,7 7,8 7,9 四连（差一颗成五） */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,6,  0,0,  7,7,  0,1,  7,8,  0,2,  7,9)) == GOMOKU_OK,
          "摆四连应成功");
    CHECK(g.winner == 0, "四连还没胜");

    before = g;
    CHECK(gomoku_run_len(&g, 7, 10, GOMOKU_BLACK) == 5, "假想 (7,10) 黑应连成 5");
    CHECK(gomoku_run_len(&g, 7, 5,  GOMOKU_BLACK) == 5, "假想 (7,5) 黑也应连成 5");
    CHECK(gomoku_run_len(&g, 7, 10, GOMOKU_WHITE) == 1, "假想 (7,10) 白只能连 1（被隔）");
    CHECK(gomoku_run_len(&g, 7, 6,  GOMOKU_WHITE) == 0, "对方子的点对白是 0");
    CHECK(gomoku_run_len(&g, 7, 6,  GOMOKU_BLACK) == 4, "己方子的点按己方算，应连 4");
    CHECK(gomoku_run_len(&g, -1, 0, GOMOKU_BLACK) == 0, "越界返回 0");
    CHECK(g.cell[7][10] == GOMOKU_EMPTY,                "(7,10) 应仍是空的");
    CHECK(g.stones == before.stones && g.turn == before.turn, "状态不应变");
}

/* ---------------------------------------------------------------------------
 * G. 满盘平局
 * ------------------------------------------------------------------------- */
static void test_draw(void)
{
    gomoku_t g;
    int r, c, i;
    static int mv[GOMOKU_N * GOMOKU_N * 2];
    int nb = 0, nw = 0, wstart;

    printf("---- G. 满盘平局 ----\n");

    /* 构造一个四个方向都没有五连的填法：color = ((r + 2c) & 3) < 2 ? 黑 : 白。
     * 逐方向验算（模 4 的周期）：
     *   横：c 每 +1 -> 值在 r%4 与 (r+2)%4 之间交替，一黑一白 -> 最长 1
     *   竖：r 每 +1 -> 模 4 递增 -> 黑黑白白 -> 最长 2
     *   斜\：r+2c 每步 +3（≡ -1）-> 最长 2
     *   斜/：r+2c 每步 -1         -> 最长 2
     * 所以整个盘面无五连，是真正的平局。黑白数量 113 : 112，
     * 正好黑先、逐手交替填得进去。 */
    for (r = 0; r < GOMOKU_N; r++) {
        for (c = 0; c < GOMOKU_N; c++) {
            if (((r + 2 * c) & 3) < 2) {
                mv[nb * 2 + 0] = r;
                mv[nb * 2 + 1] = c;
                nb++;
            }
        }
    }
    wstart = nb;
    for (r = 0; r < GOMOKU_N; r++) {
        for (c = 0; c < GOMOKU_N; c++) {
            if (((r + 2 * c) & 3) >= 2) {
                mv[wstart * 2 + nw * 2 + 0] = r;
                mv[wstart * 2 + nw * 2 + 1] = c;
                nw++;
            }
        }
    }
    CHECK(nb == 113 && nw == 112, "填法应给出 113 黑 / 112 白");

    gomoku_reset(&g);
    for (i = 0; i < nb + nw; i++) {
        int idx = (i % 2 == 0) ? (i / 2) : (nb + i / 2);
        int ret = gomoku_place(&g, mv[idx * 2], mv[idx * 2 + 1]);
        if (ret != GOMOKU_OK) {
            g_fail++;
            printf("  [FAIL] 平局填充第 %d 手失败 ret=%d\n", i, ret);
            return;
        }
    }

    CHECK(gomoku_is_full(&g),                "应已满盘");
    CHECK(g.stones == GOMOKU_N * GOMOKU_N,   "stones 应为 225");
    CHECK(g.winner == 0,                     "满盘平局不应有胜方");
    CHECK(gomoku_scan_winner(&g) == 0,       "全盘扫描也不应找到胜方");
    CHECK(gomoku_place(&g, 0, 0) == GOMOKU_ERR_OCCUPIED, "满盘后无处可下");
}

/* ---------------------------------------------------------------------------
 * H. 【最重要】增量判胜 vs 全盘扫描，随机对局逐步对拍
 * ------------------------------------------------------------------------- */
static uint32_t lcg_state = 12345u;
static uint32_t lcg(void)
{
    lcg_state = lcg_state * 1103515245u + 12345u;
    return (lcg_state >> 16) & 0x7fffu;
}

static void test_cross_check_random(void)
{
    int game;
    long total_moves = 0;
    int wins = 0, draws = 0;

    printf("---- H. 随机对局：增量判胜 vs 全盘扫描 逐步对拍 ----\n");

    for (game = 0; game < 300; game++) {
        gomoku_t g;
        int guard = 0;
        gomoku_reset(&g);

        while (g.winner == 0 && !gomoku_is_full(&g) && guard++ < 400) {
            int r, c, ret, tries = 0;
            do {
                r = (int)(lcg() % GOMOKU_N);
                c = (int)(lcg() % GOMOKU_N);
                tries++;
            } while (g.cell[r][c] != GOMOKU_EMPTY && tries < 1000);

            ret = gomoku_place(&g, r, c);
            if (ret != GOMOKU_OK) {
                g_fail++;
                printf("  [FAIL] 第 %d 局随机落子被拒 ret=%d\n", game, ret);
                return;
            }
            total_moves++;

            /* 每落一手，用全盘扫描独立算一遍，必须和增量结果一致 */
            {
                int scan = gomoku_scan_winner(&g);
                if (scan != g.winner) {
                    g_fail++;
                    printf("  [FAIL] 对拍不一致！第 %d 局第 %d 手落 (%d,%d)："
                           "增量 winner=%d，全盘扫描=%d\n",
                           game, guard, r, c, g.winner, scan);
                    return;
                }
            }
        }
        if (g.winner) wins++; else draws++;
    }
    printf("       跑了 300 局 / %ld 手，分胜负 %d 局、平 %d 局，逐步对拍一致\n",
           total_moves, wins, draws);
    CHECK(total_moves > 3000, "对拍样本量应足够（> 3000 手）");
}

/* ------------------------------------------------------------------------- */
int main(void)
{
    printf("=== 五子棋 轨道 C 单测 ===\n\n");

    test_reset();
    test_win_directions();
    test_reverse_order_win();
    test_edges();
    test_not_win();
    test_long_run();
    test_illegal();
    test_run_len_is_readonly();
    test_draw();
    test_cross_check_random();

    printf("\n============================\n");
    printf("checks=%d  errors=%d\n", g_pass + g_fail, g_fail);
    if (g_fail == 0) printf("=== PASS ===\n");
    else             printf("=== FAIL ===\n");
    return g_fail == 0 ? 0 : 1;
}
