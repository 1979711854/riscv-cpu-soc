/* ============================================================================
 * game.h —— 对局状态机（轨道 B2/B3）
 * ----------------------------------------------------------------------------
 * 标题屏 → 对局 → 胜负 → 回标题。光标移动/落子、轮到谁、AI 何时出手，都在这里。
 *
 * [!] 本文件**不碰硬件**：时间由调用方传进来（now），按键由调用方取成掩码传进来，
 *     画面更新交给 render.*，AI 交给 ai.*。所以整个对局逻辑能在 PC 上跑完整盘。
 *
 * 按键方案（板上只有 4 个用户键 SW4..SW7 = key[0..3]，见 input.h 的论证）：
 *
 *   标题屏（标准竖排菜单，任务 T6 阶段 1）
 *       短按 ↑/↓  移动选中项（页内回绕）
 *       长按任意键  主菜单 = 进入子菜单；子菜单「开始对局」= 开始对局
 *       短按 ←/→  参数项上改值（回绕）；短按 ← 在「开始对局」上 = 返回上一层
 *   对局中    短按 ←/→/↑/↓ 移动光标   长按任意方向键 在光标处落子
 *   胜负后    长按任意键 回标题
 *   AI 对弈（原演示模式）  双方都是 AI，按 step_ms 间隔落子；长按回标题
 *
 * [!] AI 是在 game_tick() 里**派单**（game_ai_begin），真正的搜索由宿主决定怎么跑：
 *     裸机/x86 同步算完，RT-Thread 丢给低优先级 AI 线程。见 game_ai_begin 的注释。
 * ==========================================================================*/
#ifndef GOMOKU_GAME_H
#define GOMOKU_GAME_H

#include <stdint.h>
#include "board.h"
#include "ai.h"

typedef enum {
    GAME_TITLE = 0,     /* 标题屏：多级菜单 */
    GAME_PLAYING,       /* 对局中 */
    GAME_OVER,          /* 已分胜负或平局 */
    GAME_COREMARK       /* CoreMark 终端演示屏（SW6+SW7 复位彩蛋，T7，见 coremark_screen.c）*/
} game_phase_t;

/* 对局模式（任务 T2）*/
typedef enum {
    GAME_MODE_HUMAN = 0,   /* 人机对弈 */
    GAME_MODE_AI    = 1    /* AI 对弈（原演示模式：双方都是 AI）*/
} game_mode_t;

/* 标题屏菜单的页面（任务 T6 阶段 1：标准菜单）。每页是「选中项下标 + 每项的值」，
 * 不再是 T2 的「每层一个参数」。交互与每项取值见 game.c 的 tick_title。 */
typedef enum {
    MENU_PAGE_MAIN = 0,    /* 主菜单：HUMAN VS AI / AI VS AI */
    MENU_PAGE_HUMAN,       /* 人机子菜单：难度 / 执子 / 开始对局 */
    MENU_PAGE_AI           /* AI 子菜单：黑方 / 白方 / 间隔 / 开始对局 */
} menu_page_t;

typedef struct {
    gomoku_t     board;
    game_phase_t phase;

    int cursor_r, cursor_c;     /* 光标位置（交叉点坐标） */
    int cursor_on;              /* 闪烁：这一拍光标画不画 */
    int cursor_hidden;          /* 落子后临时藏起光标 —— 见 game_cursor_shown 的说明 */
    uint32_t t_blink;           /* 上次翻转时刻 */
    uint32_t blink_ticks;       /* 半周期（单位与 now 相同）*/

    int      mode;              /* GAME_MODE_HUMAN / GAME_MODE_AI（AI 对弈=原演示）*/
    int      human;             /* 人机模式下人执哪一方（GOMOKU_BLACK / GOMOKU_WHITE）*/
    int      level_black;       /* 黑方 AI 难度（AI_EASY / AI_NORMAL / AI_HARD）*/
    int      level_white;       /* 白方 AI 难度 */
    uint32_t step_ms;           /* AI 对弈每手间隔（毫秒）*/
    int      menu_page;         /* 标题屏菜单当前页（menu_page_t）*/
    int      menu_cursor;       /* 菜单当前选中项下标（0-based，页内回绕）*/
    int      winner;            /* 0 = 未分胜负 */

    /* AI 对弈（原演示模式）：双方都是 AI，每手之间停 demo_delay。 */
    uint32_t demo_delay;        /* 每手之间的间隔（单位与 now 相同，宿主按 step_ms 换算）*/
    uint32_t t_next_ai;         /* AI 对弈模式下下一手 AI 的时刻 */

    /* AI 最近一步的统计 —— 给上层打串口用（工作清单要求"打印节点数/耗时"）*/
    uint32_t ai_nodes;
    uint32_t ai_ms;
    int      ai_depth;
    int      ai_moves;          /* AI 一共走了几步 */
    int      last_ai_r, last_ai_c;  /* AI 最近一手（-1 = 还没走过）*/

    /* G3 异步 AI：派单时的棋盘副本 + 是否在等结果。
     * game_tick 内部只调 game_ai_begin（快、不阻塞、只置 ai_pending 并拷盘）；
     * 真正的搜索由宿主决定怎么跑 —— 裸机/x86 同步算完，RT-Thread 丢给低优先级 AI 线程。 */
    gomoku_t ai_snap;           /* AI 只搜这个副本，绝不动真盘 board */
    int      ai_pending;        /* 1 = 已派单、等 AI 结果 */
    uint32_t ai_gen;            /* 派单序号：每次 game_ai_begin 自增，宿主据此丢弃过期结果 */
} game_t;

/* 初始化并进入标题屏（菜单顶层）。
 *   level        = 黑白双方难度的初始值（人机模式两边同步，AI 对弈里再分别改）
 *   human        = 人机模式下人的初始执子（GOMOKU_BLACK / GOMOKU_WHITE）
 *   blink_ticks  = 光标闪烁半周期（单位与 now 相同）
 * 其余字段给默认值：mode=HUMAN、step_ms=1000、menu_page=MENU_PAGE_MAIN、menu_cursor=0。 */
void game_init(game_t *gm, int level, int human, uint32_t blink_ticks);

/* 推进一拍。
 *   now        = 当前时刻
 *   short_mask = bit k = 这一拍有 key k 的【短按】事件
 *   long_mask  = bit k = 这一拍有 key k 的【长按】事件
 * 调用方每拍从 input.c 取完事件后调它一次。 */
void game_tick(game_t *gm, uint32_t now, uint8_t short_mask, uint8_t long_mask);

/* 现在轮到 AI 吗（标题屏/胜负后不算）*/
int game_ai_turn(const game_t *gm);

/* 现在轮到谁，就按谁的难度取 —— 黑取 level_black、白取 level_white。
 * 供 game_ai_run_sync / RT-Thread 宿主派单时把「这一手是谁的难度」带进 ai_cmd。 */
int game_ai_level(const game_t *gm);

/* 标准菜单：当前页的菜单项数（主菜单 2 / 人机 3 / AI 4）。供 HUD 与测试枚举。 */
int game_menu_item_count(const game_t *gm);

/* 按当前 mode/human/难度/step_ms 的配置开始一局（清盘清统计 → 进对局 →
 * AI 对弈停一拍再下第一手、人机且人执白时 AI 先走）。菜单末层确认时调用，
 * 也暴露给测试直接开局。 */
void game_start(game_t *gm, uint32_t now);

/* 光标是否要画出来。
 * [!] **AI VS AI 下一律不画**（2026-10-17 加）—— 光标是给人类玩家的操作指示，
 *     双方都是 AI 时它只会在棋盘中间一直闪，干扰观感。用户上板反馈要求去掉。
 * [!] 落子之后会【临时藏起来】，直到玩家再按方向键。原因：显示层没有精灵，
 *     光标和棋子占用的是【同一层的同一块图块】—— 光标画着就看不见底下的子。
 *     而刚落完子那一拍恰恰是玩家最想确认自己下在哪的时候，所以让它先消失，
 *     一按键（反正要挪光标了）立刻回来。
 *     另一条路是给 9 种网格形状各加 黑/白 两个带光标的图块（+18 块 = +4.6KB），
 *     但 32KB 里那 4.6KB 更该留给后面加字库。 */
int game_cursor_shown(const game_t *gm);

/* ---- 异步 AI（G3）----------------------------------------------------------
 * 「该不该下」和「下在哪」拆成两步：game_tick 内部只调 game_ai_begin
 * （幂等派单，置 ai_pending 并拷盘，立即返回、绝不阻塞）；搜索由宿主跑 ——
 * 裸机/x86 用 game_ai_run_sync 同步算完，RT-Thread 把 ai_snap 丢给低优先级
 * AI 线程、算完再 game_ai_finish 落子。 */
int game_ai_begin(game_t *gm);
int game_ai_finish(game_t *gm, uint32_t now, int r, int c, const ai_stats_t *st);
const gomoku_t *game_ai_snapshot(const game_t *gm);
int game_ai_run_sync(game_t *gm, uint32_t now, ai_stats_t *out_st);

#endif /* GOMOKU_GAME_H */
