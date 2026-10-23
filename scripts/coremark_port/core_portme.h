#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

/* 无浮点：RV32I 无 F 扩展，避免软浮点拖慢并增大代码 */
#ifndef HAS_FLOAT
#define HAS_FLOAT 0
#endif
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
#ifndef HAS_PRINTF
#define HAS_PRINTF 0
#endif

#ifndef COMPILER_VERSION
#ifdef __GNUC__
#define COMPILER_VERSION "GCC"__VERSION__
#else
#define COMPILER_VERSION "Please put compiler version here"
#endif
#endif
#ifndef COMPILER_FLAGS
/* [!] 这串是【打印给人看的】，必须与实际编译口径一致 —— 报告里会引用它。
 *     2026-10-10 阶段0（v6 任务书）：-O2 换成 -O3 + 循环展开/对齐（CoreMark
 *     README Run Rules 许可 "changing build/load/run options"），拍/迭代
 *     313,886 → 282,777（阶段0）。**只影响代码生成，不影响正确性（四个 CRC 不变）**。
 *     阶段1（到达级重定向）再加 −7.34% → **262,018**。
 *     但别让它和 run_coremark.ps1 的命令行对不上 —— 那属于"报告里的数字说不清"。 */
#define COMPILER_FLAGS "-O3 -funroll-loops -funroll-all-loops -fpeel-loops -falign-functions=4 -falign-loops=4 -march=rv32im_zicsr -mabi=ilp32"
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "Static"
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
#ifdef VIDEO_TEXT_HOST
/* x86 主机预览：x64 上指针 64 位，ee_ptr_int 截成 32 位会让 align_mem()
 * 的整数往返把指针打断（core_matrix 首次访问即崩）。固件构建【永不定义】
 * VIDEO_TEXT_HOST —— 走下面的原定义（RV32 指针 32 位，ee_u32 正好）。 */
#include <stdint.h>
typedef uintptr_t      ee_ptr_int;
#else
typedef ee_u32         ee_ptr_int;
#endif
typedef size_t         ee_size_t;
#define NULL ((void *)0)

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

/* 用静态数组做内存块，避免自己实现 malloc */
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif

#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) \
    && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
