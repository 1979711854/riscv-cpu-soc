#include "coremark.h"
#include "core_portme.h"
#include "video_text.h"        /* HDMI 文本控制台（任务 B）*/
#include "../gomoku/cm_mailbox.h"   /* 0xFF00 共享邮箱：跑完把分数留给五子棋标题屏 */

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* 读 MMIO 周期计数器（0xFFF4，跟上系统时钟自由跑） */
#ifdef VIDEO_TEXT_HOST
/* x86 主机预览：没有 mtime 外设，直读字面地址会崩。返回合成计数器，让
 * stop-start = ITERATIONS × VIDEO_TEXT_HOST_TICKS_PER_ITER（默认 217,088 =
 * 板上实测每迭代拍数），结果页数字与板级口径自洽（版式全真、数字示意）。
 * [!] 该计数器只在 start_time/stop_time 各被读一次（ee_printf 的忙等在
 *     主机预览里已被短路，见 ee_printf.c）。 */
#ifndef VIDEO_TEXT_HOST_TICKS_PER_ITER
#define VIDEO_TEXT_HOST_TICKS_PER_ITER 217088u
#endif
CORETIMETYPE
barebones_clock(void)
{
    static unsigned long long host_clock = 0;
    CORETIMETYPE              now        = (CORETIMETYPE)host_clock;
    host_clock += (unsigned long long)ITERATIONS * VIDEO_TEXT_HOST_TICKS_PER_ITER;
    return now;
}
#else
CORETIMETYPE
barebones_clock(void)
{
    return (CORETIMETYPE)(*(volatile ee_u32 *)0xFFF4);
}
#endif

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1
/* 时钟频率 = 本固件要跑的那个平台的系统时钟。
 * [重点] 上板（本地盘古板）：PLL 27MHz→85.0051MHz，见 rtl/top/cpu_top_board.v；
 * [重点] 仿真 / 远程 FPGA 平台：固定 27MHz。
 * 填错不会报错，但 CoreMark 会算出错误的秒数 —— 判 valid 时按这个值卡。
 * [!] 这个常量【必须】与 PDS 时序报告里的实际频率一致（不用标称值）。
 *     历史：27e6 → 45e6 → 49,892,700 → 62,030,900 → 85,005,100 → 76,505,200
 *     （2026-10-17 128KB 版在 85 MHz 收不住，降频档改 RATIO0=15.0）。 */
#define EE_TICKS_PER_SEC           76505200

static CORETIMETYPE start_time_val, stop_time_val;
static CORETIMETYPE cm_ticks;      /* 计时区间总拍数；stop_time 里记下，结果页要用 */

/* 计时区间里的"显存保险丝"（任务书 §3.3 第 4 条）：
 *   start_time() 进门先关掉 HDMI 镜像，stop_time() 出门再打开。
 *   ⇒ 即使以后有人在计时区间里打日志，也只会走串口、**绝不会写显存**
 *     （显存写在慢总线上，多一次就可能让 Total ticks 变一位，跑分作废）。 */
void
start_time(void)
{
    /* [!] 本函数**只读计时器，一个字都不多做** —— 这是"Total ticks 逐位相同"的关键：
     *     start_time 的长度变了，它自己的 `ret` 就会换地址，BTB 里那条预测对不上，
     *     计时区间会莫名多 1 拍（实测：把 mirror 调用塞进来，217,088 → 217,089）。
     *     显存保险丝改在 portable_init 的末尾关、stop_time 里开，见那边的注释。 */
    GETMYTIME(&start_time_val);
}
void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
    cm_ticks = (CORETIMETYPE)(stop_time_val - start_time_val);
    video_text_mirror(1);
}
CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed
        = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}
secs_ret
time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

ee_u32 default_num_contexts = 1;

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    /* [!] 版本自证（2026-10-10 加）：打在 CoreMark 自己的报告【之前】。
     *     理由：两版位流可以装着**完全相同的固件**，跑分日志因此一模一样，
     *     事后分不出烧的是哪一版（见 doc/board/README.md 的 A/B 那一节）。
     *     版本号来自 RTL 侧的 `mimpid`，常量在 rtl/core/csr_file.v 的 DESIGN_REV。
     * [!] mimpid 是只读 CSR，只读不写（写它会抛非法指令）。
     *
     * [!] **这里绝对不能用 `ee_printf`** —— 2026-10-10 实踩，我自己踩的：
     *     `ee_printf` 的 `uart_send_char()` 每发一个字符都要**读 `0xFFF4` 忙等**，
     *     而 `sim/tb_coremark.v` 判定"CoreMark 计时区间"的判据恰恰是
     *     **第 1 次 / 第 2 次读 `0xFFF4`**（CoreMark 自己在 `start_time()` 之前
     *     一个字都不打，所以那两个读本来正好是 `start_time` / `stop_time`）。
     *     用了 `ee_printf` 之后，区间在 banner 处就被提前打开、下一个字符又立刻关上，
     *     于是 `region cycles / commit / mem acc` **全部变成 1**，
     *     所有流水线分解数据静默失效（而 `Total ticks` 仍然是对的，所以看不出来）。
     *     所以这里**直接写 UART 口、不忙等**：这 30 来个字符进的是 1024 深的
     *     FIFO，而后头还有十几秒的 CoreMark 要跑，早在程序结束前就发完了。 */
#ifdef VIDEO_TEXT_HOST
    /* x86 主机预览：无 UART/CSR 外设（0xFFFC 直写与 csrr 在主机上都会崩）。
     * banner 只走显存镜像（与板上画面一致）；版本号填当前 DESIGN_REV
     * （rtl/core/csr_file.v = 0x20261027）。 */
    {
        static const char pre[] = "[build] FW=COREMARK RTL=0x";
        static const char hx[]  = "0123456789abcdef";
        const char *p;
        unsigned    rev = 0x20261027u;
        int         i;

        video_text_init();
        for (p = pre; *p; p++) video_text_putc(*p);
        for (i = 28; i >= 0; i -= 4) video_text_putc(hx[(rev >> i) & 0xF]);
        video_text_putc('\n');          /* putc 忽略 '\r'，只处理 '\n' */
        video_text_mirror(0);
    }
#else
    {
        volatile ee_u8 *uart = (volatile ee_u8 *)0xFFFC;   /* 兼容区 UART 发送口 */
        static const char pre[] = "[build] FW=COREMARK RTL=0x";
        static const char hx[]  = "0123456789abcdef";
        const char *p;
        unsigned    rev;
        int         i;

        /* ---- HDMI 文本控制台初始化（任务书 §3.3）----
         * [!] **必须在这里、也就是 start_time() 之前做完**：它要写调色板 + 95 个
         *     16x16 图块 + 清 40x30 的 nametable（约 32KB 显存），@76.5MHz 约 0.3ms。
         *     放进计时区间就会直接改变 Total ticks。
         * [!] 只在本函数里做一次；计时区间里由 start_time/stop_time 的
         *     video_text_mirror 开关挡着，绝不写显存。 */
        video_text_init();

        __asm__ volatile ("csrr %0, mimpid" : "=r"(rev));
        for (p = pre; *p; p++) { *uart = (ee_u8)*p; video_text_putc(*p); }
        for (i = 28; i >= 0; i -= 4) {
            char h = hx[(rev >> i) & 0xF];
            *uart = (ee_u8)h;
            video_text_putc(h);
        }
        *uart = (ee_u8)'\r';
        *uart = (ee_u8)'\n';
        video_text_putc('\n');          /* putc 忽略 '\r'，只处理 '\n' */

        /* ---- 显存保险丝：从这里到 stop_time 之间，HDMI 镜像关闭 ----
         * 位置刻意放在 portable_init 的**最后**（紧挨着之后的 get_seed/start_time）：
         *   · 计时区间里任何 ee_printf 都只走串口，不会写显存；
         *   · 又不必往 start_time() 里加指令（加了会让计时区间多 1 拍，见上面的注释）。 */
        video_text_mirror(0);
    }
#endif /* VIDEO_TEXT_HOST */

    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

/* ---------------------------------------------------------------------------
 * 结果页（任务书 §3.1 / §3.5）
 * ---------------------------------------------------------------------------
 * [!] 为什么用 container_of 取 results：`portable_fini()` 只拿到 `&results[0].port`，
 *     而 Total ticks / 四个 CRC / 迭代数都在外层的 core_results 里（port 是**最后一个**
 *     成员）。改 third_party 里的 CoreMark 源码是更坏的选择 —— 那份是 EEMBC 的
 *     上游代码，升级/比对时会冲突。offsetof 是编译期常量，零运行期开销。
 * ------------------------------------------------------------------------- */
static const core_results *results_from_port(core_portable *p)
{
    return (const core_results *)((const char *)p - __builtin_offsetof(core_results, port));
}

/* 把成绩写进 0xFF00 的共享邮箱（跨复位保留，五子棋标题屏来读）。
 * [!] **magic 最后写** —— 读的一方（五子棋）据此判断"这是一份完整结果"。 */
static void mailbox_publish(const core_results *r, ee_u32 score_x100, ee_u16 seedcrc)
{
#ifdef VIDEO_TEXT_HOST
    /* x86 主机预览：0xFF00 邮箱是字面地址直写（主机上会崩），跳过 —— 不影响屏幕。 */
    (void)r; (void)score_x100; (void)seedcrc;
    return;
#else
    volatile ee_u32 *m = (volatile ee_u32 *)CM_MBOX_BASE;

    m[CM_MBOX_I_MAGIC] = 0u;                       /* 先撤销，别让旧 magic 骗到人 */
    m[CM_MBOX_I_ITER]     = (ee_u32)ITERATIONS;
    m[CM_MBOX_I_TICKS]    = (ee_u32)cm_ticks;
    m[CM_MBOX_I_SCORE]    = score_x100;
    m[CM_MBOX_I_SEEDCRC]  = (ee_u32)seedcrc;
    m[CM_MBOX_I_CRCLIST]  = (ee_u32)r->crclist;
    m[CM_MBOX_I_CRCMAT]   = (ee_u32)r->crcmatrix;
    m[CM_MBOX_I_CRCSTATE] = (ee_u32)r->crcstate;
    m[CM_MBOX_I_FLAGS]    = (r->err == 0) ? (ee_u32)CM_MBOX_FLAG_CRC_OK : 0u;
    m[CM_MBOX_I_MAGIC]    = (ee_u32)CM_MBOX_MAGIC; /* 最后 */
#endif /* VIDEO_TEXT_HOST */
}

/* ---- 结果页用的小工具：自己拼串（固件没有 sprintf）---- */
static char *vt_append(char *d, const char *s)
{
    while (*s) *d++ = *s++;
    *d = '\0';
    return d;
}

static char *vt_dec(char *d, unsigned v, int width)
{
    char tmp[12];
    int  n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (n < width) tmp[n++] = '0';
    while (n--) *d++ = tmp[n];
    *d = '\0';
    return d;
}

static char *vt_hex(char *d, unsigned v, int width)
{
    static const char hx[] = "0123456789abcdef";
    char tmp[12];
    int  n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = hx[v & 0xFu]; v >>= 4; }
    while (n < width) tmp[n++] = '0';
    while (n--) *d++ = tmp[n];
    *d = '\0';
    return d;
}

/* 屏上结果页（2026-10-18 第二轮反馈 C1~C4）：
 *   · 每一行都从 **col 4** 起，不再贴左上角；
 *   · 按「标题 / 参数 / 结果 / CRC / 提示」五组分开，**组间空一行**；
 *   · 只留关键数字，编译器 flags 那些长行不往结果页上堆（滚动区里已经有了）。
 * 数字全部**现算**（64 位），不用 CoreMark 的整数截断值：
 *   Score        = ITER × 时钟 ÷ ticks
 *   CoreMark/MHz = ITER × 1e6 ÷ ticks
 *   Total time   = ticks ÷ 时钟（毫秒定点，避免 11 / 0 那种整数截断） */
static void draw_result_page(const core_results *r, ee_u16 seedcrc)
{
    const int X = 4;                    /* 结果页左边界（反馈 C1：不贴左） */
    unsigned long long ticks = (unsigned long long)cm_ticks;
    unsigned long long score_x10, cpi_x1000, secs_x1000;
    unsigned int score10, cpi1000, secs1000, mhz10;
    char line[40];
    char *p;

    if (ticks == 0ull) ticks = 1ull;

    score_x10  = (unsigned long long)ITERATIONS * (unsigned long long)EE_TICKS_PER_SEC * 10ull / ticks;
    cpi_x1000  = (unsigned long long)ITERATIONS * 1000000000ull / ticks;
    secs_x1000 = ticks * 1000ull / (unsigned long long)EE_TICKS_PER_SEC;

    score10  = (unsigned int)score_x10;
    cpi1000  = (unsigned int)cpi_x1000;
    secs1000 = (unsigned int)secs_x1000;
    mhz10    = (unsigned int)(EE_TICKS_PER_SEC / 100000u);   /* 76.5052MHz -> 765 */

    video_text_clear();

    /* 组 1：标题 */
    video_text_at(1, X, "COREMARK 1.0");
    p = line; p = vt_append(p, "RV32IMA @ ");
    p = vt_dec(p, mhz10 / 10u, 0);
    p = vt_append(p, ".");
    p = vt_dec(p, mhz10 % 10u, 0);
    p = vt_append(p, " MHz");
    video_text_at(3, X, line);

    /* 组 2：参数 */
    p = line; p = vt_append(p, "ITER        = ");
    p = vt_dec(p, (unsigned)ITERATIONS, 0);
    video_text_at(4, X, line);

    /* 组 3：结果（空一行再开始）*/
    p = line; p = vt_append(p, "Total ticks : ");
    p = vt_dec(p, (unsigned)cm_ticks, 0);
    video_text_at(6, X, line);

    p = line; p = vt_append(p, "Time        : ");
    p = vt_dec(p, secs1000 / 1000u, 0);
    p = vt_append(p, ".");
    p = vt_dec(p, secs1000 % 1000u, 3);
    p = vt_append(p, " s");
    video_text_at(7, X, line);

    p = line; p = vt_append(p, "CoreMark/MHz: ");
    p = vt_dec(p, cpi1000 / 1000u, 0);
    p = vt_append(p, ".");
    p = vt_dec(p, cpi1000 % 1000u, 3);
    video_text_at(8, X, line);

    p = line; p = vt_append(p, "Score       : ");
    p = vt_dec(p, score10 / 10u, 0);
    p = vt_append(p, ".");
    p = vt_dec(p, score10 % 10u, 0);
    video_text_at(9, X, line);

    /* 组 4：四个 CRC（空一行）*/
    p = line; p = vt_append(p, "seedcrc   : 0x");
    p = vt_hex(p, seedcrc, 4);
    video_text_at(11, X, line);

    p = line; p = vt_append(p, "crclist   : 0x");
    p = vt_hex(p, r->crclist, 4);
    video_text_at(12, X, line);

    p = line; p = vt_append(p, "crcmatrix : 0x");
    p = vt_hex(p, r->crcmatrix, 4);
    video_text_at(13, X, line);

    p = line; p = vt_append(p, "crcstate  : 0x");
    p = vt_hex(p, r->crcstate, 4);
    video_text_at(14, X, line);

    /* 组 5：判定 + 下一步（各空一行）*/
    video_text_at(16, X, (r->err == 0) ? "CRC OK" : "CRC BAD");
    video_text_at(18, X, "SW6 UP + RESET -> GOMOKU");
}

void
portable_fini(core_portable *p)
{
    const core_results *res = results_from_port(p);
    ee_u16 seedcrc = 0;
    ee_u32 score_x100;

    /* ---- 1) 与 CoreMark 报告里同一套 seedcrc 算法（core_main.c:287-290）---- */
    seedcrc = crc16(res->seed1, seedcrc);
    seedcrc = crc16(res->seed2, seedcrc);
    seedcrc = crc16(res->seed3, seedcrc);
    seedcrc = crc16((ee_s16)res->size, seedcrc);

    /* ---- 2) 分数（64 位；ITER×时钟×100 超过 32 位，见任务书 §3.6.1）---- */
    score_x100 = (ee_u32)((unsigned long long)ITERATIONS *
                          (unsigned long long)EE_TICKS_PER_SEC * 100ull /
                          (unsigned long long)(cm_ticks ? cm_ticks : 1));

    /* ---- 3) 共享邮箱 + HDMI 结果页 ---- */
    mailbox_publish(res, score_x100, seedcrc);
    draw_result_page(res, seedcrc);

    /* [!] Cache 命中/缺失上报（高阶任务①，2026-10-11 加）。
     *   位置刻意放在 portable_fini：它在 CoreMark 报告【之后】、计时区间【之外】，
     *   所以既不影响 Total ticks，也不影响四个 CRC。
     *   计数器是 mem_bus 里的只读 MMIO（0x8000_0018~0x24，见 scripts/demo/addr_map.h）；
     *   DCACHE_EN/ICACHE_EN=0 时它们恒 0，所以这里无条件打也无害。
     *   同样直写 0xFFFC、不走 ee_printf（理由见 portable_init 的长注释）。 */
#ifndef VIDEO_TEXT_HOST /* x86 主机预览：0xFFFC/0x80000018 字面地址直读写会崩，跳过 */
    {
        volatile ee_u8 *uart = (volatile ee_u8 *)0xFFFC;
        static const char hx[] = "0123456789abcdef";
        struct { const char *label; ee_u32 addr; } tab[4];
        int t, i;

        tab[0].label = "[cache] D hits=0x"; tab[0].addr = 0x80000018u;
        tab[1].label = "[cache] D miss=0x"; tab[1].addr = 0x8000001Cu;
        tab[2].label = "[cache] I hits=0x"; tab[2].addr = 0x80000020u;
        tab[3].label = "[cache] I miss=0x"; tab[3].addr = 0x80000024u;

        for (t = 0; t < 4; t++) {
            ee_u32 v = *(volatile ee_u32 *)tab[t].addr;
            const char *q;
            for (q = tab[t].label; *q; q++) *uart = (ee_u8)*q;
            for (i = 28; i >= 0; i -= 4) *uart = (ee_u8)hx[(v >> i) & 0xF];
            *uart = (ee_u8)'\r';
            *uart = (ee_u8)'\n';
        }
    }
#endif /* VIDEO_TEXT_HOST */
    p->portable_id = 0;
}
