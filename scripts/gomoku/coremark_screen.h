/* ============================================================================
 * coremark_screen.h —— CoreMark 终端演示屏（GAME_COREMARK，T7 2026-10-19）
 * ----------------------------------------------------------------------------
 * 规格来源：SW6+SW7 复位彩蛋（用户任务书）。A1 方案 = 「真实成绩的重放展示」：
 *   · 成绩/ticks/四个 CRC 从 0xFF00 邮箱读【上一次官方 SW6 跑分的结果】
 *     （mailbox 跨复位保留，见 cm_mailbox.h）；
 *   · 进度条/Iterations/Ticks/Time 按【该次真实总时长】的节奏重放一遍
 *     （~11 秒），[ RUNNING ] 闪烁 → [ PASS ]，金色大分数 + CRC OK；
 *   · 没有邮箱数据（官方跑分从未跑过）→ 灰字提示，仍然可以长按 SW6 返回。
 * [!] 它【不是】本次现算 —— RT-Thread 镜像塞不下 CoreMark（体积探测结论，
 *     2026-10-19），官方跑分口径也不允许测量期间写显存。演示效果与真跑一致，
 *     串口证据链仍然由官方裸机跑分档负责。
 *
 * 时序约定（draw_frame / gomoku_run 负责配对）：
 *   cm_screen_begin()  —— 进入相位时调一次（render_term_begin + 静态版式）
 *   cm_screen_tick()   —— 每帧调（动态行/进度条/闪烁/收尾）
 *   退出（长按 SW6）   —— game.c 把相位切回 GAME_TITLE，draw_frame 检测到
 *                         离开本相位后调 render_term_end() 恢复图块+调色板。
 * ==========================================================================*/
#ifndef GOMOKU_COREMARK_SCREEN_H
#define GOMOKU_COREMARK_SCREEN_H

#include <stdint.h>

/* 进入演示屏：调色板换黑 + 借图块合成终端字形 + 铺静态版式 + 读邮箱快照。 */
void cm_screen_begin(void);

/* 每帧推进一步：闪烁、每秒跳动的 Iterations/Ticks/Time、进度条、收尾[PASS]。 */
void cm_screen_tick(uint32_t now);

#endif /* GOMOKU_COREMARK_SCREEN_H */
