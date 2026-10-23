/* ============================================================================
 * game.c —— 对局状态机的实现（轨道 B2/B3）
 * ----------------------------------------------------------------------------
 * 纯逻辑：不碰任何硬件。时间、按键、画面、AI 都由外部注入。
 * ==========================================================================*/
#include "game.h"
#include "input.h"

/* 光标默认起点：天元（棋盘正中） */
#define CURSOR_HOME_R (GOMOKU_N / 2)
#define CURSOR_HOME_C (GOMOKU_N / 2)

static int clamp(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void game_init(game_t *gm, int level, int human, uint32_t blink_ticks)
{
    gomoku_reset(&gm->board);
    gm->phase        = GAME_TITLE;
    gm->cursor_r     = CURSOR_HOME_R;
    gm->cursor_c     = CURSOR_HOME_C;
    gm->cursor_on    = 1;
    gm->cursor_hidden= 0;
    gm->t_blink      = 0;
    gm->blink_ticks  = blink_ticks ? blink_ticks : 1;
    gm->mode         = GAME_MODE_HUMAN;
    gm->human        = human;
    gm->level_black  = level;
    gm->level_white  = level;
    gm->step_ms      = 1000;
    gm->menu_page    = MENU_PAGE_MAIN;
    gm->menu_cursor  = 0;
    gm->demo_delay   = blink_ticks ? blink_ticks : 1;  /* 宿主稍后按 step_ms 覆盖 */
    gm->t_next_ai    = 0;
    gm->winner       = 0;
    gm->ai_nodes     = 0;
    gm->ai_ms        = 0;
    gm->ai_depth     = 0;
    gm->ai_moves     = 0;
    gm->last_ai_r    = -1;
    gm->last_ai_c    = -1;
    gm->ai_pending   = 0;
    gm->ai_gen       = 0;
}

/* 处理一次落子后的公共收尾：判胜负、切阶段 */
static void after_move(game_t *gm)
{
    if (gm->board.winner) {
        gm->winner = gm->board.winner;
        gm->phase  = GAME_OVER;
    } else if (gomoku_is_full(&gm->board)) {
        gm->winner = 0;
        gm->phase  = GAME_OVER;            /* 平局 */
    }
}

/* ---------------------------------------------------------------------------
 * 异步 AI（G3）：把「该不该下」和「下在哪」拆成两步。
 *   game_ai_begin —— game_tick 内部调，只在轮到 AI 时置 ai_pending=1 并拷盘，
 *                    立即返回、绝不阻塞。
 *   真正的搜索由宿主决定怎么跑：裸机/x86 用 game_ai_run_sync 同步算完；
 *   RT-Thread 把 ai_snap 丢给低优先级 AI 线程，算完再 game_ai_finish 落子。
 * ------------------------------------------------------------------------- */
int game_ai_begin(game_t *gm)
{
    if (!game_ai_turn(gm)) return 0;      /* 没轮到 AI / 不在对局中 */
    if (gm->ai_pending)    return 0;      /* 已有在途任务，别重复派 */
    gm->ai_snap    = gm->board;           /* 拷盘：之后 AI 只搜这个副本 */
    gm->ai_gen++;                         /* 每派一次单加一号，宿主据此丢弃过期结果 */
    gm->ai_pending = 1;
    return 1;
}

int game_ai_finish(game_t *gm, uint32_t now, int r, int c, const ai_stats_t *st)
{
    int ret = gomoku_place(&gm->board, r, c);
    if (ret != GOMOKU_OK) { gm->ai_pending = 0; return ret; }  /* 非法点=内部错，放行 */

    gm->ai_nodes   = st->nodes;
    gm->ai_depth   = (int)st->depth;
    gm->ai_moves++;
    gm->last_ai_r  = r;
    gm->last_ai_c  = c;
    if (gm->board.winner) gm->winner = gm->board.winner;

    after_move(gm);                       /* 判胜负 / 平局 / 切阶段 */

    if (gm->mode == GAME_MODE_AI) gm->t_next_ai = now + gm->demo_delay;   /* AI 对弈：下一手隔 demo_delay */
    gm->ai_pending = 0;
    return GOMOKU_OK;
}

const gomoku_t *game_ai_snapshot(const game_t *gm)
{
    return &gm->ai_snap;
}

/* 同步便捷封装：立即算完并落子。返回 1 = 真的走了一步；out_st 可空回填统计。 */
int game_ai_run_sync(game_t *gm, uint32_t now, ai_stats_t *out_st)
{
    ai_stats_t st;
    int r = -1, c = -1;
    int ret;

    if (!gm->ai_pending) return 0;

    ret = ai_choose_move(game_ai_snapshot(gm), game_ai_level(gm), &r, &c, &st);
    if (out_st) *out_st = st;
    if (ret == GOMOKU_OK) {
        return (game_ai_finish(gm, now, r, c, &st) == GOMOKU_OK);
    }
    gm->ai_pending = 0;                   /* 算不出来（不该发生），放行 */
    return 0;
}

int game_ai_turn(const game_t *gm)
{
    if (gm->phase != GAME_PLAYING) return 0;
    if (gm->mode == GAME_MODE_AI) return 1;   /* AI 对弈：双方都是 AI */
    return (gm->board.turn != gm->human);
}

int game_ai_level(const game_t *gm)
{
    return (gm->board.turn == GOMOKU_BLACK) ? gm->level_black : gm->level_white;
}

int game_cursor_shown(const game_t *gm)
{
    /* [2026-10-17] **AI VS AI 下不画光标**：光标是给人类玩家的操作指示，
     *   双方都是 AI 时没有"人"，它只会在棋盘中间一直闪（红色圈圈），纯粹干扰观感。
     *   用户 2026-10-17 上板反馈："AI 下棋，中间还是会有红色圈圈光标闪烁，应该考虑去掉"。
     *   [!] 人机模式下行为【不变】：仍按 cursor_on（闪烁节拍）与 cursor_hidden
     *       （落子后 AI 思考期间隐藏）决定，见 game.h 的说明。 */
    if (gm->mode != GAME_MODE_HUMAN) return 0;
    return (gm->phase == GAME_PLAYING && gm->cursor_on && !gm->cursor_hidden) ? 1 : 0;
}

/* ---- 菜单选项循环（到头回绕）-------------------------------------------- */
static int level_next(int l) { return l >= AI_HARD ? AI_EASY : l + 1; }
static int level_prev(int l) { return l <= AI_EASY ? AI_HARD : l - 1; }

static uint32_t step_next(uint32_t ms)
{
    if (ms >= 2000) return 500;
    if (ms >= 1000) return 2000;
    return 1000;                             /* 500 -> 1000 */
}
static uint32_t step_prev(uint32_t ms)
{
    if (ms <= 500)  return 2000;
    if (ms <= 1000) return 500;
    return 1000;                             /* 2000 -> 1000 */
}

static int color_next(int c) { return c == GOMOKU_BLACK ? GOMOKU_WHITE : GOMOKU_BLACK; }
#define color_prev(c) color_next(c)          /* 黑/白只有两档，prev == next */

/* ---- 标准菜单（任务 T6 阶段 1）的页内结构 -------------------------------- */

/* 当前页的菜单项数：主 2 / 人机 3 / AI 4。 */
int game_menu_item_count(const game_t *gm)
{
    return gm->menu_page == MENU_PAGE_MAIN  ? 2 :
           gm->menu_page == MENU_PAGE_HUMAN ? 3 : 4;
}

/* 当前选中项是不是「参数项」（能用 ←/→ 改值）。 */
static int menu_is_value(const game_t *gm)
{
    return (gm->menu_page == MENU_PAGE_HUMAN && gm->menu_cursor < 2) ||
           (gm->menu_page == MENU_PAGE_AI    && gm->menu_cursor < 3);
}

/* 当前选中项是不是「开始对局」。 */
static int menu_is_start(const game_t *gm)
{
    return (gm->menu_page == MENU_PAGE_HUMAN && gm->menu_cursor == 2) ||
           (gm->menu_page == MENU_PAGE_AI    && gm->menu_cursor == 3);
}

/* ← 返回上一层：子菜单 → 主菜单（选中项回到刚才的模式）；主菜单无操作。 */
static void menu_go_back(game_t *gm)
{
    if (gm->menu_page == MENU_PAGE_HUMAN) {
        gm->menu_page   = MENU_PAGE_MAIN;
        gm->menu_cursor = GAME_MODE_HUMAN;      /* 回到「HUMAN VS AI」这一项 */
    } else if (gm->menu_page == MENU_PAGE_AI) {
        gm->menu_page   = MENU_PAGE_MAIN;
        gm->menu_cursor = GAME_MODE_AI;         /* 回到「AI VS AI」这一项 */
    }
    /* 主菜单上 ← 无操作 */
}

/* 按 (page,cursor) 改当前参数项的值。forward=1 下一个 / 0 上一个。 */
static void menu_value_step(game_t *gm, int forward)
{
    switch (gm->menu_page) {
    case MENU_PAGE_HUMAN:
        if (gm->menu_cursor == 0) {              /* 难度：人机黑白同步 */
            gm->level_black = forward ? level_next(gm->level_black) : level_prev(gm->level_black);
            gm->level_white = gm->level_black;
        } else if (gm->menu_cursor == 1) {       /* 执子 */
            gm->human = forward ? color_next(gm->human) : color_prev(gm->human);
        }
        break;
    case MENU_PAGE_AI:
        if (gm->menu_cursor == 0)
            gm->level_black = forward ? level_next(gm->level_black) : level_prev(gm->level_black);
        else if (gm->menu_cursor == 1)
            gm->level_white = forward ? level_next(gm->level_white) : level_prev(gm->level_white);
        else if (gm->menu_cursor == 2)
            gm->step_ms = forward ? step_next(gm->step_ms) : step_prev(gm->step_ms);
        break;
    default:
        break;
    }
}

/* ---------------------------------------------------------------------------
 * 开始一局：按当前 mode/human/难度/step_ms 的配置清盘清统计 → 进对局。
 * AI 对弈空盘先停一拍再下第一手；人机且人执白时 AI 先走（避免主循环再开特例）。
 * ------------------------------------------------------------------------- */
void game_start(game_t *gm, uint32_t now)
{
    gomoku_reset(&gm->board);
    gm->winner        = 0;
    gm->ai_nodes      = 0;
    gm->ai_ms         = 0;
    gm->ai_depth      = 0;
    gm->ai_moves      = 0;
    gm->last_ai_r     = -1;
    gm->last_ai_c     = -1;
    gm->ai_pending    = 0;
    gm->cursor_r      = CURSOR_HOME_R;
    gm->cursor_c      = CURSOR_HOME_C;
    gm->cursor_on     = 1;
    gm->cursor_hidden = 0;
    gm->phase         = GAME_PLAYING;

    if (gm->mode == GAME_MODE_AI) {
        gm->t_next_ai = now + gm->demo_delay;   /* 空盘先停一拍再下第一手 */
    } else if (gm->board.turn != gm->human) {
        game_ai_begin(gm);                       /* 人执白，AI 先走 */
    }
}

/* ---------------------------------------------------------------------------
 * 标题屏：标准竖排菜单（任务 T6 阶段 1）
 *   短按 ↑/↓ 移动选中项；短按 ←/→ 在参数项上改值；长按任意键确认。
 *   「开始对局」项上：长按 = 开局，短按 ← = 返回上一层。
 * ------------------------------------------------------------------------- */
static void tick_title(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask)
{
    int up    = (short_mask & (1u << KEY_UP))    != 0;
    int down  = (short_mask & (1u << KEY_DOWN))  != 0;
    int left  = (short_mask & (1u << KEY_LEFT))  != 0;
    int right = (short_mask & (1u << KEY_RIGHT)) != 0;

    /* 长按任意键 = 确认：主菜单进子菜单；「开始对局」开局；参数项无操作。 */
    if (long_mask != 0) {
        if (gm->menu_page == MENU_PAGE_MAIN) {
            gm->mode        = (gm->menu_cursor == 0) ? GAME_MODE_HUMAN : GAME_MODE_AI;
            gm->menu_page   = (gm->mode == GAME_MODE_HUMAN) ? MENU_PAGE_HUMAN : MENU_PAGE_AI;
            gm->menu_cursor = 0;
        } else if (menu_is_start(gm)) {
            game_start(gm, now);
        }
        return;
    }

    if (left) {
        if (menu_is_value(gm)) menu_value_step(gm, 0);   /* 参数项：← 上一个值 */
        else                   menu_go_back(gm);          /* 开始对局：← 返回上一层 */
        return;
    }
    if (right) {
        if (menu_is_value(gm)) menu_value_step(gm, 1);   /* 参数项：→ 下一个值 */
        return;
    }

    if (up || down) {
        int n   = game_menu_item_count(gm);
        int inc = down ? 1 : -1;                          /* ↑ = 上一项，↓ = 下一项 */
        gm->menu_cursor = (gm->menu_cursor + inc + n) % n;
        if (gm->menu_page == MENU_PAGE_MAIN) gm->mode = gm->menu_cursor;  /* 主菜单移动即选模式 */
    }
}

/* ---------------------------------------------------------------------------
 * 对局中：短按方向移动光标；长按方向落子
 * ------------------------------------------------------------------------- */
static void tick_playing(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask)
{
    int dr = 0, dc = 0;

    if (gm->mode == GAME_MODE_AI) {
        /* AI 对弈：忽略人类按键，按节拍让 AI 走；长按任意键 = 中途退回标题。 */
        if (long_mask) {
            gomoku_reset(&gm->board);
            gm->winner = 0;
            gm->ai_pending = 0;
            gm->phase  = GAME_TITLE;
            gm->menu_page   = MENU_PAGE_MAIN;   /* 回标题菜单也回主菜单 */
            gm->menu_cursor = 0;
            return;
        }
        if ((int32_t)(now - gm->t_next_ai) >= 0) {
            game_ai_begin(gm);   /* 派单；落子与 t_next_ai 在 game_ai_finish 里推进 */
        }
        return;
    }

    if (!game_ai_turn(gm)) {                /* AI 思考时不吃按键 */
        if (short_mask & (1u << KEY_LEFT))  dc -= 1;
        if (short_mask & (1u << KEY_RIGHT)) dc += 1;
        if (short_mask & (1u << KEY_UP))    dr -= 1;
        if (short_mask & (1u << KEY_DOWN))  dr += 1;

        if (dr || dc) {
            gm->cursor_r = clamp(gm->cursor_r + dr, 0, GOMOKU_N - 1);
            gm->cursor_c = clamp(gm->cursor_c + dc, 0, GOMOKU_N - 1);
            gm->cursor_on     = 1;          /* 一移动就把光标点亮，别让它正好落在暗的半拍 */
            gm->cursor_hidden = 0;          /* 同时解除"落子后藏起来" */
            gm->t_blink       = now;        /* 闪烁计时从这次移动重新起算 */
        }

        /* 长按方向键 = 在【当前光标位置】落子。
         * 光标不会因为长按而移动 —— 短按才移动，这是 input.h 里那套时序的用意。 */
        if (long_mask) {
            int ret = gomoku_place(&gm->board, gm->cursor_r, gm->cursor_c);
            if (ret == GOMOKU_OK) {
                /* 落子成功 -> 先把光标藏起来，让玩家看清自己刚下的那一手。
                 * 理由见 game.h 的 game_cursor_shown 注释。 */
                gm->cursor_hidden = 1;
                after_move(gm);
                if (gm->phase == GAME_PLAYING && game_ai_turn(gm)) {
                    game_ai_begin(gm);   /* 派单；落子在 game_ai_finish 里做 */
                }
            }
            /* 落子失败（该点已有子）就什么都不做 —— 用户自己会再挪一格。
             * 不弹提示是因为 v1 没有文字，画面上"什么都没发生"已经够清楚。 */
        }
    }
}

/* ---------------------------------------------------------------------------
 * 胜负后：长按任意键回标题
 * ------------------------------------------------------------------------- */
static void tick_over(game_t *gm, uint32_t now, uint8_t long_mask)
{
    (void)now;
    if (long_mask) {
        gomoku_reset(&gm->board);
        gm->winner = 0;
        gm->ai_pending = 0;
        gm->phase  = GAME_TITLE;
        gm->menu_page   = MENU_PAGE_MAIN;
        gm->menu_cursor = 0;
    }
}

void game_tick(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask)
{
    /* ---- 光标闪烁（所有阶段都推进，切阶段时不会卡在暗的半拍）---- */
    if ((uint32_t)(now - gm->t_blink) >= gm->blink_ticks) {
        gm->t_blink    = now;
        gm->cursor_on  = !gm->cursor_on;
    }

    switch (gm->phase) {
    case GAME_TITLE:   tick_title(gm, now, short_mask, long_mask);   break;
    case GAME_PLAYING: tick_playing(gm, now, short_mask, long_mask); break;
    case GAME_COREMARK:
        /* CoreMark 终端演示屏（T7）：唯一交互 = 长按 SW6（key[2]）回标题。
         * [!] 画面与进度由 coremark_screen.c 的 cm_screen_tick 负责
         *     （draw_frame 每帧调），这里只管输入与相位切换；
         * [!] 其它按键一律吞掉 —— 演示屏后面没有对局状态可操作。 */
        if (long_mask & (1u << 2)) gm->phase = GAME_TITLE;
        break;
    default:           tick_over(gm, now, long_mask);                break;
    }
}
