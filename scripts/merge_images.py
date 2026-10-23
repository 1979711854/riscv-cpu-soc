#!/usr/bin/env python3
"""把 boot / CoreMark / RT-Thread 三块镜像合成**一份** mem.hex（单一位流的唯一镜像）。

官方答疑第 53 问（R99）要求「跑分和应用是同一个 bit 流」。做法：一颗位流 + 128KB
统一存储器，里面同时驻留三个程序，复位后由 boot.S 按按键选路。本脚本只做一件事：
把三份 elf2mem 产物按固定布局拼起来，并且在【拼之前】把所有会静默出错的情况变成
硬报错。

布局（与 doc/reports/2026-10-17_three_way_split.md §1.1 一致，改一处要三处一起改）::

    0x00000 ~ 0x00FFF   boot       复位入口，跳 0x1000 / 0x10000
    0x01000 ~ 0x0EFFF   coremark   CoreMark 跑分档（栈顶 0xF000）
    0x0F000 ~ 0x0FFFF   兼容区 0xFFF0~0xFFFF + 间隙（RAM 空洞，不可放数据）
    0x10000 ~ 0x1FFEF   rtthread   RT-Thread + 五子棋（栈顶 0x1FFF0）
    0x1FFF0 ~ 0x1FFFF   保留（0x1FFF0 的 addr[15:4] 也是 0xFFF —— 别名陷阱）

必须报错（不是警告）的五类问题：

  1. **段内越界**：某块镜像的数据越过它自己的区间（例如 CoreMark 长到 0xF000 里）。
  2. **交叉重叠**：两块镜像占同一个字。统一存储器只有一份，后者会静默覆盖前者。
  3. **入口不对**：boot 的第一字必须 = 0x0、coremark = 0x1000、rtthread = 0x10000。
     boot.S 是**直接 jr 到常数地址**的，链接脚本一改起点，跳过去就是别人的中段。
  4. **踩兼容区**：0xFFF0~0xFFFF 是 MMIO（0xFFF4 计时 / 0xFFF8 done / 0xFFFC UART），
     不是 RAM。镜像里出现这块地址 ⇒ RAM 写会被 mem_bus 当成 MMIO 写，静默丢失。
  5. **踩 0x1FFF0 保留区**：这一段的 addr[15:4] 也是 0xFFF，扩到 128KB 后如果哪天
     `mem_bus.v` 的兼容区判决漏了 `!addr[16]`，0x1FFF0 会被当成 MMIO ——
     所以镜像**根本不许**用它，从源头堵住。

用法::

    python scripts/merge_images.py                      # 用默认路径
    python scripts/merge_images.py --boot a.hex --coremark b.hex --rtthread c.hex -o out.hex
    python scripts/merge_images.py --no-out             # 只校验，不写文件

输入/输出格式同 elf2mem.py：``@<word索引>`` 后跟十六进制字，**按字索引定位**。
"""
import argparse
import os
import sys

# ---------------------------------------------------------------------------
# 布局：唯一的真相表。CLI 只改文件名，不改区间。
# ---------------------------------------------------------------------------
LAYOUT = [
    # (名字, 起始字节(含), 结束字节(不含), 默认输入)
    ("boot",     0x00000000, 0x00001000, "sim/programs/combined/boot.hex"),
    ("coremark", 0x00001000, 0x0000F000, "sim/programs/combined/coremark.hex"),
    ("rtthread", 0x00010000, 0x0001FFF0, "sim/programs/combined/rtthread.hex"),
]

RAM_FIRST_BYTE = 0x00000000        # addr_map.vh: RAM_BASE
RAM_LAST_BYTE  = 0x0001FFEF        # addr_map.vh: RAM_LAST_BYTE
COMPAT_FIRST   = 0x0000FFF0        # 0xFFF0~0xFFFF 兼容区（RAM 空洞）
COMPAT_LAST    = 0x0000FFFF
RESERVED_FIRST = 0x0001FFF0        # 0x1FFF0~0x1FFFF 保留（别名陷阱）
RESERVED_LAST  = 0x0001FFFF


class MergeError(Exception):
    pass


def parse_hex(path):
    """读 elf2mem 风格的 hex，返回 {word_index: value}。

    格式：``@idx`` 设定当前位置，其后每行一个 32 位字，索引自增。
    任何不合规（缺 @ 就出数据、数据不是 8 位十六进制、索引重复）都报错 ——
    这个文件最终会进 BRAM 初始化，静默容忍等于把错误烧进板子。
    """
    words = {}
    cur = None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, raw in enumerate(f, 1):
            s = raw.strip()
            if not s:
                continue
            if s.startswith("@"):
                try:
                    cur = int(s[1:], 16)
                except ValueError:
                    raise MergeError("%s:%d 不是合法的 @地址：%r" % (path, lineno, s))
                continue
            if cur is None:
                raise MergeError("%s:%d 数据行出现在 @地址 之前：%r" % (path, lineno, s))
            try:
                val = int(s, 16)
            except ValueError:
                raise MergeError("%s:%d 不是十六进制数据：%r" % (path, lineno, s))
            if not (0 <= val <= 0xFFFFFFFF):
                raise MergeError("%s:%d 数据超过 32 位：%r" % (path, lineno, s))
            if cur in words:
                raise MergeError("%s:%d 字索引 0x%x 重复出现（文件自身就重叠）" % (path, lineno, cur))
            words[cur] = val
            cur += 1
    return words


def byte_span(words):
    """{word: val} -> (起始字节, 结束字节(含))；空镜像返回 None。"""
    if not words:
        return None
    lo = min(words) * 4
    hi = max(words) * 4 + 3
    return lo, hi


def check_image(name, words, start, end, path):
    """单块镜像的自检：非空、起点对、不越界、不踩兼容区/保留区。"""
    span = byte_span(words)
    if span is None:
        raise MergeError("镜像 %s 是空的（%s）：elf2mem 没产出任何字，检查链接脚本/段名"
                         % (name, path))
    lo, hi = span

    # 3) 入口必须落在区间起点：boot.S 里的 jr 用的是常数地址
    if lo != start:
        raise MergeError(
            "镜像 %s 的起始地址是 0x%05x，但布局要求 0x%05x（%s）。\n"
            "      boot.S 是直接 jr 到常数地址的，起点错了就会跳进别人的中段。\n"
            "      检查对应链接脚本里的 `. = 0x%x;`。" % (name, lo, start, path, start))

    # 4) 兼容区（RAM 空洞）：逐字检查，落到 0xFFF0~0xFFFF 就是错
    # [!] 必须先于"段内越界"判：CoreMark 区间到 0xEFFF，踩 0xFFF0 时若先报越界，
    #     提示会指向"程序太大"，而真正原因是链接脚本把数据顶到了 MMIO 上。
    hit = [w for w in words if COMPAT_FIRST <= w * 4 <= COMPAT_LAST]
    if hit:
        raise MergeError(
            "镜像 %s 有 %d 个字落在兼容区 0x%05x~0x%05x（最小 0x%05x）。\n"
            "      那是 MMIO（0xFFF4 计时 / 0xFFF8 done / 0xFFFC UART），不是 RAM ——\n"
            "      写进去会被 mem_bus 当外设写、静默丢失。检查链接脚本是否把\n"
            "      .data/.bss 顶到了 0xF000 以上。" % (name, len(hit), COMPAT_FIRST, COMPAT_LAST, min(hit) * 4))

    # 5) 0x1FFF0 保留区
    hit = [w for w in words if RESERVED_FIRST <= w * 4 <= RESERVED_LAST]
    if hit:
        raise MergeError(
            "镜像 %s 有 %d 个字落在保留区 0x%05x~0x%05x（最小 0x%05x）。\n"
            "      这一段的 addr[15:4] 也是 0xFFF —— 兼容区判决一旦漏掉 `!addr[16]`\n"
            "      （rtl/bus/mem_bus.v），它就会被当成 MMIO 误判。镜像不许用它：\n"
            "      RT-Thread 的栈顶只能到 0x1FFF0（不含）。"
            % (name, len(hit), RESERVED_FIRST, RESERVED_LAST, min(hit) * 4))

    # 1) 段内越界
    if hi >= end:
        raise MergeError(
            "镜像 %s 越界：占 0x%05x~0x%05x，而它自己的区间是 0x%05x~0x%05x（%s）。\n"
            "      超出 %d 字节 —— 先裁程序或调布局，别指望链接器帮你留空隙。"
            % (name, lo, hi, start, end - 1, path, hi - (end - 1)))

    # 全局 RAM 上界
    if hi > RAM_LAST_BYTE:
        raise MergeError("镜像 %s 结束于 0x%05x，超过 RAM 末字节 0x%05x"
                         % (name, hi, RAM_LAST_BYTE))


def write_hex(path, words):
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for idx in sorted(words):
            f.write("@%x\n%08x\n" % (idx, words[idx]))


def main():
    ap = argparse.ArgumentParser(description="合并 boot/CoreMark/RT-Thread 为单一 mem.hex")
    ap.add_argument("--boot", default=LAYOUT[0][3], help="boot selector 的 mem.hex")
    ap.add_argument("--coremark", default=LAYOUT[1][3], help="CoreMark 的 mem.hex")
    ap.add_argument("--rtthread", default=LAYOUT[2][3], help="RT-Thread 的 mem.hex")
    ap.add_argument("-o", "--out", default="sim/programs/mem.hex", help="输出合并镜像")
    ap.add_argument("--no-out", action="store_true", help="只校验，不写输出")
    args = ap.parse_args()

    paths = {"boot": args.boot, "coremark": args.coremark, "rtthread": args.rtthread}

    merged = {}
    owner = {}            # word -> 镜像名，用来报"谁和谁撞了"
    stats = []
    images = {}           # name -> words

    try:
        # 先全部读进来：重叠检查要在"越界"之前做，否则两块撞在一起时只会报越界，
        # 看不出真正的原因是布局算错了（报错信息要指向根因）。
        for name, start, end, _default in LAYOUT:
            path = paths[name]
            if not os.path.exists(path):
                raise MergeError("找不到 %s 的镜像：%s（先跑对应的 build 脚本）" % (name, path))
            images[name] = parse_hex(path)

        # 2) 交叉重叠：统一存储器只有一份，重叠 = 静默覆盖
        names = [n for n, _s, _e, _d in LAYOUT]
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                a, b = names[i], names[j]
                clash = sorted(set(images[a]) & set(images[b]))
                if clash:
                    raise MergeError(
                        "镜像 %s 与 %s 有 %d 个字重叠（最小 0x%05x）。\n"
                        "      统一存储器只有一份，后写会静默覆盖先写 —— 必须调布局。"
                        % (a, b, len(clash), clash[0] * 4))

        for name, start, end, _default in LAYOUT:
            path = paths[name]
            words = images[name]
            check_image(name, words, start, end, path)
            for w, v in words.items():
                merged[w] = v
                owner[w] = name
            lo, hi = byte_span(words)
            stats.append((name, lo, hi, len(words), end - start))
    except MergeError as e:
        print("错误: %s" % e, file=sys.stderr)
        return 2

    # ---- 报告 ----
    print("镜像布局（%d 个字 / %d 行 hex）:" % (len(merged), len(merged) * 2))
    print("  %-9s %-19s %-9s %-9s %s" % ("镜像", "占用字节", "字数", "区间大小", "用量"))
    for name, lo, hi, n, cap in stats:
        used = hi - lo + 1
        print("  %-9s 0x%05x~0x%05x  %8d  %8d  %5.1f%%"
              % (name, lo, hi, n, cap, 100.0 * used / cap))

    # 三块之间是否留了缝隙（不是错误，只是让"为什么这么大"一眼可见）
    for i in range(len(stats) - 1):
        gap = stats[i + 1][1] - (stats[i][2] + 1)
        if gap > 0:
            print("  （%s 与 %s 之间空隙 %d 字节）" % (stats[i][0], stats[i + 1][0], gap))

    if args.no_out:
        print("已校验通过（--no-out，未写文件）")
        return 0

    write_hex(args.out, merged)
    print("已写出：%s（%d 字，%d 行）" % (args.out, len(merged), len(merged) * 2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
