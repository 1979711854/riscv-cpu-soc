/* ============================================================================
 * video_port.c —— render.h 声明的平台端口在这里落地（MMIO 直写显存）
 * ----------------------------------------------------------------------------
 * 本文件是【固件专用】：x86 单测（test_render.c）自己实现一份假的 vid_bulk_write，
 * 所以不编译这个文件。两边实现同一个接口，render.c 因此两边跑同一份源码。
 * ==========================================================================*/
#include "addr_map.h"
#include "render.h"
#include "video_port.h"
#include "hw_port.h"   /* hw_mtime() / hw_ticks_per_ms() —— vblank 超时要用 */

#define REG8(a)  (*(volatile unsigned char  *)(a))
#define REG32(a) (*(volatile unsigned int   *)(a))

void vid_bulk_write(uint8_t region, uint16_t offset, const uint8_t *data, uint16_t len)
{
    uint32_t base;
    uint16_t i;

    switch (region) {
    case VID_REGION_NT:  base = VIDEO_NT;  break;
    case VID_REGION_PAT: base = VIDEO_PAT; break;
    default:             base = VIDEO_PAL; break;
    }

    /* 逐字节写（sb 语义）。三块显存都支持按字节写 —— mem_bus 的字节使能是直通的
     * （rtl/bus/mem_bus.v 里 vid_be = mem_byte_en），所以调色板那种 4 字节项也能
     * 一条一条写：第 4 个字节（高 8 位）写 0 无害，硬件本来就把高 8 位忽略掉。 */
    for (i = 0; i < len; i++)
        REG8(base + offset + i) = data[i];
}

void video_set_scroll(int x, int y)
{
    /* 控制寄存器【只接受整字写 sw】—— 这里必须是 REG32，用字节写会无效 */
    REG32(VIDEO_SCROLL_X) = (unsigned int)(x & 0xFFF);
    REG32(VIDEO_SCROLL_Y) = (unsigned int)(y & 0xFFF);
}

/* vblank 等待的超时（毫秒）。一帧 16.7ms，取 50ms = 3 帧，足够宽又不会让人等太久。 */
#define VIDEO_VBLANK_TIMEOUT_MS 50u

/* 弱函数：vblank 忙等循环里每圈让一次。裸机是空实现（紧忙等）；
 * RT-Thread 宿主覆盖成 rt_thread_mdelay(1)，让低优先级 AI 线程在帧间拿到 CPU。 */
__attribute__((weak)) void video_vblank_yield(void) { }

int video_wait_vblank(void)
{
    /* VIDEO_STATUS bit0 = vblank。
     *
     * [!] 这里**必须带超时**。原来的实现是无超时忙等，注释自己承认了隐患却没修：
     *       "如果视频 PLL 没锁（pix_clk 不走），这个位永远不变，程序会卡死在这里、
     *        串口也不打印，看起来像'死机'。"
     *     2026-10-07 板上实踩过 —— 按复位后视频域没恢复（vid_resetn 跟着按钮复位），
     *     vblank 永远不来，CPU 永久挂在主循环第一句：屏幕黑、串口静默、按键全死。
     *
     *     现在的行为：超时（50ms ≈ 3 帧）就返回，**宁可少等一拍也不能永久挂死**。
     *     返回 0 表示等到了 vblank、非 0 表示超时 —— 调用方可据此提示或降级。 */
    uint32_t t0    = hw_mtime();
    uint32_t limit = VIDEO_VBLANK_TIMEOUT_MS * hw_ticks_per_ms();

    while ((REG32(VIDEO_STATUS) & 1u) == 0u) {
        if ((uint32_t)(hw_mtime() - t0) > limit)
            return 1;                    /* 超时：视频没在跑 */
        video_vblank_yield();
    }
    return 0;
}
