/* ============================================================================
 * measure_ai.c —— AI 搜索成本随【对局阶段】的变化（x86 测量工具，不进固件）
 * ----------------------------------------------------------------------------
 * 要回答的问题（2026-10-04 上板实测引出的）：
 *
 *   板上 HARD(6 层) 开局一手是 24,246 节点 / 14.5 秒，慢得没法玩。
 *   但"开局慢"是反常的 —— 直觉上开局简单、该快。
 *   所以要量清楚：**到底哪个阶段最贵，HARD 相对 NORMAL 的优势又出现在哪。**
 *
 * 做法：先用 NORMAL 自对弈走到若干采样点（2/6/10/16/22/30/40 子），
 *       然后在【同一个局面】上分别跑 EASY / NORMAL / HARD 三档。
 *       同局面三档对比，排除了"各下各的、局面越走越不一样"的干扰。
 *
 * [!] 为什么是这三个数：nodes 决定板上耗时（× 0.6 ms，见下），
 *     depth 是实际完成的深度（超预算会被截断），两者一起看才知道"贵在哪"。
 *
 * 板上秒数换算：节点数 × 0.6 ms
 *   这个系数是 2026-10-04 板上实测的（HARD 开局 24,246 节点 = 14,503 ms）。
 *   注意它随盘面变满而上升（NORMAL 实测 0.52 → 0.88 ms/节点），
 *   所以下面是**偏乐观**的下界估计。
 *
 * 编译运行（和其它 x86 测试台同一套路，不需要板子 / 不需要 RV32 工具链）：
 *   gcc -O2 -I. board.c ai.c measure_ai.c -o measure_ai.exe && ./measure_ai.exe
 * ==========================================================================*/
#include <stdio.h>
#include <time.h>
#include "board.h"
#include "ai.h"

static double now_ms(void)
{
    return (double)clock() * 1000.0 / (double)CLOCKS_PER_SEC;
}

static void probe(const gomoku_t *g, int level, const char *tag)
{
    ai_stats_t st;
    int r = -1, c = -1;
    double t0 = now_ms();
    int ret = ai_choose_move(g, level, &r, &c, &st);
    double dt = now_ms() - t0;

    if (ret != GOMOKU_OK) { printf("  %-7s 无子可下\n", tag); return; }

    printf("  %-7s nodes=%-7u depth=%d  %s  x86 %7.1f ms   板上约 %6.1f s\n",
           tag, st.nodes, st.depth, st.aborted ? "(截断)" : "      ",
           dt, (double)st.nodes * 0.6 / 1000.0);
}

int main(void)
{
    /* 采样点：盘上子数。2 = 开局，22 前后是典型中盘，40 = 残局 */
    static const int stops[] = { 2, 6, 10, 16, 22, 30, 40 };
    const int nstops = (int)(sizeof(stops) / sizeof(stops[0]));
    gomoku_t g;
    int si;

    printf("=== AI 搜索成本 vs 对局阶段（同一局面三档对比，x86）===\n");
    printf("自对弈用 NORMAL；走到每个采样点子数就停，然后在该局面上跑三档\n");
    printf("[重点] 板上约 = 节点数 x 0.6 ms（2026-10-04 板上实测系数，偏乐观）\n");
    printf("[重点] 看三件事：哪个阶段最贵 / HARD 比 NORMAL 贵多少 / 差距在哪个阶段最大\n\n");

    gomoku_reset(&g);

    for (si = 0; si < nstops; si++) {
        /* ---- 用 NORMAL 自对弈走到采样点 ---- */
        while (g.stones < stops[si] && g.winner == 0) {
            ai_stats_t st;
            int r, c;
            if (ai_choose_move(&g, AI_NORMAL, &r, &c, &st) != GOMOKU_OK) break;
            if (gomoku_place(&g, r, c) != GOMOKU_OK) break;
        }

        printf("--- 盘上 %d 子 ---\n", (int)g.stones);
        probe(&g, AI_EASY,   "EASY");
        probe(&g, AI_NORMAL, "NORMAL");
        probe(&g, AI_HARD,   "HARD");
        printf("\n");

        if (g.winner) {
            printf("（自对弈已分出胜负，采样提前结束）\n");
            break;
        }
    }

    return 0;
}
