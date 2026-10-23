/* ============================================================================
 * input.c —— 按键去抖与短按/长按识别的实现（轨道 B1）
 * ----------------------------------------------------------------------------
 * 纯逻辑：只依赖 input.h，不碰任何硬件。平台差异（时间单位）由
 * INPUT_TICKS_PER_MS 这个编译期宏吸收，所以 x86 上能逐事件验证时序。
 * ==========================================================================*/
#include "input.h"

void input_init(input_t *in, uint32_t now, uint8_t key_raw,
                uint32_t debounce_ticks, uint32_t long_ticks)
{
    int k;
    uint8_t pressed = (uint8_t)(~key_raw);   /* 低有效 -> 翻成"按下 = 1" */

    in->short_latch    = 0;
    in->long_latch     = 0;
    in->debounce_ticks = debounce_ticks;
    in->long_ticks     = long_ticks;

    for (k = 0; k < INPUT_N_KEYS; k++) {
        uint8_t lvl = (uint8_t)((pressed >> k) & 1u);
        /* 上电时若某个键正被按着，就当它"一直按着"——
         * 不让它立刻产生一次短按（那会是莫名其妙的开机自触发）。 */
        in->raw[k]       = lvl;
        in->stable[k]    = lvl;
        in->t_edge[k]    = now;
        in->down_at[k]   = now;
        in->long_sent[k] = 1;                /* 1 = 先当作"长按已报过"，松手时也不会补短按 */
    }
}

void input_poll(input_t *in, uint32_t now, uint8_t key_raw)
{
    int k;
    uint8_t pressed = (uint8_t)(~key_raw);
    uint8_t short_now = 0, long_now = 0;

    for (k = 0; k < INPUT_N_KEYS; k++) {
        uint8_t lvl  = (uint8_t)((pressed >> k) & 1u);
        uint8_t bit  = (uint8_t)(1u << k);

        /* ---- 1) 记录原始电平的变化时刻（去抖判据）---- */
        if (lvl != in->raw[k]) {
            in->raw[k]    = lvl;
            in->t_edge[k] = now;
        }

        /* ---- 2) 电平稳定够久 -> 认账，产生边沿 ---- */
        if (lvl != in->stable[k] && (uint32_t)(now - in->t_edge[k]) >= in->debounce_ticks) {
            in->stable[k] = lvl;
            if (lvl) {                       /* 按下 */
                in->down_at[k]   = now;
                in->long_sent[k] = 0;
            } else {                         /* 松手 */
                /* 长按已经报过就不再补短按 —— 否则"按住落子"之后松手会
                 * 又移动一格，正是本文件开头要避免的那个毛病。 */
                if (!in->long_sent[k]) short_now |= bit;
            }
        }

        /* ---- 3) 按住够久 -> 报一次长按（只报一次）---- */
        if (in->stable[k] && !in->long_sent[k] &&
            (uint32_t)(now - in->down_at[k]) >= in->long_ticks) {
            in->long_sent[k] = 1;
            long_now |= bit;
        }
    }

    /* 锁存：调用方什么时候来取都行，不会被漏掉 */
    in->short_latch |= short_now;
    in->long_latch  |= long_now;
}

int input_take_short(input_t *in, int key)
{
    uint8_t bit;
    if (key < 0 || key >= INPUT_N_KEYS) return 0;
    bit = (uint8_t)(1u << key);
    if (in->short_latch & bit) {
        in->short_latch = (uint8_t)(in->short_latch & ~bit);
        return 1;
    }
    return 0;
}

int input_take_long(input_t *in, int key)
{
    uint8_t bit;
    if (key < 0 || key >= INPUT_N_KEYS) return 0;
    bit = (uint8_t)(1u << key);
    if (in->long_latch & bit) {
        in->long_latch = (uint8_t)(in->long_latch & ~bit);
        return 1;
    }
    return 0;
}

int input_is_down(const input_t *in, int key)
{
    if (key < 0 || key >= INPUT_N_KEYS) return 0;
    return in->stable[key] ? 1 : 0;
}

void input_clear_events(input_t *in)
{
    in->short_latch = 0;
    in->long_latch  = 0;
}
