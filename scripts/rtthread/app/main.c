/* ============================================================================
 * main.c —— RT-Thread 版五子棋的入口线程（任务 T1 / G3：拆线程）
 * ----------------------------------------------------------------------------
 * 这是任务 H（单线程版，git 历史里）之后的第二步：把五子棋拆成两个线程，
 * 让 AI 思考期间画面照常刷新、光标照常闪：
 *
 *       render 线程（高优先） —— 跑 gomoku_run()。vblank 同步、按键采样、
 *                               状态机、刷屏全在它身上。它【不阻塞算棋】。
 *       AI    线程（低优先） —— 收到「该 AI 下」的消息后，在【副本盘】上跑
 *                               同步 ai_choose_move，算完把落点经消息发回，
 *                               render 线程再 game_ai_finish 落子。
 *
 * 线程间只用【邮箱】(rt_mb) 传指针，不用互斥锁 —— RT-Thread v5 的邮箱承载单个
 * rt_ubase_t（= 指针），msgpool 是 rt_ubase_t[]、size 是槽数。单飞（一次只挂
 * 一个任务）+ AI 只读副本盘、render 是唯一写真盘的人 ⇒ 无竞态。
 *
 * 两个【弱函数】被本文件【强覆盖】（gcc 弱符号链接；裸机版仍走空/同步实现）：
 *   gomoku_ai_pump()     —— render 线程每帧 game_tick 之后调，派单 + 非阻塞收结果
 *   video_vblank_yield() —— vblank 忙等里每圈让一次，render 睡 1ms 把 CPU 让给 AI
 *
 * [!] **AI 拆线程不是"会更快"**，是"思考期间画面不卡"。所以 AI 线程的优先级
 *     必须【低于】render，否则又变回单线程阻塞。
 * ==========================================================================*/

#include <rtthread.h>
#include <rthw.h>

#include "game.h"          /* game_t / game_ai_* / ai_stats_t（scripts/gomoku）*/
#include "board.h"         /* BOARD_SYSTEM_CLOCK_HZ —— 横幅里的主频从它来（别写死）*/

/* 五子棋的应用主体。**不叫 main** —— 见 scripts/gomoku/main_entry.c 的文件头：
 * 五子棋要同时支持裸机与 RT-Thread 两种宿主，两个 main() 会撞。
 * 本函数【不会返回】（内部 for(;;)）。 */
void gomoku_run(void);

/* ---- 邮箱消息：RT-Thread v5 邮箱承载单个 rt_ubase_t（= 指针）----
 * 静态结构体 + 单飞协议，不需要动态分配，也不会有竞态。 */
typedef struct { uint32_t gen; gomoku_t board; int level; }           ai_cmd_t;   /* render -> AI */
typedef struct { uint32_t gen; int r, c; int ret; ai_stats_t st; uint32_t ms; } ai_rsp_t; /* AI -> render */

static ai_cmd_t    ai_cmd;      /* 派单参数：副本盘 + 难度 */
static ai_rsp_t    ai_rsp;      /* 结果：落点 + 统计 + 耗时 */

/* 邮箱消息池（每槽一个 rt_ubase_t）。两槽留余量；单飞实际最多挂一条。 */
static rt_ubase_t  cmd_pool[2];
static rt_ubase_t  rsp_pool[2];
static struct rt_mailbox mb_cmd, mb_rsp;

static int         ai_dispatched;   /* render 线程：当前 ai_pending 是否已派给 AI 线程 */

/* ---- AI 线程：低优先，纯算。收到命令→算→发结果，循环。 ----
 * 栈 3KB：6 层 α-β 递归 + 调用链实测约 2KB，留 1KB 余量。
 * [!] 2026-10-19 T7 实踩：原来两个线程栈各 4KB，把堆挤到只剩 208B ⇒
 *     RT-Thread 连自己的 main 线程都创建不出来（`rt_application_init` 用
 *     rt_thread_create 从堆上分配 1024B 栈 + TCB）⇒ 串口只出 banner 就没了。
 *     两个线程各让 1KB，堆回到 ~2.2KB，main 线程 ~1.2KB 才放得下。 */
#define AI_STACK    3072
#define AI_PRIORITY 25            /* 低：render(12) 与主线程(10) 都会抢占它 */

static rt_uint8_t  ai_stack[AI_STACK];
static struct rt_thread ai_thread;

static void ai_entry(void *parameter)
{
    RT_UNUSED(parameter);
    rt_kprintf("[boot] gomoku ai thread running\n");

    for (;;) {
        rt_ubase_t p;
        if (rt_mb_recv(&mb_cmd, &p, RT_WAITING_FOREVER) != RT_EOK)
            continue;

        {
            ai_cmd_t *c = (ai_cmd_t *)p;
            rt_tick_t t0 = rt_tick_get();

            ai_rsp.gen = c->gen;
            ai_rsp.r = ai_rsp.c = -1;
            ai_rsp.ret = ai_choose_move(&c->board, c->level,
                                        &ai_rsp.r, &ai_rsp.c, &ai_rsp.st);
            /* 墙钟毫秒（含 render 抢占的一点点开销）。tick 周期 1ms，直接就是毫秒。 */
            ai_rsp.ms  = (uint32_t)(rt_tick_get() - t0);
        }
        rt_mb_send(&mb_rsp, (rt_ubase_t)&ai_rsp);
    }
}

/* ---------------------------------------------------------------------------
 * gomoku_ai_pump 的强定义：覆盖 gomoku/main.c 里的弱默认（同步算）。
 * render 线程每帧 game_tick 之后调一次。返回 1 = 这一帧真的落了 AI 的子。
 * ------------------------------------------------------------------------- */
int gomoku_ai_pump(game_t *gm, uint32_t now)
{
    rt_ubase_t p;

    /* 派单：ai_pending 从 0→1 的那一帧发一次（ai_dispatched 防止重复发）。
     * game_ai_begin 已经把棋盘拷进 gm->ai_snap，这里再拷给 AI 线程。 */
    if (gm->ai_pending && !ai_dispatched) {
        ai_cmd.gen   = gm->ai_gen;
        ai_cmd.board = *game_ai_snapshot(gm);
        ai_cmd.level = game_ai_level(gm);
        /* rt_mb_send 非阻塞：满了会返回 -RT_EFULL。单飞下不会满，但万一失败
         * 别置 ai_dispatched —— 下一帧重试。 */
        if (rt_mb_send(&mb_cmd, (rt_ubase_t)&ai_cmd) == RT_EOK)
            ai_dispatched = 1;
    }

    /* 收结果：非阻塞轮询，有就落子。 */
    if (rt_mb_recv(&mb_rsp, &p, RT_WAITING_NO) == RT_EOK) {
        ai_rsp_t *r = (ai_rsp_t *)p;
        ai_dispatched = 0;
        /* 结果可能过期（思考中玩家退回标题、或又开了一局）：gen 对不上就丢掉，
         * 绝不能让旧盘的落点落到新盘上。 */
        if (gm->ai_pending && r->gen == gm->ai_gen) {
            gm->ai_ms = r->ms;
            game_ai_finish(gm, now, r->r, r->c, &r->st);
            return 1;
        }
        return 0;
    }
    return 0;
}

/* ---------------------------------------------------------------------------
 * video_vblank_yield 的强定义：覆盖 video_port.c 里的弱空实现。
 * vblank 忙等里每圈睡 1ms —— render 线程不独占 CPU，低优先 AI 线程才能算棋。
 * 1ms 粒度 vs 480p@60 的 ~1.4ms vblank 窗：最坏迟 1ms 赶上一行，可接受。
 * ------------------------------------------------------------------------- */
void video_vblank_yield(void)
{
    rt_thread_mdelay(1);
}

/* ---- render 线程：高优先，跑 gomoku_run()。3KB（见 AI_STACK 上方说明）----
 * render_init 峰值约 1.7KB（cell32 1KB + quad 256B + tile 256B + 调用帧），
 * 3KB 留 1.3KB 余量。 */
#define RENDER_STACK    3072
#define RENDER_PRIORITY 12            /* 高：必须压过 AI(25)，思考期间照样刷屏 */

static rt_uint8_t  render_stack[RENDER_STACK];
static struct rt_thread render_thread;

static void render_entry(void *parameter)
{
    RT_UNUSED(parameter);
    rt_kprintf("[boot] gomoku render thread running\n");
    gomoku_run();                       /* 不返回 */
}

/* 主线程心跳周期（毫秒）。上板 5 秒足够看出"还活着"又不刷屏；
 * [!] 仿真必须调小 —— 5000ms @100MHz = 5 亿周期，iverilog 跑不完。 */
#ifndef HB_DELAY_MS
#define HB_DELAY_MS         5000
#endif

/* ---------------------------------------------------------------------------
 * main：RT-Thread 的 main 线程入口（由 rt_application_init 创建）
 * -------------------------------------------------------------------------*/
int main(void)
{
    rt_err_t err;

    /* 堆有多大 = link.ld 里 __heap_end - __heap_start。
     * 扩到 64KB 之后这个数应该有三万多 —— 打出来比事后猜"为什么 malloc 失败"省事。 */
    extern char __heap_start;
    extern char __heap_end;
    rt_uint32_t heap_size = (rt_uint32_t)(&__heap_end - &__heap_start);

    rt_kprintf("\n");
    /* [!] 版本自证（2026-10-10 加）：RT-Thread 自己的 banner 在上面，那一段
     *     两版位流完全一样；**能区分位流的是这行 RTL=** —— 它读的是 mimpid，
     *     常量在 rtl/core/csr_file.v 的 DESIGN_REV。理由见
     *     scripts/gomoku/main.c 里 design_rev() 的注释与 doc/board/README.md。 */
    {
        rt_uint32_t rev;
        __asm__ volatile ("csrr %0, mimpid" : "=r"(rev));
        rt_kprintf("[build] FW=RTTHREAD-GOMOKU-G3 RTL=0x%x\n", (unsigned)rev);
    }
    rt_kprintf("========================================\n");
    /* [!] 主频【不许写死】（2026-10-14 实踩）：同一份固件要装进 85.0051 / 76.5052
     *     两种位流，写死的那份在另一种上会打出【错的主频】—— 看起来像烧错了位流。
     *     实测：76.5052MHz 的 rev1019 位流打出 "@85.0051MHz"。
     *     **位流的权威自证永远是上面那行 `RTL=`（读 mimpid），不是这行。** */
    rt_kprintf(" RV32IMA + RT-Thread + GOMOKU(G3) @%d.%04dMHz\n",
               (int)(BOARD_SYSTEM_CLOCK_HZ / 1000000u),
               (int)((BOARD_SYSTEM_CLOCK_HZ % 1000000u) / 100u));
    rt_kprintf("========================================\n");
    rt_kprintf("[boot] tick         = %d\n", rt_tick_get());
    rt_kprintf("[boot] tick period  = %d Hz\n", RT_TICK_PER_SECOND);
    rt_kprintf("[boot] heap         = %d bytes\n", (int)heap_size);

    /* 邮箱：RT-Thread v5 邮箱承载 rt_ubase_t（指针），size=槽数。 */
    rt_mb_init(&mb_cmd, "aicmd", cmd_pool, sizeof(cmd_pool) / sizeof(cmd_pool[0]), RT_IPC_FLAG_FIFO);
    rt_mb_init(&mb_rsp, "airsp", rsp_pool, sizeof(rsp_pool) / sizeof(rsp_pool[0]), RT_IPC_FLAG_FIFO);

    /* render 线程（高优先）。静态线程：不占堆，栈不够链接期就报错。 */
    err = rt_thread_init(&render_thread, "render", render_entry, RT_NULL,
                         render_stack, sizeof(render_stack),
                         RENDER_PRIORITY, 10);
    if (err != RT_EOK) {
        rt_kprintf("[boot] rt_thread_init(render) FAILED (%d)\n", err);
        return -1;
    }
    rt_thread_startup(&render_thread);

    /* AI 线程（低优先） */
    err = rt_thread_init(&ai_thread, "ai", ai_entry, RT_NULL,
                         ai_stack, sizeof(ai_stack),
                         AI_PRIORITY, 10);
    if (err != RT_EOK) {
        rt_kprintf("[boot] rt_thread_init(ai) FAILED (%d)\n", err);
        return -1;
    }
    rt_thread_startup(&ai_thread);

    /* 主线程退到后台当"心跳"。它的存在本身就是判据：
     * 串口里 [hb] 和五子棋的输出交替出现 ⇒ 调度正常、render 没把 CPU 独占死。 */
    while (1) {
        rt_thread_mdelay(HB_DELAY_MS);
        rt_kprintf("[hb] alive, uptime %d ticks\n", rt_tick_get());
    }
}
