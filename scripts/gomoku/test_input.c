/* ============================================================================
 * test_input.c —— 按键去抖与短按/长按的 x86 单测（轨道 B1）
 * ----------------------------------------------------------------------------
 * 运行：  scripts\gomoku\run_test.ps1
 *
 * 时序代码最容易写出"看起来对、边界全错"的 bug —— 去抖阈值差 1 个采样、
 * 长按后松手又补一次短按、抖动被当成连击…… 这些在板上极难复现，
 * 在这里是几行断言的事。所以本文件**逐毫秒地走时间轴**，不跳步。
 *
 * 时间单位：**喂进来的 now 用微秒**（1 tick = 1µs），断言里的数字可以肉眼读。
 * 阈值按同一个单位换算后传给 input_init —— 这正是"单位由调用方给"的好处：
 * 测试用微秒、板上用 62MHz 周期，两边各算各的，不可能对不上。
 * ==========================================================================*/
#include <stdio.h>
#include "input.h"

#define US_PER_MS 1000u
#define DEBOUNCE_TICKS (INPUT_DEBOUNCE_MS * US_PER_MS)
#define LONG_TICKS     (INPUT_LONG_MS     * US_PER_MS)

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                            \
    do {                                                            \
        if (cond) { g_pass++; }                                     \
        else {                                                      \
            g_fail++;                                               \
            printf("  [FAIL] %s:%d  %s\n", __FILE__, __LINE__, msg); \
        }                                                           \
    } while (0)

/* 原始按键字节：**按下 = 0**（低有效）。bit k 对应 key[k]。 */
#define KEYS_NONE   0xFFu
#define PRESS(k)    (uint8_t)(KEYS_NONE & ~(1u << (k)))

static input_t g_in;
static uint32_t g_t;                       /* 当前时刻（微秒）*/

/* 从当前时刻起，持续 dur_us 微秒喂同一个 key_raw，每 step_us 采一次 */
static void feed(uint32_t dur_us, uint8_t key_raw, uint32_t step_us)
{
    uint32_t end = g_t + dur_us;
    while (g_t < end) {
        input_poll(&g_in, g_t, key_raw);
        g_t += step_us;
    }
}

static void t_init(uint8_t key_raw)
{
    g_t = 0;
    input_init(&g_in, g_t, key_raw, DEBOUNCE_TICKS, LONG_TICKS);
}

/* ---------------------------------------------------------------------------
 * A. 没按键 -> 永远没有事件
 * ------------------------------------------------------------------------- */
static void test_idle(void)
{
    int k;
    printf("---- A. 静默（无按键）----\n");
    t_init(KEYS_NONE);
    feed(50000, KEYS_NONE, 100);
    for (k = 0; k < INPUT_N_KEYS; k++) {
        CHECK(!input_take_short(&g_in, k), "空闲时不该有短按事件");
        CHECK(!input_take_long(&g_in, k),  "空闲时不该有长按事件");
    }
}

/* ---------------------------------------------------------------------------
 * B. 去抖：抖动不该被当成连击
 * ------------------------------------------------------------------------- */
static void test_bounce(void)
{
    int k;
    printf("---- B. 抖动（bounce）----\n");
    t_init(KEYS_NONE);

    /* 10ms 内快速抖 10 次（每次 1ms 一个来回）—— 全都在去抖窗口内，
     * 认账的电平一次都不该翻 */
    for (k = 0; k < 10; k++) {
        feed(500, PRESS(KEY_LEFT), 100);
        feed(500, KEYS_NONE,       100);
    }
    CHECK(!input_take_short(&g_in, KEY_LEFT), "抖动不该产生短按");
    CHECK(!input_is_down(&g_in, KEY_LEFT),    "抖动后不该认为键按着");

    /* 抖完之后真正按住并稳住 -> 应该干净地认一次 */
    feed(2000,  PRESS(KEY_LEFT), 100);        /* 稳住 2ms 还不够 */
    feed(30000, PRESS(KEY_LEFT), 100);        /* 再稳 30ms，够了 */
    CHECK(input_is_down(&g_in, KEY_LEFT), "稳定按住后应认账");
    feed(1000, KEYS_NONE, 100);               /* 松手 */
    feed(20000, KEYS_NONE, 100);              /* 松手稳住 */
    CHECK(input_is_down(&g_in, KEY_LEFT) == 0, "松手稳定后应认账");
    CHECK(input_take_short(&g_in, KEY_LEFT), "抖动之后的那次真实短按应该报出来");
    CHECK(!input_take_short(&g_in, KEY_LEFT), "短按只报一次");
}

/* ---------------------------------------------------------------------------
 * C. 短按：按下 -> 稳住 -> 松手 -> 报一次
 * ------------------------------------------------------------------------- */
static void test_short(void)
{
    printf("---- C. 短按 ----\n");
    t_init(KEYS_NONE);

    feed(30000, PRESS(KEY_UP), 100);          /* 按住 30ms（> 去抖窗口 10ms）*/
    CHECK(!input_take_short(&g_in, KEY_UP), "还没松手，不该报短按");
    CHECK(!input_take_long(&g_in, KEY_UP),  "按 30ms 远不到长按");

    feed(30000, KEYS_NONE, 100);              /* 松手 */
    CHECK(input_take_short(&g_in, KEY_UP), "松手后应报一次短按");
    CHECK(!input_take_short(&g_in, KEY_UP), "短按不该重复报");

    /* 松手那一瞬间（未过去抖窗口）不该立刻报 —— 确认去抖也管松手 */
    t_init(KEYS_NONE);
    feed(30000, PRESS(KEY_UP), 100);
    feed(2000,  KEYS_NONE, 100);              /* 只松开 2ms，还在去抖窗口内 */
    CHECK(!input_take_short(&g_in, KEY_UP), "松手未过去抖窗口时不该报");
    feed(30000, KEYS_NONE, 100);
    CHECK(input_take_short(&g_in, KEY_UP), "松手稳住后才报");

    /* [重点] 比去抖窗口还短的"按一下"会被【整个忽略】—— 这不是 bug，
     * 是去抖的必然代价：10ms 内的任何电平都不足以形成一次可辨认的边沿。
     * 人按一下约 100ms，所以实用上碰不到；但写测试时别拿边界值当"正常按压"。 */
    t_init(KEYS_NONE);
    feed(6000, PRESS(KEY_UP), 100);           /* 只按 6ms，不到去抖窗口 */
    feed(30000, KEYS_NONE, 100);
    CHECK(!input_take_short(&g_in, KEY_UP), "短于去抖窗口的按压应被忽略（预期行为）");
}

/* ---------------------------------------------------------------------------
 * D. 长按：这条是本次按键方案的命门
 * ------------------------------------------------------------------------- */
static void test_long(void)
{
    printf("---- D. 长按（落子）----\n");
    t_init(KEYS_NONE);

    /* 按住 599ms 松手 —— 还差一点，应该算短按 */
    feed(INPUT_LONG_MS * 1000u - 1000u, PRESS(KEY_DOWN), 1000);
    CHECK(!input_take_long(&g_in, KEY_DOWN), "599ms 不该算长按");
    feed(30000, KEYS_NONE, 100);
    CHECK(input_take_short(&g_in, KEY_DOWN), "599ms 松手应算短按");

    /* [!] 长按的计时是从【去抖认账那一刻】开始的，所以从手指按下算起，
     * 实际需要 去抖(10ms) + 阈值(600ms) = 约 610ms。这里给 620ms 留余量。 */
    t_init(KEYS_NONE);
    feed((INPUT_LONG_MS + INPUT_DEBOUNCE_MS + 10u) * 1000u, PRESS(KEY_DOWN), 1000);
    CHECK(input_take_long(&g_in, KEY_DOWN), "620ms 应算长按（去抖 + 阈值）");
    CHECK(!input_take_long(&g_in, KEY_DOWN), "长按只报一次");

    /* [关键] 长按之后松手，**不能再报一次短按** ——
     * 否则"按住落子"松手时会又移动一格，正是 input.h 开头要避免的毛病 */
    feed(30000, KEYS_NONE, 100);
    CHECK(!input_take_short(&g_in, KEY_DOWN), "长按之后松手不该再补短按");

    /* 再按一次，应该是全新的短按（状态要清干净） */
    feed(30000, PRESS(KEY_DOWN), 100);
    feed(30000, KEYS_NONE, 100);
    CHECK(input_take_short(&g_in, KEY_DOWN), "长按之后再短按应正常");

    /* 按住不放持续很久，也只报一次长按 */
    t_init(KEYS_NONE);
    feed(3000000, PRESS(KEY_DOWN), 1000);
    CHECK(input_take_long(&g_in, KEY_DOWN), "持续按住应报长按");
    feed(3000000, PRESS(KEY_DOWN), 1000);
    CHECK(!input_take_long(&g_in, KEY_DOWN), "一直按住不该反复报长按");
}

/* ---------------------------------------------------------------------------
 * E. 多键独立：同时按两个键时互不干扰
 * ------------------------------------------------------------------------- */
static void test_multi(void)
{
    printf("---- E. 多键独立 ----\n");
    t_init(KEYS_NONE);

    /* 左和右同时按住，然后先后松开 */
    feed(20000, (uint8_t)(PRESS(KEY_LEFT) & PRESS(KEY_RIGHT)), 100);
    CHECK(input_is_down(&g_in, KEY_LEFT),  "左键应认账");
    CHECK(input_is_down(&g_in, KEY_RIGHT), "右键应认账");

    feed(30000, PRESS(KEY_RIGHT), 100);       /* 松开左 */
    CHECK(!input_is_down(&g_in, KEY_LEFT), "左键应已松开");
    CHECK(input_is_down(&g_in, KEY_RIGHT), "右键仍按着");
    CHECK(input_take_short(&g_in, KEY_LEFT),  "左键应报短按");
    CHECK(!input_take_short(&g_in, KEY_RIGHT), "右键还没松，不该报");

    feed(30000, KEYS_NONE, 100);
    CHECK(input_take_short(&g_in, KEY_RIGHT), "右键松手后应报短按");
}

/* ---------------------------------------------------------------------------
 * F. 上电时键正被按着：不该自触发
 * ------------------------------------------------------------------------- */
static void test_power_on_held(void)
{
    printf("---- F. 上电时按键已按下 ----\n");
    t_init(PRESS(KEY_LEFT));                  /* 复位时手还按着 */

    feed(1000, PRESS(KEY_LEFT), 100);
    CHECK(!input_take_short(&g_in, KEY_LEFT), "上电瞬间不该冒出一次短按");

    feed(30000, KEYS_NONE, 100);              /* 松手 */
    CHECK(!input_take_short(&g_in, KEY_LEFT), "上电就按着的那次松手也不该报短按");

    /* 之后正常按键要能工作 */
    feed(30000, PRESS(KEY_LEFT), 100);
    feed(30000, KEYS_NONE, 100);
    CHECK(input_take_short(&g_in, KEY_LEFT), "之后正常按键应工作");
}

/* ------------------------------------------------------------------------- */
int main(void)
{
    printf("=== 五子棋 轨道 B1（按键去抖 / 短按长按）单测 ===\n");
    printf("去抖 %d ms / 长按 %d ms / 时间单位 = 微秒（%u 微秒每毫秒）\n\n",
           INPUT_DEBOUNCE_MS, INPUT_LONG_MS, (unsigned)US_PER_MS);

    test_idle();
    test_bounce();
    test_short();
    test_long();
    test_multi();
    test_power_on_held();

    printf("\nchecks=%d  errors=%d\n", g_pass + g_fail, g_fail);
    if (g_fail == 0) printf("=== PASS ===\n");
    else             printf("=== FAIL ===\n");
    return g_fail == 0 ? 0 : 1;
}
