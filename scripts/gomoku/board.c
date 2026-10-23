/* ============================================================================
 * board.c —— 五子棋棋盘与判胜的实现（轨道 C）
 * ----------------------------------------------------------------------------
 * [!] 本文件【不用任何 libc】—— 只有 <stdint.h> 经 board.h 传进来。
 *     不用 memset/memcpy/printf/assert，因为它要能原样编进 RV32 裸机固件。
 *     两处清零写成显式循环（N=15 时 225 个字节，编译器会自己展开）。
 *
 * 判胜是【增量】的：只从刚落的那一格沿 4 个方向数，O(1)；
 * 不是每次全盘扫。全盘扫只留了一份 gomoku_scan_winner() 给单测对拍用。
 * ==========================================================================*/
#include "board.h"

/* 4 个方向：横 / 竖 / 斜 "\" / 斜 "/"
 * 只取"正方向" (dr,dc)，反方向由取负得到。 */
static const int8_t GOMOKU_DR[4] = { 0, 1, 1,  1 };
static const int8_t GOMOKU_DC[4] = { 1, 0, 1, -1 };

static inline int in_range(int r, int c)
{
    return (r >= 0 && r < GOMOKU_N && c >= 0 && c < GOMOKU_N);
}

/* 从 (r,c) 出发，沿 (dr,dc) 方向数连续的 who，不含起点本身。 */
static int count_dir(const gomoku_t *g, int r, int c, int dr, int dc, int who)
{
    int n = 0;
    int rr = r + dr;
    int cc = c + dc;
    while (in_range(rr, cc) && g->cell[rr][cc] == who) {
        n++;
        rr += dr;
        cc += dc;
    }
    return n;
}

int gomoku_run_len(const gomoku_t *g, int r, int c, int who)
{
    int best = 0;
    int d;

    if (!in_range(r, c)) return 0;
    /* 该点已被对方占住 -> 这一个方向都谈不成 */
    if (g->cell[r][c] != GOMOKU_EMPTY && g->cell[r][c] != who) return 0;

    for (d = 0; d < 4; d++) {
        int n = 1
              + count_dir(g, r, c,  GOMOKU_DR[d],  GOMOKU_DC[d], who)
              + count_dir(g, r, c, -GOMOKU_DR[d], -GOMOKU_DC[d], who);
        if (n > best) best = n;
    }
    return best;
}

void gomoku_reset(gomoku_t *g)
{
    int r, c;
    for (r = 0; r < GOMOKU_N; r++)
        for (c = 0; c < GOMOKU_N; c++)
            g->cell[r][c] = GOMOKU_EMPTY;

    g->stones   = 0;
    g->turn     = GOMOKU_BLACK;   /* 黑先 */
    g->last_r   = -1;
    g->last_c   = -1;
    g->last_who = GOMOKU_EMPTY;
    g->run_len  = 0;
    g->winner   = 0;
}

int gomoku_place(gomoku_t *g, int r, int c)
{
    uint8_t who;
    int     n;

    if (!in_range(r, c))                 return GOMOKU_ERR_RANGE;
    if (g->cell[r][c] != GOMOKU_EMPTY)   return GOMOKU_ERR_OCCUPIED;
    if (g->winner != 0)                  return GOMOKU_ERR_OVER;

    who = g->turn;
    g->cell[r][c] = who;
    g->stones++;
    g->last_r   = (int8_t)r;
    g->last_c   = (int8_t)c;
    g->last_who = who;

    n = gomoku_run_len(g, r, c, who);
    g->run_len = (uint8_t)(n > 255 ? 255 : n);
    if (n >= GOMOKU_WIN_LEN) g->winner = who;

    g->turn = (who == GOMOKU_BLACK) ? GOMOKU_WHITE : GOMOKU_BLACK;
    return GOMOKU_OK;
}

/* ---------------------------------------------------------------------------
 * 全盘扫描判胜 —— 只给单测做"增量判胜"的对拍基准，固件里不调用。
 * 只往"正方向"数，避免同一条连子被数 4 遍。
 * ------------------------------------------------------------------------- */
int gomoku_scan_winner(const gomoku_t *g)
{
    int r, c, d;

    for (r = 0; r < GOMOKU_N; r++) {
        for (c = 0; c < GOMOKU_N; c++) {
            uint8_t v = g->cell[r][c];
            if (v != GOMOKU_BLACK && v != GOMOKU_WHITE) continue;
            for (d = 0; d < 4; d++) {
                /* 只要"起点"（反方向没有同色子），每条连子就只会被数一次 */
                int pr = r - GOMOKU_DR[d];
                int pc = c - GOMOKU_DC[d];
                if (in_range(pr, pc) && g->cell[pr][pc] == v) continue;

                if (count_dir(g, r, c, GOMOKU_DR[d], GOMOKU_DC[d], v) + 1
                    >= GOMOKU_WIN_LEN)
                    return v;
            }
        }
    }
    return 0;
}
