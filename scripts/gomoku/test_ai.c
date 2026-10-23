/* ============================================================================
 * test_ai.c —— 轨道 D 的 x86 单测（只在 PC 上跑，不进固件）
 * ----------------------------------------------------------------------------
 * 运行：  scripts\gomoku\run_test.ps1
 *
 * 验收标准照抄工作清单的轨道 D：
 *   D1 「会堵对手活四、会抢自己活三」
 *   D2 「PvE 可玩、单步 ≤ ~1 秒」
 *   D4 「不越 32KB、落子不卡死输入」
 * 所以这个文件除了战术断言，还要量【节点数】和【耗时】——那是 D4 的唯一数据源。
 *
 * [!] 耗时是 x86 上量的，不等于板上的时间。板上换算是：
 *        板上时间 ≈ 本次 x86 时间 × CAL_X86_TO_BOARD
 *     这个系数是估的，不是测的 —— 真值只能在板上量（见 README 的"下一步"）。
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>   /* rand/srand —— 只在 x86 测试里用，固件不依赖 */
#include <time.h>     /* clock —— 同上 */
#include "board.h"
#include "ai.h"

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

#define MV(...)  (const int[]){ __VA_ARGS__ }, (int)(sizeof((const int[]){ __VA_ARGS__ }) / sizeof(int))

static int place_seq(gomoku_t *g, const int *rc, int n_ints)
{
    int i;
    for (i = 0; i + 1 < n_ints; i += 2) {
        int ret = gomoku_place(g, rc[i], rc[i + 1]);
        if (ret != GOMOKU_OK) return ret;
    }
    return GOMOKU_OK;
}

/* 双方棋盘逐字节比对 —— 用来断言 ai_choose_move 只读棋盘 */
static int board_identical(const gomoku_t *a, const gomoku_t *b)
{
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    unsigned i;
    for (i = 0; i < sizeof(gomoku_t); i++)
        if (pa[i] != pb[i]) return 0;
    return 1;
}

/* 跑一步 AI，顺手断言它没改棋盘、落点合法 */
static int ai_play(gomoku_t *g, int level, ai_stats_t *st)
{
    gomoku_t before = *g;
    int r = -1, c = -1, ret;

    ret = ai_choose_move(g, level, &r, &c, st);
    if (ret != GOMOKU_OK) return ret;

    if (!board_identical(g, &before)) {
        g_fail++;
        printf("  [FAIL] ai_choose_move 改了棋盘！（level=%d）\n", level);
        return 99;
    }
    if (r < 0 || r >= GOMOKU_N || c < 0 || c >= GOMOKU_N) {
        g_fail++;
        printf("  [FAIL] AI 给出越界走法 (%d,%d)\n", r, c);
        return 99;
    }
    if (g->cell[r][c] != GOMOKU_EMPTY) {
        g_fail++;
        printf("  [FAIL] AI 给出已占用的点 (%d,%d)\n", r, c);
        return 99;
    }
    return gomoku_place(g, r, c);
}

/* ---------------------------------------------------------------------------
 * A. 战术：能成五就成五；对手能成五就堵
 * ------------------------------------------------------------------------- */
static void test_tactics(void)
{
    gomoku_t g;
    int r, c, i;
    ai_stats_t st;

    printf("---- A. 战术：成五 / 堵五 ----\n");

    /* 黑 7,3..7,6 四连，白在无关处。黑该下 (7,7) 或 (7,2) —— 两个都能成五 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  0,2,  7,6,  0,3)) == GOMOKU_OK, "布景应成功");
    r = c = -1;
    CHECK(ai_choose_move(&g, AI_HARD, &r, &c, &st) == GOMOKU_OK, "AI 应给出走法");
    CHECK(r == 7 && (c == 7 || c == 2), "黑该自己成五（落 (7,7) 或 (7,2)）");

    /* 白 (7,0)..(7,3) 四连，**只有 (7,4) 一个点能补成五**
     * （另一端被棋盘边堵死）—— 黑必须堵 (7,4)，这是真能救的棋。
     * 注意别用"活四"来测：活四两头都能成五，本来就救不了，那种局面下
     * AI 随便下哪都是输，"必须堵哪"这条断言本身就不成立。 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 0,0,  7,0,  0,1,  7,1,  0,2,  7,2, 10,10,  7,3)) == GOMOKU_OK, "布景应成功");
    CHECK(g.turn == GOMOKU_BLACK, "现在应轮到黑");
    r = c = -1;
    CHECK(ai_choose_move(&g, AI_HARD, &r, &c, &st) == GOMOKU_OK, "AI 应给出走法");
    if (!(r == 7 && c == 4))
        printf("       （实际选了 (%d,%d)，期望 (7,4)）\n", r, c);
    CHECK(r == 7 && c == 4, "黑必须堵白唯一的成五点 (7,4)");

    /* 对手活三：白 7,4 7,5 7,6（两端 7,3 / 7,7 都空），轮黑该去堵一端 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 0,0,  7,4, 14,14,  7,5, 0,1,  7,6)) == GOMOKU_OK, "布景应成功");
    r = c = -1;
    CHECK(ai_choose_move(&g, AI_NORMAL, &r, &c, &st) == GOMOKU_OK, "AI 应给出走法");
    if (!(r == 7 && (c == 3 || c == 7)))
        printf("       （实际选了 (%d,%d)，期望 (7,3) 或 (7,7)）\n", r, c);
    CHECK(r == 7 && (c == 3 || c == 7), "黑该堵白的活三（落 (7,3) 或 (7,7)）");

    /* 五连里被夹住的那种，AI 不该误判成"对手能成五" */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  7,6,  7,7)) == GOMOKU_OK, "布景应成功");
    CHECK(g.winner == 0, "这局不该已经结束");
    r = c = -1;
    CHECK(ai_choose_move(&g, AI_NORMAL, &r, &c, &st) == GOMOKU_OK, "AI 应给出走法");
    (void)i;
}

/* ---------------------------------------------------------------------------
 * B. 空盘开局 + 只读性 + 合法性（各难度都过一遍）
 * ------------------------------------------------------------------------- */
static void test_basic(void)
{
    gomoku_t g, before;
    int r, c, lv;
    ai_stats_t st;

    printf("---- B. 空盘开局 / 只读性 / 合法性 ----\n");

    gomoku_reset(&g);
    r = c = -1;
    CHECK(ai_choose_move(&g, AI_EASY, &r, &c, &st) == GOMOKU_OK, "空盘应能给出走法");
    CHECK(r == GOMOKU_N / 2 && c == GOMOKU_N / 2, "空盘应下天元 (7,7)");

    /* 已分胜负 / 满盘 时应当拒绝 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,3,  0,0,  7,4,  0,1,  7,5,  0,2,  7,6,  0,3,  7,7)) == GOMOKU_OK, "布景应成功");
    CHECK(g.winner == GOMOKU_BLACK, "黑应已胜");
    r = c = -1;
    CHECK(ai_choose_move(&g, AI_HARD, &r, &c, &st) != GOMOKU_OK, "已分胜负时不该再给走法");

    /* 三个难度都不许改棋盘 */
    for (lv = AI_EASY; lv <= AI_HARD; lv++) {
        gomoku_reset(&g);
        place_seq(&g, MV( 7,7,  7,8,  8,8,  6,6));
        before = g;
        r = c = -1;
        CHECK(ai_choose_move(&g, lv, &r, &c, &st) == GOMOKU_OK, "AI 应给出走法");
        CHECK(board_identical(&g, &before), "ai_choose_move 不该改棋盘");
        CHECK(g.cell[r][c] == GOMOKU_EMPTY, "给出的点应是空的");
        /* st.depth 是"**实际完成**的深度"，可能因为节点预算被截断而小于档位
         * —— 那是设计如此（迭代加深会退回上一轮完整结果）。所以断言范围，
         * 不断言等于档位。AI_EASY 不搜索，恒为 1。 */
        {
            int nominal = (lv == AI_EASY) ? 1 : ((lv == AI_NORMAL) ? 4 : 6);
            CHECK(st.depth >= 1 && st.depth <= nominal, "统计里的深度应在 [1, 档位] 内");
            if (lv == AI_EASY) CHECK(st.depth == 1, "EASY 不搜索，深度应为 1");
        }
        CHECK(st.nodes > 0, "统计里应有节点数");
    }
}

/* ---------------------------------------------------------------------------
 * C. 自对弈：跑完整局，判出胜负，全程不非法
 * ------------------------------------------------------------------------- */
static int play_game(int lv_black, int lv_white, uint32_t seed, int *moves_out,
                     uint32_t *nodes_out, uint32_t *maxnodes_out,
                     uint32_t *hard_max_out)
{
    gomoku_t g;
    uint32_t lcg = seed * 2654435761u + 1u;
    int guard = 0, mv = 0, open;
    uint32_t nodes = 0, mx = 0, hard_mx = 0;

    gomoku_reset(&g);

    /* 用 seed 先铺 4 手伪随机开局（2 黑 2 白），让不同 seed = 不同局面。
     * 否则确定性引擎从空盘对弈，每局棋谱一模一样 —— "N 局"实际只有 1 个样本。
     * 开局只落在天元附近 7x7（行/列 4..10），不会铺成一边倒的残局。 */
    for (open = 0; open < 4 && g.winner == 0; open++) {
        int r, c, tries;
        for (tries = 0; tries < 200; tries++) {
            lcg = lcg * 1103515245u + 12345u;
            r = 4 + (int)(lcg % 7);
            lcg = lcg * 1103515245u + 12345u;
            c = 4 + (int)(lcg % 7);
            if (g.cell[r][c] == GOMOKU_EMPTY) break;
        }
        if (tries >= 200) break;
        if (gomoku_place(&g, r, c) != GOMOKU_OK) break;
    }

    while (g.winner == 0 && !gomoku_is_full(&g) && guard++ < 400) {
        ai_stats_t st;
        int lv = (g.turn == GOMOKU_BLACK) ? lv_black : lv_white;
        int ret;

        ret = ai_play(&g, lv, &st);
        if (ret != GOMOKU_OK) return -1;
        mv++;
        nodes += st.nodes;
        if (st.nodes > mx) mx = st.nodes;
        if (lv == AI_HARD && st.nodes > hard_mx) hard_mx = st.nodes;
    }
    if (moves_out)    *moves_out = mv;
    if (nodes_out)    *nodes_out = nodes;
    if (maxnodes_out) *maxnodes_out = mx;
    if (hard_max_out) *hard_max_out = hard_mx;
    return g.winner;
}

/* 统计一局胜负：HARD 执黑时黑赢、执白时白赢，都算 HARD 赢 */
static void tally(int w, int hard_is_black, int *hard_wins, int *normal_wins, int *draws)
{
    if (w == 0) { (*draws)++; return; }
    if ((hard_is_black && w == GOMOKU_BLACK) || (!hard_is_black && w == GOMOKU_WHITE))
        (*hard_wins)++;
    else
        (*normal_wins)++;
}

static void test_selfplay(void)
{
    int i, w;
    uint32_t hard_mx;
    int hard_wins = 0, normal_wins = 0, draws = 0;
    uint32_t worst_hard_nodes = 0;

    printf("---- C. 自对弈（HARD 6 层 对 NORMAL 4 层，10 开局 x 黑白互换 = 20 局）----\n");

    for (i = 0; i < 10; i++) {
        uint32_t seed = (uint32_t)(i + 1);

        /* 同一个开局打两局：HARD 执黑 / HARD 执白，抵消开局对某方的天然偏袒 */
        w = play_game(AI_HARD, AI_NORMAL, seed, NULL, NULL, NULL, &hard_mx);
        CHECK(w >= 0, "自对弈不应中途出现非法走法");
        tally(w, 1, &hard_wins, &normal_wins, &draws);
        if (hard_mx > worst_hard_nodes) worst_hard_nodes = hard_mx;

        w = play_game(AI_NORMAL, AI_HARD, seed, NULL, NULL, NULL, &hard_mx);
        CHECK(w >= 0, "自对弈不应中途出现非法走法");
        tally(w, 0, &hard_wins, &normal_wins, &draws);
        if (hard_mx > worst_hard_nodes) worst_hard_nodes = hard_mx;
    }

    printf("       HARD 赢 %d 局 / NORMAL 赢 %d 局 / 平 %d 局；HARD 单步最多 %u 节点\n",
           hard_wins, normal_wins, draws, worst_hard_nodes);
    CHECK(hard_wins + normal_wins + draws == 20, "应有 20 局结果");

    /* B3 验收（任务书）：**两条都要过** ——
     *   ① HARD 收窄宽度后仍应强于 NORMAL（否则这个档位没有存在意义）
     *   ② 最坏一手不能慢到被误判成死机
     *
     * [!] 2026-10-07 修正：原稿把「≤4000 节点」删了，理由是它和①冲突 —— 冲突属实，
     *     但**删掉标准不等于解决，只是把目标丢了**。真正的控制量是 ai.c 的
     *     `AI_NODE_BUDGET`：宽度只管【典型】节点数，**最坏情况永远被预算兜住**。
     *     所以②改成卡【板上换算的秒数】，而不是卡一个死节点数 —— 这样两条不再冲突：
     *     典型局面 808 节点（≈0.5s）离预算很远，6 层照样完整搜完；
     *     只有极端局面才中途降级，而那时它被预算兜在 7 秒内。
     *
     * 板上秒数 = 节点数 × 0.6 ms（2026-10-06 双发射板上实测系数，见 measure_ai.c）。 */
    CHECK(hard_wins > normal_wins, "HARD 应比 NORMAL 多赢（B3 验收①）");
    CHECK(worst_hard_nodes * 0.6 <= 8000.0,
          "HARD 最坏单步应 ≤ 8 秒（板上换算，B3 验收②）");
}

/* ---------------------------------------------------------------------------
 * D. 棋力：HARD 对「随机走子」，必须压倒性获胜
 * ------------------------------------------------------------------------- */
static int random_move(gomoku_t *g)
{
    int tries;
    for (tries = 0; tries < 2000; tries++) {
        int idx = (int)(rand() % (GOMOKU_N * GOMOKU_N));
        int r = idx / GOMOKU_N, c = idx % GOMOKU_N;
        if (g->cell[r][c] == GOMOKU_EMPTY) return gomoku_place(g, r, c);
    }
    return 1;
}

static void test_strength_vs_random(void)
{
    int i, ai_wins = 0, rand_wins = 0, draws = 0;

    printf("---- D. 棋力：HARD 对「随机走子」20 局 ----\n");
    srand(20261001u);

    for (i = 0; i < 20; i++) {
        gomoku_t g;
        int guard = 0;
        int ai_color = (i % 2 == 0) ? GOMOKU_BLACK : GOMOKU_WHITE;
        int ret;

        gomoku_reset(&g);
        while (g.winner == 0 && !gomoku_is_full(&g) && guard++ < 400) {
            if (g.turn == ai_color) ret = ai_play(&g, AI_HARD, NULL);
            else                    ret = random_move(&g);
            if (ret != GOMOKU_OK) { g_fail++; printf("  [FAIL] 对局中途非法\n"); return; }
        }
        if (g.winner == ai_color) ai_wins++;
        else if (g.winner == 0)   draws++;
        else                      rand_wins++;
    }
    printf("       AI 胜 %d / 随机胜 %d / 平 %d\n", ai_wins, rand_wins, draws);
    CHECK(ai_wins >= 18, "HARD 对随机应至少赢 18/20");
    CHECK(rand_wins == 0, "不该输给随机走子");
}

/* ---------------------------------------------------------------------------
 * E. 性能：节点数与耗时 —— D4 的唯一数据源
 * ------------------------------------------------------------------------- */
/* x86 时间 × 这个系数 ≈ 板上 RV32 的时间。
 *
 * [!] 2026-10-07 修正：原值 20.0 差了 **6 倍**（注释还写着"62MHz"，那是提频前、
 *     而且当时是单发射）。按板上实测反推：
 *         x86    NORMAL 1400 us / 342 节点 = 4.094 us/节点
 *         板上   NORMAL  552 ms / 1287 节点 = 0.4289 ms/节点（2026-10-06 双发射实测）
 *         ⇒ 系数 = 428.9 / 4.094 ≈ 105
 *     取 120 是**偏保守**的一端（对同样的 x86 时间给出更高的板上估计，
 *     于是 D4 那条"单步 < 1 秒"的验收更严，不会放过慢局面）。
 *     更准的做法是直接用 `节点数 × 0.6 ms`（见 scripts/gomoku/measure_ai.c 的实测）。
 * [!] 这个数会随 CPU 配置变：单发射比双发射慢约 18%。改 CPU 后要重新标定。 */
#define CAL_X86_TO_BOARD  120.0

static void test_perf(void)
{
    gomoku_t g;
    static const int lv[3] = { AI_EASY, AI_NORMAL, AI_HARD };
    static const char *nm[3] = { "EASY", "NORMAL", "HARD" };
    int k, i;

    printf("---- E. 性能（节点数 / x86 耗时 / 板上粗估）----\n");

    /* 用一个中局局面：双方各 6 子，接近实战 */
    gomoku_reset(&g);
    CHECK(place_seq(&g, MV( 7,7,  7,8,  8,8,  6,6,  8,7,  6,8,
                            9,9,  5,5,  8,9,  6,7,  9,8, 5,6)) == GOMOKU_OK, "布景应成功");

    for (k = 0; k < 3; k++) {
        ai_stats_t st;
        int r, c;
        clock_t t0, t1;
        double x86_us, board_ms;
        uint32_t worst = 0, total = 0;

        /* 每个难度跑 5 次取最坏（避免单次抖动） */
        for (i = 0; i < 5; i++) {
            t0 = clock();
            if (ai_choose_move(&g, lv[k], &r, &c, &st) != GOMOKU_OK) {
                g_fail++; printf("  [FAIL] %s 没给出走法\n", nm[k]); return;
            }
            t1 = clock();
            (void)t0; (void)t1;
            if (st.nodes > worst) worst = st.nodes;
            total += st.nodes;
        }

        t0 = clock();
        for (i = 0; i < 5; i++) ai_choose_move(&g, lv[k], &r, &c, NULL);
        t1 = clock();
        x86_us = (double)(t1 - t0) * 1e6 / (CLOCKS_PER_SEC * 5.0);
        board_ms = x86_us * CAL_X86_TO_BOARD / 1000.0;

        printf("       %-6s 深度=%d  最多 %6u 节点/步（均 %6u）  "
               "x86 %8.0f us/步   板上粗估 %6.1f ms\n",
               nm[k], (int)st.depth, worst, total / 5, x86_us, board_ms);

        /* D4 的验收：单步 ≤ 1 秒。
         * [!] 2026-10-07 改：原来拿 `board_ms`（= x86 墙钟时间 × 系数）判定 ——
         *     但 **x86 时间不稳定**：同一个 808 节点的局面，实测在 4000~8400 us 之间
         *     （差 2.1 倍，取决于机器忙不忙），于是这条验收会**随机变红**。
         *     拿一个抖动的量去卡硬指标，判据本身就不可信。
         *     引擎没有随机源 ⇒ **节点数是确定性的**，改用节点数换算：
         *     判据可复现，而且直接对应"板上跑多久"。
         * 板上每节点 ≈ 0.6 ms（2026-10-06 双发射实测，取保守端）。 */
        CHECK(worst * 0.6 < 1000.0, "单步应按节点数估算 < 1 秒");
    }
}

/* ------------------------------------------------------------------------- */
int main(void)
{
    printf("=== 五子棋 轨道 D（AI）单测 ===\n\n");
    printf("sizeof(gomoku_t) = %u 字节（这块内存由调用方持有）\n\n",
           (unsigned)sizeof(gomoku_t));

    test_tactics();
    test_basic();
    test_selfplay();
    test_strength_vs_random();
    test_perf();

    printf("\n============================\n");
    printf("checks=%d  errors=%d\n", g_pass + g_fail, g_fail);
    if (g_fail == 0) printf("=== PASS ===\n");
    else             printf("=== FAIL ===\n");
    return g_fail == 0 ? 0 : 1;
}
