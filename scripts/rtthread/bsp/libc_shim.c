/* ============================================================================
 * libc_shim.c —— 把编译器会"顺手生成"的 C 库函数接到 RT-Thread 的 klibc 上
 * ----------------------------------------------------------------------------
 * 为什么需要这个：
 *
 *   我们用 -nostdlib（不链 newlib），但 **gcc 自己会生成对 memset/memcpy 的调用** ——
 *   典型是零初始化：`char tmp[32] = {0};` 编译出来就是一次 `memset`。
 *   实测就是 rt_vsnprintf_tiny.c:78 那个 `char tmp[32] = {0}` 触发的：
 *
 *     undefined reference to `memset'
 *
 *   这些名字必须有人提供，否则链接期就断在这儿。
 *
 * 为什么是"转发给 rt_*"而不是自己写循环：
 *   RT-Thread 的 klibc（src/klibc/kstring.c）本来就有 rt_memset / rt_memcpy 等实现，
 *   而且是字对齐的快速版。重复实现一遍既啰嗦又慢。
 *
 * [!] 前提：rtconfig.h 里**不能**定义 RT_KLIBC_USING_LIBC_MEMSET 那一族。
 *     如果定义了，kstring.c 的 rt_memset 会反过来转回 memset —— 那就成无限递归了。
 *     我们现在没定义，走的是 kstring.c 的 "#else 自带实现" 分支，所以这里是安全的。
 *     日后若开了 RT_KLIBC_USING_LIBC_*，必须把这个文件删掉改成直连 newlib。
 * ==========================================================================*/

#include <rtthread.h>

/* 声明 RT-Thread klibc 的实现（在 src/klibc/kstring.c 里） */
extern void *rt_memset(void *s, int c, rt_size_t count);
extern void *rt_memcpy(void *dst, const void *src, rt_size_t count);
extern void *rt_memmove(void *dst, const void *src, rt_size_t count);
extern int   rt_memcmp(const void *cs, const void *ct, rt_size_t count);
extern rt_size_t rt_strlen(const char *s);
extern char *rt_strcpy(char *dst, const char *src);
extern char *rt_strncpy(char *dst, const char *src, rt_size_t n);
extern int   rt_strcmp(const char *cs, const char *ct);
extern int   rt_strncmp(const char *cs, const char *ct, rt_size_t count);

/* ---- 编译器生成的符号，转发到上面那些 ----
 * 不加 rt_ 前缀，因为这些是 gcc 按 ABI 期望的名字。 */

void *memset(void *s, int c, rt_size_t count)
{
    return rt_memset(s, c, count);
}

void *memcpy(void *dst, const void *src, rt_size_t count)
{
    return rt_memcpy(dst, src, count);
}

void *memmove(void *dst, const void *src, rt_size_t count)
{
    return rt_memmove(dst, src, count);
}

int memcmp(const void *cs, const void *ct, rt_size_t count)
{
    return rt_memcmp(cs, ct, count);
}

rt_size_t strlen(const char *s)
{
    return rt_strlen(s);
}

char *strcpy(char *dst, const char *src)
{
    return rt_strcpy(dst, src);
}

char *strncpy(char *dst, const char *src, rt_size_t n)
{
    return rt_strncpy(dst, src, n);
}

int strcmp(const char *cs, const char *ct)
{
    return rt_strcmp(cs, ct);
}

int strncmp(const char *cs, const char *ct, rt_size_t count)
{
    return rt_strncmp(cs, ct, count);
}
