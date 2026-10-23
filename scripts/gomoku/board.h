/* ============================================================================
 * board.h —— 五子棋棋盘与判胜（轨道 C）
 * ----------------------------------------------------------------------------
 * 【一份源码两处用】本文件与 board.c 刻意做成**平台无关的纯逻辑**：
 *   - 只依赖 <stdint.h>，不用 libc / 不用动态内存 / 不用浮点
 *   - 无全局状态、无硬件依赖 —— 可以在 x86 上用 gcc 跑单测（test_board.c），
 *     也可以原样编进 RV32 裸机固件（工作清单 §C 的硬要求）
 *
 * 所以【不要】在这里 include 任何 addr_map.h / HAL 之类的东西。
 *
 * 规则取舍（写进注释免得反复讨论）：
 *   - 15x15 交叉点，五连即胜；**长连（6 子及以上）同样算胜**（无禁手规则）
 *   - **不实现禁手**（黑棋三三/四四/长连禁手）。工作清单没要求，且判定复杂、
 *     容易和"到底算不算胜"纠缠不清。真要加，在这一层之上单开一个模块。
 * ==========================================================================*/
#ifndef GOMOKU_BOARD_H
#define GOMOKU_BOARD_H

#include <stdint.h>

#define GOMOKU_N        15   /* 棋盘边长（15x15 交叉点） */
#define GOMOKU_WIN_LEN  5    /* 连成几个算胜 */

/* 格子状态 */
#define GOMOKU_EMPTY    0
#define GOMOKU_BLACK    1
#define GOMOKU_WHITE    2

/* 落子返回码 */
#define GOMOKU_OK           0
#define GOMOKU_ERR_RANGE    1   /* 越界 */
#define GOMOKU_ERR_OCCUPIED 2   /* 该点已有子 */
#define GOMOKU_ERR_TURN     3   /* 不是该他走 */
#define GOMOKU_ERR_OVER     4   /* 已分出胜负，不再接受落子（重开用 gomoku_reset） */

typedef struct {
    uint8_t cell[GOMOKU_N][GOMOKU_N];  /* 0/1/2，见上面三个宏 */
    uint8_t stones;                    /* 已落子数，0..225（判平局用；225 < 255 装得下）*/
    uint8_t turn;                      /* 该谁走：GOMOKU_BLACK / GOMOKU_WHITE */

    int8_t  last_r, last_c;            /* 最后一手坐标；-1 表示还没落过子 */
    uint8_t last_who;                  /* 最后一手是谁下的 */
    uint8_t run_len;                   /* 最后一手在四个方向上连成的**最长**长度 */

    uint8_t winner;                    /* 0 = 未分胜负，否则是胜方颜色 */
} gomoku_t;

/* ---------------------------------------------------------------------------
 * 基础操作
 * ------------------------------------------------------------------------- */

/* 清空棋盘，黑先。 */
void gomoku_reset(gomoku_t *g);

/* 落子。成功返回 GOMOKU_OK，并更新 last_* / run_len / winner / turn；
 * 失败返回错误码，**且不改动任何状态**（可安全地试下）。
 * 用的是 g->turn，不接受外部指定颜色 —— 免得调用方和状态机对不上。 */
int gomoku_place(gomoku_t *g, int r, int c);

/* 读一格。越界返回 GOMOKU_EMPTY（调用方若需要区分，自己先查范围）。 */
static inline int gomoku_get(const gomoku_t *g, int r, int c)
{
    if (r < 0 || r >= GOMOKU_N || c < 0 || c >= GOMOKU_N) return GOMOKU_EMPTY;
    return g->cell[r][c];
}

/* 棋盘是否已满（用于判平局）。 */
static inline int gomoku_is_full(const gomoku_t *g)
{
    return g->stones >= (uint8_t)(GOMOKU_N * GOMOKU_N);
}

/* ---------------------------------------------------------------------------
 * 判胜 / 评分原语
 * ------------------------------------------------------------------------- */

/* 【增量判胜】假设 `who` 的子在 (r,c)，返回过这一点的**最长**连子数。
 *   - (r,c) 可以是空的（"如果我下这儿会连几个" —— 给 AI 用）
 *   - 也可以是 `who` 的子（刚落完，给判胜用）
 *   - 若是**对方的子**则返回 0
 * 只沿 4 个方向各数一次，O(1)，不做全盘扫描。
 * 返回值 >= GOMOKU_WIN_LEN 即表示这一手成五。 */
int gomoku_run_len(const gomoku_t *g, int r, int c, int who);

/* 自己数一遍全盘，返回胜方（0=无）。**不依赖 run_len 缓存**，
 * 用来和增量判胜对拍 —— 单测里有这一条。O(N*N*4)。 */
int gomoku_scan_winner(const gomoku_t *g);

#endif /* GOMOKU_BOARD_H */
