/* ============================================================================
 * host_mmio.h —— x86 主机预览用假 MMIO 重定向（只读这一页，别上板）
 * ----------------------------------------------------------------------------
 * [!] 固件构建（run_coremark.ps1 / build_bitstream.ps1）【永不定义】
 *     VIDEO_TEXT_HOST，所以固件里没有任何一个翻译单元会包含本文件，
 *     对固件镜像零影响。只有 sim/tools/preview_coremark.c 的主机预览构建
 *     （scripts/preview_coremark.ps1，-DVIDEO_TEXT_HOST）会走这里。
 *
 * 干什么：video_text.c 对显存的直写（REG8/REG32 宏）在主机预览下被重定向到
 *         harness 提供的假内存上（host_mmio_ptr 按绝对地址分发）。
 *         地址分区与 rtl/bus/addr_map.vh 对齐：
 *           0xFF00..0xFFFF           兼容区（邮箱 0xFF00 / mtime 0xFFF4 / UART 0xFFFC）
 *           0x80000000..0x80000FFF   系统计数器（Cache 命中/缺失 @0x80000018..）
 *           0x80010000..0x80030FFF   视频（NT 8KB / PAT 64KB / PAL 1KB / scroll）
 * ===========================================================================*/
#ifndef COREMARK_HOST_MMIO_H
#define COREMARK_HOST_MMIO_H

#include <stdint.h>

/* harness（sim/tools/preview_coremark.c）提供；越界地址直接报错退出 ——
 * 宁可预览失败，也不要静默写飞。 */
unsigned char *host_mmio_ptr(uintptr_t addr);

#define HOST_R8(a)  (*(volatile unsigned char *)(host_mmio_ptr((uintptr_t)(a))))
#define HOST_R32(a) (*(volatile unsigned int   *)(host_mmio_ptr((uintptr_t)(a))))

#endif /* COREMARK_HOST_MMIO_H */
