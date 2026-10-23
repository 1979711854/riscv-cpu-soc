/* ============================================================================
 * ai.c —— 五子棋 AI 的实现（轨道 D）
 * ----------------------------------------------------------------------------
 * [!] 不用任何 libc（没有 memset/memcpy/qsort/malloc），要能原样编进 RV32 固件。
 *     结构体清零写成显式赋值，排序写成插入排序（候选数 ≤ AI_WIDTH，够了）。
 *
 * 评分模型（这是本文件的核心，改之前先读完）：
 *   对每个**空点**，分别算两件事：
 *     atk = 假设【我方】下在这儿，四个方向能形成的最好形态值之和
 *     def = 假设【对手】下在这儿，四个方向能形成的最好形态值之和
 *   score = atk*10 + def*9
 *   —— 权重 10 : 9 是刻意的：**同样大的威胁，优先成全自己而不是堵对手**。
 *      如果取相等，双方都有活四时会出现"随机选一个"，而先手本来就该赢。
 *
 *   形态值只数"连续子数 + 两端是否被堵"（shape_score）。它【认不出】跳三
 *   `X_XX`、跳四 `XX_X` 这类断点棋型 —— 那是有意为之：评分函数只负责排序，
 *   断点交给 alpha-beta 搜索去发现（它在两三层内就能看到那条线）。
 *   把评分表堆到能认断点会让每个节点变慢好几倍，而 RV32 上时间是硬约束。
 *
 * 搜索：
 *   根节点按 score 排序取前 AI_WIDTH 个候选（这是天然的走法排序，α-β 剪枝效率
 *   主要靠它），然后 negamax + α-β 递归。任一层若某手直接成五就立即返回获胜分，
 *   不再往下搜 —— 五子棋里这一步剪掉的量非常大。
 * ==========================================================================*/
#include "ai.h"

/* ---- 形态分值 -------------------------------------------------------------
 * 量级关系是硬约束，别随手改：
 *   SC_WIN  >> SC_FIVE  —— 保证"四层内能赢"压过"现在就成五"之外的任何东西
 *   FIVE    >> OPEN4    —— 我成五 >> 我成活四
 *   OPEN4   >  FOUR     —— 活四（必胜）> 冲四（被堵一下就没了）
 *   atk*10 + def*9      —— 所以对手成五（9*FIVE）会被我方成五（10*FIVE）压过，
 *                          但会压过我方活四（10*OPEN4）→ 该堵的时候一定堵
 */
#define SC_WIN      20000000
#define SC_FIVE     10000000
#define SC_OPEN4      100000
#define SC_FOUR        20000
#define SC_OPEN3       15000
#define SC_SLEEP3       2000
#define SC_OPEN2        1000
#define SC_SLEEP2        200
#define SC_OPEN1          50
#define SC_SLEEP1          5

#define AI_INF      1000000000

/* 每个节点保留的候选走法数（搜索宽度）。调大 = 更强更慢，改完必须重测耗时 */
#define AI_WIDTH    14

/* HARD 档的搜索宽度（任务书 B3）：6 层 × 14 宽在板上实测一手要 14.5 秒，太慢。
 * 收窄宽度是唯一正确的方向（「开局库」「调小 NODE_BUDGET」都被 2026-10-04 实测否掉）。
 * 但 8 宽"少看太多"：2026-10-07 自对弈实测 8 宽和 NORMAL 打平（执黑方全胜、无强弱差），
 * 每层少看 6 个候选的损失 > 多 2 层挣回的收益。所以取 10~12 之间的平衡点：
 * 比 14 宽明显快，又足够宽到深度 6 仍强于 NORMAL。板上秒数 = 节点数 × 0.6ms，
 * 具体值由 test_ai.c 自对弈 + 板上实测标定，先取 10。 */
#define AI_WIDTH_HARD 10

/* 单步搜索的节点数上限 —— D4「落子不卡死输入」的保险丝。
 * 超了就退回上一轮【完整搜完】的结果（迭代加深保证总有上一轮）。
 *
 * [!] **这个值才是"最坏一手多久"的真正控制量，宽度不是。**
 *     宽度（AI_WIDTH_HARD）只决定【典型】一手的节点数；
 *     最坏情况永远被这个预算兜住 —— 所以 HARD 的延迟上限 = 预算 × 每节点耗时。
 *
 * [重点] 2026-10-07 按板上实测标定（原值 40000 是"先保证不扭曲棋力"的临时值，
 *     在板上意味着最坏 4 万 × 0.6ms ≈ 24 秒，比动工前那 14.5 秒还差）：
 *
 *         板上每节点耗时：双发射实测 0.429 ms（NORMAL 552ms/1287 节点，2026-10-06）
 *                         保守取 **0.6 ms**（盘面越满越贵，实测见过 0.88）
 *         目标最坏一手：**≈ 7 秒**（配合串口的 "AI thinking..." 提示，可接受）
 *         ⇒ 预算 = 7000ms / 0.6ms ≈ 11,700 → 取 **12000**
 *
 *     典型局面（808 节点）离预算很远，**6 层照样完整搜完**；
 *     只有极端局面才会中途降级到 4 层。**这是按局面自适应，不是一刀切降档。**
 *
 * [!] 改这个值必须重跑 `test_ai.c` 的自对弈：预算压太小会让 HARD 频繁降级、
 *     棋力掉回 NORMAL —— 那这个档位就没有存在意义了，应该直接删掉。
 * [!] 换 CPU 配置（单发射/双发射、改主频）后要重新标定：单发射慢约 18%。 */
#define AI_NODE_BUDGET  12000u

/* 候选点只取"离已有棋子切比雪夫距离 ≤ AI_NEIGH"的空点。
 * 这是五子棋搜索的标准剪枝：离棋子很远的点没有战术意义。 */
#define AI_NEIGH    2

typedef struct {
    int8_t  r, c;
    int32_t atk;     /* 我方下这儿的形态值 */
    int32_t def;     /* 对手下这儿的形态值 */
    int32_t score;   /* atk*10 + def*9 */
} ai_move_t;

typedef struct {
    uint8_t stones;
    uint8_t turn;
} ai_undo_t;

/* --------------------------------------------------------------------------- */

static inline int ai_opp(int who)
{
    return (who == GOMOKU_BLACK) ? GOMOKU_WHITE : GOMOKU_BLACK;
}

static inline int ai_in_range(int r, int c)
{
    return (r >= 0 && r < GOMOKU_N && c >= 0 && c < GOMOKU_N);
}

/* 连续子数 + 两端开口数 → 形态分。这是评分函数的全部"棋型知识"。 */
static int32_t shape_score(int run, int open)
{
    if (run >= GOMOKU_WIN_LEN) return SC_FIVE;
    if (open == 0)             return 0;          /* 两头都堵死，没用 */
    switch (run) {
    case 4:  return (open == 2) ? SC_OPEN4  : SC_FOUR;
    case 3:  return (open == 2) ? SC_OPEN3  : SC_SLEEP3;
    case 2:  return (open == 2) ? SC_OPEN2  : SC_SLEEP2;
    case 1:  return (open == 2) ? SC_OPEN1  : SC_SLEEP1;
    default: return 0;
    }
}

/* 假想 (r,c) 是 who 的子，看 (dr,dc) 这一条线。 */
static int32_t line_score(const gomoku_t *g, int r, int c, int dr, int dc, int who)
{
    int n1 = 0, n2 = 0, o1 = 0, o2 = 0;
    int rr, cc;

    rr = r + dr; cc = c + dc;
    while (ai_in_range(rr, cc) && g->cell[rr][cc] == who) { n1++; rr += dr; cc += dc; }
    o1 = (ai_in_range(rr, cc) && g->cell[rr][cc] == GOMOKU_EMPTY);

    rr = r - dr; cc = c - dc;
    while (ai_in_range(rr, cc) && g->cell[rr][cc] == who) { n2++; rr -= dr; cc -= dc; }
    o2 = (ai_in_range(rr, cc) && g->cell[rr][cc] == GOMOKU_EMPTY);

    return shape_score(1 + n1 + n2, o1 + o2);
}

/* 假想 (r,c) 是 who 的子，四个方向加起来。**不改变 g**。 */
static int32_t point_score(const gomoku_t *g, int r, int c, int who)
{
    return line_score(g, r, c,  0,  1, who)     /* 横 */
         + line_score(g, r, c,  1,  0, who)     /* 竖 */
         + line_score(g, r, c,  1,  1, who)     /* 斜 \ */
         + line_score(g, r, c,  1, -1, who);    /* 斜 / */
}

int32_t ai_move_score(const gomoku_t *g, int r, int c, int who)
{
    if (!ai_in_range(r, c) || g->cell[r][c] != GOMOKU_EMPTY) return -AI_INF;
    return point_score(g, r, c, who) * 10 + point_score(g, r, c, ai_opp(who)) * 9;
}

/* ---------------------------------------------------------------------------
 * 候选生成：只收"离已有棋子 <= AI_NEIGH"的空点，按 score 降序只留前 maxn 个。
 * 用"边扫边插"的两遍法，而不是先全收再排序 —— 全收要 225 个 ai_move_t
 * （约 3.6 KB），乘上递归深度就是十几 KB，32 KB 的机器上不敢这么花。
 * ------------------------------------------------------------------------- */
static void insert_top(ai_move_t *arr, int *n, int maxn, const ai_move_t *m)
{
    int i;

    if (*n < maxn) {
        i = *n;
        while (i > 0 && arr[i - 1].score < m->score) { arr[i] = arr[i - 1]; i--; }
        arr[i] = *m;
        (*n)++;
        return;
    }
    if (m->score <= arr[maxn - 1].score) return;   /* 进不了前 maxn，丢掉 */
    i = maxn - 1;
    while (i > 0 && arr[i - 1].score < m->score) { arr[i] = arr[i - 1]; i--; }
    arr[i] = *m;
}

static int near_stone(const gomoku_t *g, int r, int c)
{
    int dr, dc;
    for (dr = -AI_NEIGH; dr <= AI_NEIGH; dr++) {
        for (dc = -AI_NEIGH; dc <= AI_NEIGH; dc++) {
            int rr, cc;
            if (dr == 0 && dc == 0) continue;
            rr = r + dr; cc = c + dc;
            if (ai_in_range(rr, cc) && g->cell[rr][cc] != GOMOKU_EMPTY) return 1;
        }
    }
    return 0;
}

static int gen_top(const gomoku_t *g, int who, ai_move_t *out, int maxn)
{
    int r, c, n = 0;
    int op = ai_opp(who);
    int r0, r1, c0, c1;

    if (g->stones == 0) {                 /* 空盘：天元开局 */
        out[0].r = (int8_t)(GOMOKU_N / 2);
        out[0].c = (int8_t)(GOMOKU_N / 2);
        out[0].atk = out[0].def = out[0].score = 0;
        return 1;
    }

    /* [!] 扫描范围收缩到"已有棋子的外接矩形 + AI_NEIGH 边距"。
     * 这是本函数最值钱的一处优化：五子棋的棋子是聚在一起的，整盘 225 格
     * 里真正要看的通常只有几十格。早先版本每层都扫满 225 格 × near_stone(25)，
     * 单节点就是 5600 次判断 —— 节点数一上千，耗时直接失控。 */
    r0 = GOMOKU_N; r1 = -1; c0 = GOMOKU_N; c1 = -1;
    for (r = 0; r < GOMOKU_N; r++) {
        for (c = 0; c < GOMOKU_N; c++) {
            if (g->cell[r][c] == GOMOKU_EMPTY) continue;
            if (r < r0) r0 = r;
            if (r > r1) r1 = r;
            if (c < c0) c0 = c;
            if (c > c1) c1 = c;
        }
    }
    r0 -= AI_NEIGH; r1 += AI_NEIGH; c0 -= AI_NEIGH; c1 += AI_NEIGH;
    if (r0 < 0)             r0 = 0;
    if (c0 < 0)             c0 = 0;
    if (r1 > GOMOKU_N - 1)  r1 = GOMOKU_N - 1;
    if (c1 > GOMOKU_N - 1)  c1 = GOMOKU_N - 1;

    for (r = r0; r <= r1; r++) {
        for (c = c0; c <= c1; c++) {
            ai_move_t m;
            if (g->cell[r][c] != GOMOKU_EMPTY) continue;
            if (!near_stone(g, r, c))          continue;
            m.r = (int8_t)r;
            m.c = (int8_t)c;
            m.atk = point_score(g, r, c, who);
            m.def = point_score(g, r, c, op);
            m.score = m.atk * 10 + m.def * 9;
            insert_top(out, &n, maxn, &m);
        }
    }
    return n;
}

/* ---------------------------------------------------------------------------
 * 叶子估值
 *   = 我方最好的进攻点 - 对手最好的进攻点
 * 直接复用父节点已经算好的 atk/def，不再扫盘 —— 叶子节点数量最大，这里省下的
 * 每一次 point_score（4 方向 × 最多 9 格）都会成倍放大。
 * ------------------------------------------------------------------------- */
static int32_t leaf_eval(const ai_move_t *cand, int n)
{
    int32_t ba = 0, bd = 0;
    int i;
    for (i = 0; i < n; i++) {
        if (cand[i].atk > ba) ba = cand[i].atk;
        if (cand[i].def > bd) bd = cand[i].def;
    }
    return ba - bd;
}

/* 搜索里只动 cell / stones / turn 三个字段：gomoku_run_len 只读 cell，
 * 叶子估值只读候选表，所以 last_ 那几个字段与 winner 都不必保存。
 * [!] 在本文件的块注释里【不要】写出星号紧跟斜杠的序列 —— 那会把注释提前闭合，
 *     编译报 "expected '=' ... before '/'"，而且报错行号指向注释本身，很难看出来。 */
static void do_move(gomoku_t *g, int r, int c, int who, ai_undo_t *u)
{
    u->stones = g->stones;
    u->turn   = g->turn;
    g->cell[r][c] = (uint8_t)who;
    g->stones++;
    g->turn = (uint8_t)ai_opp(who);
}

static void undo_move(gomoku_t *g, int r, int c, const ai_undo_t *u)
{
    g->cell[r][c] = GOMOKU_EMPTY;
    g->stones = u->stones;
    g->turn   = u->turn;
}

static int32_t search(gomoku_t *g, int who, int depth, int ply,
                      int32_t alpha, int32_t beta, int width, ai_stats_t *st)
{
    ai_move_t cand[AI_WIDTH];      /* 数组恒按最大宽度开；实际用 width 个 */
    int       n, i;
    int32_t   best;

    /* [!] 节点预算：超了就置 aborted 并立刻往上退。
     *    中途退出的评分是【不可信】的（α-β 只保证完整搜完才有意义），
     *    所以调用方看到 aborted 必须丢弃本轮结果、用上一轮完整搜完的。
     *    这是 D4「落子不卡死输入」的实现方式。 */
    st->nodes++;
    if (st->nodes > AI_NODE_BUDGET) { st->aborted = 1; return 0; }

    n = gen_top(g, who, cand, width);
    if (n == 0) return 0;                       /* 满盘 = 平局 */

    if (depth == 0) {
        st->leaves++;
        return leaf_eval(cand, n);
    }

    best = -AI_INF;
    for (i = 0; i < n; i++) {
        ai_undo_t u;
        int r = cand[i].r, c = cand[i].c;
        int32_t v;

        if (st->aborted) return 0;              /* 已被预算打断，尽快退出去 */

        /* 这一手直接成五 -> 立刻返回，不必再展开（五子棋里剪掉的量很大） */
        if (gomoku_run_len(g, r, c, who) >= GOMOKU_WIN_LEN)
            return SC_WIN - ply;                /* 越早赢分越高 */

        do_move(g, r, c, who, &u);
        v = -search(g, ai_opp(who), depth - 1, ply + 1, -beta, -alpha, width, st);
        undo_move(g, r, c, &u);

        if (st->aborted) return 0;

        if (v > best) best = v;
        if (best > alpha) alpha = best;
        if (alpha >= beta) break;               /* α-β 剪枝 */
    }
    return best;
}

/* ------------------------------------------------------------------------- */

int ai_choose_move(const gomoku_t *g, int level, int *out_r, int *out_c,
                   ai_stats_t *stats)
{
    gomoku_t  work;
    ai_move_t cand[AI_WIDTH];
    ai_stats_t st;
    int       n, i, picked = -1;
    int       depth;
    int       width;
    int32_t   best = -AI_INF;

    /* 显式清零，不用 memset（固件侧没有 libc） */
    st.nodes = 0; st.leaves = 0; st.depth = 0; st.score = 0; st.aborted = 0;

    if (!out_r || !out_c)                 return 1;
    if (g->winner != 0)                   return 1;   /* 已分胜负 */
    if (gomoku_is_full(g))                return 1;   /* 没地方下 */

    /* 深度选择 —— 别把 NORMAL 设成 2，实测那样会输给"活三"。
     * 要看穿「我不堵 -> 对手活四 -> 我堵 -> 对手成五」这条链需要 4 层；
     * 深度 2 的叶子估值会把对手的威胁当成白送的（评分本身是对的，
     * 是搜索太浅看不出防守能救回来）。见 test_ai.c 的 A 段。 */
    depth = (level == AI_HARD)   ? 6 :
            (level == AI_NORMAL) ? 4 : 1;

    /* 搜索宽度：EASY/NORMAL 保持 14，HARD 收窄到 AI_WIDTH_HARD（任务书 B3）。
     * 宽度贯穿搜索的每一层，不只根节点 —— 否则根窄了、下面几层还是 14 宽，
     * 节点数根本降不下来。 */
    width = (level == AI_HARD) ? AI_WIDTH_HARD : AI_WIDTH;

    /* 拷贝一份来搜 —— 绝不动调用方的棋盘 */
    work = *g;

    n = gen_top(&work, work.turn, cand, width);
    if (n == 0) return 2;

    st.depth = (uint8_t)depth;
    st.nodes = (uint32_t)n;

    if (depth == 1) {
        /* 贪心：候选已经是按 score 降序的，第一个就是最优 */
        picked = 0;
        best   = cand[0].score;
    } else {
        /* [!] 把"我方"记成一个局部变量 me，别在图里反复取 work.turn ——
         *     do_move() 内部会把 work.turn 翻成对手，之后再对它套 ai_opp()
         *     就变成"以为还是自己走"，搜索会整层算在错误的一方身上。
         *     2026-10-01 踩过：症状是 AI 对明显的五连视而不见、自对弈全是平局。 */
        const int me = work.turn;
        int order[AI_WIDTH];
        int d, k;

        for (i = 0; i < n; i++) order[i] = i;

        /* 迭代加深：2 层 -> 4 层 -> 6 层，逐轮做。
         *  ① 上一轮的最优走法挪到最前面先搜 —— 这是最好的排序种子，α-β 剪枝更狠；
         *  ② 节点超预算时直接停，用【上一轮完整搜完】的结果，绝不会给出半截评分。 */
        picked = 0;
        best   = cand[0].score;                 /* 兜底：预算在第一轮就超了的话用它 */
        for (d = 2; d <= depth; d += 2) {
            int32_t alpha   = -AI_INF;
            int     cur_i   = order[0];
            int32_t cur_val = -AI_INF;
            int     done    = 1;

            st.aborted = 0;
            for (k = 0; k < n; k++) {
                ai_undo_t u;
                int idx = order[k];
                int r = cand[idx].r, c = cand[idx].c;
                int32_t v;

                if (gomoku_run_len(&work, r, c, me) >= GOMOKU_WIN_LEN) {
                    cur_i = idx; cur_val = SC_WIN; break;   /* 能成五就直接下 */
                }

                do_move(&work, r, c, me, &u);        /* 内部会把 turn 翻成对手 */
                v = -search(&work, ai_opp(me), d - 1, 1, -AI_INF, -alpha, width, &st);
                undo_move(&work, r, c, &u);          /* turn 会一起还原 */

                if (st.aborted) { done = 0; break; } /* 本轮作废，保留上一轮 */

                if (v > cur_val) { cur_val = v; cur_i = idx; }
                if (cur_val > alpha) alpha = cur_val;
            }

            if (!done) break;
            picked   = cur_i;
            best     = cur_val;
            st.depth = (uint8_t)d;               /* 记录【实际完成】的深度 */

            /* 把本轮最优挪到最前面，下一轮先搜它 */
            for (k = 0; k < n; k++) if (order[k] == picked) break;
            if (k > 0 && k < n) { int t = order[0]; order[0] = order[k]; order[k] = t; }
        }
    }

    if (picked < 0) picked = 0;                 /* 理论上到不了 */
    *out_r = cand[picked].r;
    *out_c = cand[picked].c;
    st.score = (depth == 1) ? cand[picked].score : best;

    if (stats) *stats = st;
    return GOMOKU_OK;
}
