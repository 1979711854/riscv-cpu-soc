/* ============================================================================
 * gomoku_cli.c —— 终端里的五子棋人机对战（只在 PC 上跑）
 * ----------------------------------------------------------------------------
 * 运行：  scripts\gomoku\play.ps1
 * 或手动：gcc -std=c99 -O2 board.c ai.c gomoku_cli.c -o gomoku.exe && gomoku.exe
 *
 * 这是工作清单 M0「PC 上的 AI 原型跑通 —— 能自对弈整局，打印节点数/耗时」
 * 的落地物：**不需要板子、不需要显示器**，坐在这儿就能试 AI 强弱。
 *
 * 每步 AI 走完会打印：【节点数 / 实际搜索深度 / 耗时(ms) / 评分】——
 * 那四个数就是 D4（内存与时间预算）的唯一判据，也是上板标定的基准。
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "board.h"
#include "ai.h"

#ifdef _WIN32
#include <windows.h>
#endif

#define HIST_MAX (GOMOKU_N * GOMOKU_N)

static const char *g_level_name[3] = { "EASY(贪心)", "NORMAL(4层)", "HARD(6层)" };

/* --------------------------------------------------------------------------- */
static void print_board(const gomoku_t *g)
{
    int r, c;
    printf("\n     ");
    for (c = 0; c < GOMOKU_N; c++) printf("%c ", 'A' + c);
    printf("\n");
    for (r = 0; r < GOMOKU_N; r++) {
        printf("  %2d ", r + 1);
        for (c = 0; c < GOMOKU_N; c++) {
            char ch = '.';
            if (g->cell[r][c] == GOMOKU_BLACK) ch = 'X';
            else if (g->cell[r][c] == GOMOKU_WHITE) ch = 'O';
            printf("%c ", ch);
        }
        printf("\n");
    }
    printf("     ");
    for (c = 0; c < GOMOKU_N; c++) printf("%c ", 'A' + c);
    printf("\n");
}

/* "H8" -> (7,7)；也接受 "7 7" / "7,7"（0 基）。成功返回 1。 */
static int parse_move(const char *s, int *r, int *c)
{
    int a, b;
    char ch;

    while (*s == ' ' || *s == '\t') s++;

    if (sscanf(s, " %c%d ", &ch, &a) == 2) {
        if (ch >= 'a' && ch <= 'z') ch = (char)(ch - 'a' + 'A');
        if (ch >= 'A' && ch < 'A' + GOMOKU_N && a >= 1 && a <= GOMOKU_N) {
            *c = ch - 'A';
            *r = a - 1;
            return 1;
        }
    }
    if (sscanf(s, " %d%*[ ,]%d ", &a, &b) == 2) {
        if (a >= 0 && a < GOMOKU_N && b >= 0 && b < GOMOKU_N) {
            *r = a; *c = b;
            return 1;
        }
    }
    return 0;
}

static void print_help(void)
{
    printf("  落子：输入列字母+行号，如 H8 = 正中天元；也接受 7 7 或 7,7（0 基）\n");
    printf("  q 退出   n 重开   u 悔一步（人机各退一手）   + 加难度   - 降难度\n");
    printf("  [!] 命令都是【单个字符】。别用带参数的字母命令 —— 列字母是 A-O，\n");
    printf("      L2 这种既是「L 列第 2 行」的合法落子、又像是命令，没法区分。\n");
}

/* --------------------------------------------------------------------------- */
int main(int argc, char **argv)
{
    gomoku_t g;
    int level   = AI_NORMAL;
    int human   = GOMOKU_BLACK;      /* 默认人执黑先手 */
    int hist[HIST_MAX][2];
    int nhist = 0;
    int i;
    char line[128];

#ifdef _WIN32
    /* [!] 本文件的所有界面文字是 UTF-8 字节，而中文 Windows 的控制台默认代码页是
     *     GBK(cp936) —— 不设这一句，棋盘和提示全是乱码。
     *     这里设一次，是为了让【直接双击 gomoku.exe】也能正常显示；
     *     走 play.ps1 时脚本那边也会设（两道保险，互不冲突）。 */
    SetConsoleOutputCP(65001);
#endif

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-white") == 0) human = GOMOKU_WHITE;
        else if (strcmp(argv[i], "-easy")   == 0) level = AI_EASY;
        else if (strcmp(argv[i], "-hard")   == 0) level = AI_HARD;
        else if (strcmp(argv[i], "-normal") == 0) level = AI_NORMAL;
    }

    gomoku_reset(&g);

    printf("=== 五子棋（你 %s）===\n", human == GOMOKU_BLACK ? "执黑 X，先手" : "执白 O，后手");
    printf("  AI 难度：%s\n", g_level_name[level]);
    print_help();
    print_board(&g);

    while (g.winner == 0 && !gomoku_is_full(&g)) {
        if (g.turn == human) {
            int r, c;
            char cmd = 0;
            const char *p;

            printf("你走 > ");
            fflush(stdout);
            if (!fgets(line, sizeof(line), stdin)) break;

            /* [!] 先试解析成【落子】，解析不出来才当命令。
             * 反过来的话，列字母 A-O 会和命令字母 h/n/l/u/q 撞车 ——
             * 实测 `H8` 以 'H' 开头会被当成 help、`N7` 被当成重开、`L10` 被当成换难度。 */
            if (!parse_move(line, &r, &c)) {
                p = line;
                while (*p == ' ' || *p == '\t') p++;
                cmd = *p;
                if (cmd >= 'a' && cmd <= 'z') cmd = (char)(cmd - 'a' + 'A');

                if (cmd == 'Q') { printf("再见。\n"); return 0; }

                if (cmd == 'N') {
                    gomoku_reset(&g); nhist = 0;
                    printf("--- 重开 ---\n"); print_board(&g);
                    continue;
                }
                if (cmd == 'H' || cmd == '?') { print_help(); continue; }

                /* 难度用 + / - 调，不用 "l <n>" —— 见 print_help 里的说明 */
                if (cmd == '+') {
                    if (level < AI_HARD) level++;
                    printf("  难度 -> %s\n", g_level_name[level]);
                    continue;
                }
                if (cmd == '-') {
                    if (level > AI_EASY) level--;
                    printf("  难度 -> %s\n", g_level_name[level]);
                    continue;
                }
                if (cmd == 'U') {
                    /* 退两手（AI 一手 + 我一手），保证又轮到我走 */
                    int k = 0;
                    while (k < 2 && nhist > 0) {
                        nhist--;
                        g.cell[hist[nhist][0]][hist[nhist][1]] = GOMOKU_EMPTY;
                        g.stones--;
                        k++;
                    }
                    /* 该谁走按已下子数推 —— 比逐手翻转 turn 可靠，也不会被 winner 搅乱 */
                    g.turn = (g.stones % 2 == 0) ? GOMOKU_BLACK : GOMOKU_WHITE;
                    g.winner = 0;
                    printf("--- 悔棋后 ---\n"); print_board(&g);
                    continue;
                }

                printf("  看不懂，例：H8 / 7 7 / 7,7；命令见 h\n");
                continue;
            }

            {
                int ret = gomoku_place(&g, r, c);
                if (ret != GOMOKU_OK) {
                    printf("  这一手不行：%s\n",
                           ret == GOMOKU_ERR_OCCUPIED ? "该点已有子" :
                           ret == GOMOKU_ERR_RANGE    ? "越界" : "其它");
                    continue;
                }
                hist[nhist][0] = r; hist[nhist][1] = c; nhist++;
            }
            print_board(&g);
        } else {
            /* ---- AI 走 ---- */
            ai_stats_t st;
            int r = -1, c = -1;
            clock_t t0, t1;
            double ms;
            int ret;

            printf("AI 思考中（%s）...\n", g_level_name[level]);
            fflush(stdout);

            t0 = clock();
            ret = ai_choose_move(&g, level, &r, &c, &st);
            t1 = clock();
            ms = (double)(t1 - t0) * 1000.0 / CLOCKS_PER_SEC;

            if (ret != GOMOKU_OK) { printf("  AI 无子可下。\n"); break; }

            printf("  AI 走 %c%d   节点 %u / 深度 %d / 耗时 %.1f ms / 评分 %d%s\n",
                   'A' + c, r + 1, st.nodes, (int)st.depth, ms, st.score,
                   st.aborted ? "  [触到节点预算，用的是上一轮结果]" : "");

            if (gomoku_place(&g, r, c) != GOMOKU_OK) { printf("  !! AI 给出的点非法，内部错误\n"); break; }
            hist[nhist][0] = r; hist[nhist][1] = c; nhist++;
            print_board(&g);
        }
    }

    printf("\n=== 对局结束：");
    if (g.winner == GOMOKU_BLACK)      printf("黑 X 胜 ===\n");
    else if (g.winner == GOMOKU_WHITE) printf("白 O 胜 ===\n");
    else                               printf("平局（棋盘已满）===\n");

    return 0;
}
