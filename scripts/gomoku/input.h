/* ============================================================================
 * input.h —— 按键去抖与"短按 / 长按"识别（轨道 B1）
 * ----------------------------------------------------------------------------
 * [!] 板上【只有 4 个用户按键】（丝印 SW4..SW7 = key[0..3]），却要干 5 件事
 *     （上/下/左/右 + 落子），所以必须有一个动作靠长按区分。本文件只负责
 *     "把裸按键变成干净的短按/长按事件"，**怎么解释交给 game.c**。
 *
 * 时序约定（这是本文件的核心，改之前先读完）：
 *
 *     按下 ──┬─ 松手（< LONG_MS）  -> 产生一次【短按】
 *            └─ 撑到 LONG_MS        -> 产生一次【长按】，之后松手不再产生短按
 *
 *   **两个事件都不在"按下沿"触发**，这是刻意的：
 *
 *     若改成"按下沿就移动、长按再落子"，按住方向键落子时光标会**先跑一格**，
 *     于是你想在 A 点落子、实际落在 A 的下一格 —— 手感完全错。
 *     改成现在这样，"按住不放落子"的净效果就是【光标一动不动地落子】。
 *
 *   代价：移动要等松手（人按键约 100ms），所以**没有连移**。
 *   五子棋是一格一格慢慢想的游戏，用这个代价换"落点绝不跑偏"是划算的。
 *
 * 去抖：硬件不做消抖（rtl/periph/gpio.v 注释明说消抖放软件），这里按
 *       "原始电平连续 DEBOUNCE_MS 毫秒不变才认账"处理。
 *       **用时间差而不是采样次数** —— input_poll() 在主循环里调，
 *       每圈一次，但一圈多长是不确定的，数次数会随主循环改动而失准。
 *
 * 时间单位：`now` 的单位由调用方决定，阈值在 input_init() 时一并传进来
 *           （**不能用编译期宏** —— 理由见下面那段 [!]）。
 * ==========================================================================*/
#ifndef GOMOKU_INPUT_H
#define GOMOKU_INPUT_H

#include <stdint.h>

#define INPUT_N_KEYS      4      /* 用户按键数 = key[3:0] */

/* [!] 时间单位：`now` 的单位由【调用方】决定，阈值由【调用方】在 init 时传进来。
 *
 *     板上：now = hw_mtime()，单位是 85.0051MHz 周期；
 *           阈值 = INPUT_DEBOUNCE_MS * (CPU_HZ/1000)。
 *     测试：now 用微秒，阈值 = INPUT_DEBOUNCE_MS * 1000。
 *
 * [!] 这里**不能用编译期宏**。最初就是这么写的（`#define INPUT_TICKS_PER_MS`），
 *     结果测试文件里的 `#define` 只影响测试自己那个 .c —— **input.c 是独立编译的
 *     翻译单元，它照样用默认值**，两边单位不一致，去抖阈值在测试里变成了 850ms，
 *     整个测试时间轴都够不着它。编译期宏在分离编译的模块之间【不会传播】。
 *     改成运行期参数之后，"谁给的时间谁负责换算"，两边不可能再对不上。 */
/* [!] 两个阈值允许在编译期覆盖 —— **仿真必须覆盖它们**。
 *     板上长按 600ms 在 85MHz 下是 5100 万拍；仿真的时钟是 100MHz，
 *     跑一次长按要 5100 万周期，整盘棋根本仿不完。
 *     `build.ps1 -Sim` 会传 -DINPUT_DEBOUNCE_MS=1 -DINPUT_LONG_MS=5，
 *     让仿真里的"长按"变成 5ms（约 50 万周期）—— 够小到能跑，
 *     又大到仍能压住主循环的帧级采样。**该变体不能上板。** */
#ifndef INPUT_DEBOUNCE_MS
#define INPUT_DEBOUNCE_MS 10     /* 原始电平连续多久不变才认账 */
#endif
#ifndef INPUT_LONG_MS
#define INPUT_LONG_MS     600    /* 按住多久算长按 */
#endif

/* 按键编号。物理对应（见 pds/RV32I_1/RV32I_1.fdc 头部注释）：
 *     key[0]=C23=丝印SW4   key[1]=B22=SW5   key[2]=A22=SW6   key[3]=B20=SW7
 * 映射成方向只是**默认约定**，game.c 可以按手感改。 */
#define KEY_LEFT   0
#define KEY_RIGHT  1
#define KEY_UP     2
#define KEY_DOWN   3

typedef struct {
    uint8_t  raw[INPUT_N_KEYS];        /* 上一次采到的原始电平（1 = 按下）*/
    uint32_t t_edge[INPUT_N_KEYS];     /* 原始电平最后一次变化的时刻 */
    uint8_t  stable[INPUT_N_KEYS];     /* 去抖后的电平（1 = 按下）*/
    uint32_t down_at[INPUT_N_KEYS];    /* 按下（去抖后）的时刻 */
    uint8_t  long_sent[INPUT_N_KEYS];  /* 这一轮按住里长按是否已报过 */

    uint8_t  short_latch;              /* bit k = 有一次短按未被取走 */
    uint8_t  long_latch;               /* bit k = 有一次长按未被取走 */

    /* 阈值（与 now 同一个单位，由调用方给）—— 存起来而不是用宏，
     * 理由见文件上方那段 [!]。 */
    uint32_t debounce_ticks;
    uint32_t long_ticks;
} input_t;

/* 初始化。
 *   now            = 当前时刻
 *   key_raw        = 初始读到的原始按键字节（按下 = 0）
 *   debounce_ticks = 去抖窗口，单位与 now 相同
 *   long_ticks     = 长按阈值，单位与 now 相同
 * 板上传 INPUT_DEBOUNCE_MS * hw_ticks_per_ms() 之类，测试传自己定的数。 */
void input_init(input_t *in, uint32_t now, uint8_t key_raw,
                uint32_t debounce_ticks, uint32_t long_ticks);

/* 采样一次。**在主循环里频繁调用**（每圈一次就行）。
 * now / key_raw 由调用方传入，是为了让 x86 测试能喂假时间与假按键。 */
void input_poll(input_t *in, uint32_t now, uint8_t key_raw);

/* 取走一次短按事件（取走即清，不会重复报）。有返回 1。 */
int input_take_short(input_t *in, int key);

/* 取走一次长按事件。有返回 1。 */
int input_take_long(input_t *in, int key);

/* 当前是否按着（去抖后）。给"按住时光标不闪"之类用。 */
int input_is_down(const input_t *in, int key);

/* 清掉所有未取走的事件（切画面时用，免得把上一屏的按键带过来） */
void input_clear_events(input_t *in);

#endif /* GOMOKU_INPUT_H */
