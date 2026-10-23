#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_tiles.py —— 生成五子棋的调色板与图块表（轨道 A2）

    用法：  python scripts/gomoku/gen_tiles.py
    产物：  scripts/gomoku/tiles.h   （C 头文件，**自动生成，别手改**）

为什么用脚本生成而不是手画二进制：
  1. 图块是 16x16 = 256 字节/块，36 块 = 9216 字节 —— 手改一个像素就得重算一整个
     数组，不现实
  2. 棋盘线是"程序化"的（哪几条边有线而已），用代码描述比位图清楚得多
  3. 它是**【唯一真相】**：想改颜色/线宽/棋子大小，改这里的常数重跑即可；
     tiles.h 是产物，不需要 review

图块编号约定（render.c 依赖它，改这里必须同步改 render.c）：
    tile = shape * 4 + state
      shape 0..8  = 9 种网格线形状（见下面 SHAPES）
      state 0..3  = 0 空 / 1 黑子 / 2 白子 / 3 光标
    ⇒ 共 36 块，占 tile 0..35

显存映射（见 rtl/bus/addr_map.vh 的视频区小节）：
    调色板  VIDEO_PAL + i*4            = 0xRRGGBB（高 8 位忽略）
    图块像素 VIDEO_PAT + T*256 + py*16 + px = 调色板索引
"""
import sys

TILE = 16
N_SHAPE = 9
N_STATE = 4
N_TILE = N_SHAPE * N_STATE      # 36

# ---- 调色板 ----------------------------------------------------------------
# 索引 -> 24bit RGB。**索引号被 tiles 数组直接引用**，改顺序等于改画。
#
# [2026-10-18 标题屏改版] 前 7 项是棋盘/棋子的颜色，一项都不许动 ——
#   对局界面已上板、用户认可，这次只加**不冲突的新项**：
#     7  UI 深色底（墨绿）  —— 文字图块的背景，也是整屏底色
#     8  文字前景（暖白）
#     9  金色强调        —— logo / 选中框 / 分隔线
#    10  阴影（比 UI 底更深）—— 大 logo 的投影
#    11  分隔线（介于底与字之间）
#   [!] 为什么不用"整行金色底条"做选中态：字库图块的背景是**不透明**的，
#       整行铺金会被每个字的背景方块盖成一个个小方块（见任务书 §2.5.2）。
PAL = [
    0xE8C88C,   # 0  棋盘底色（浅木色）
    0x50381C,   # 1  棋盘线（深棕）
    0x101010,   # 2  黑子主体
    0x404040,   # 3  黑子高光
    0xF8F8F8,   # 4  白子主体
    0xA8A8A8,   # 5  白子描边
    0xD02020,   # 6  光标（红）
    0x18202C,   # 7  UI 底（深墨蓝）—— FONT_BG
    0xEDE3C8,   # 8  UI 文字（暖白）—— FONT_FG
    0xD8A93C,   # 9  金色强调（logo / 选中框 / 分隔线）
    0x0C1117,   # 10 阴影（比 UI 底更深）
    0x33404F,   # 11 细分隔线
    0x1E2836,   # 12 标题屏顶部/底部细带
    0x2ECC71,   # 13 OK / WINS（柔和绿，替掉高饱和 #00FF00）
    0x888888,   # 14 8x8 提示文字（暗灰）
    0x202A38,   # 15 极暗分隔线（只比 UI 底亮一丁点）
    0x8A6D2F,   # 16 暗金（说明行 > 锚点）
    0xA0A0A0,   # 17 标题中灰（二级菜单大标题，比 14 亮一档）
    0xFFD700,   # 18 亮金（CoreMark 终端演示屏大分数，GAME_COREMARK 专用）
]

(P_BG, P_LINE, P_BLACK, P_BLACK_HI, P_WHITE, P_WHITE_EDGE, P_CURSOR,
 P_UI_BG, P_UI_FG, P_GOLD, P_SHADOW, P_UI_LINE, P_UI_BAND,
 P_OK, P_UI_DIM, P_UI_FAINT, P_GOLD_DIM, P_UI_MID, P_GOLD_BRIGHT) = range(19)

# ---- 9 种网格线形状 --------------------------------------------------------
# 每个 shape 说明"四条边哪几条有线"：(上, 下, 左, 右)
# 顺序必须与 render.c 的 SHAPE_LUT 一致
SHAPES = [
    (1, 1, 1, 1),   # 0 内部（15x15 里占 13x13 = 169 个）
    (0, 1, 1, 1),   # 1 上边
    (1, 0, 1, 1),   # 2 下边
    (1, 1, 0, 1),   # 3 左边
    (1, 1, 1, 0),   # 4 右边
    (0, 1, 0, 1),   # 5 左上角
    (0, 1, 1, 0),   # 6 右上角
    (1, 0, 0, 1),   # 7 左下角
    (1, 0, 1, 0),   # 8 右下角
]

LINE_W = 2          # 线宽（像素）—— 2 像素在 640x480 上看得清又不糊
STONE_R = 6         # 棋子半径（像素）。6.5 取整为 6，留 1.5px 空隙不粘线
CURSOR_R = 7        # 光标半径


def blank():
    return [[P_BG] * TILE for _ in range(TILE)]


def draw_lines(g, shp):
    """按 shape 的四条边把线画上去。线居中：行/列 7..8（2 像素宽）。

    横线和竖线各自独立判断：两端都有线就贯穿整块，只有一端就从中心画到那一端。
    ⚠️ 关键是**必须画到块的边界（像素 0 / 15）** —— 否则相邻两块之间会断开，
       整张棋盘看起来是虚线。
    """
    up, dn, lf, rt = shp
    lo = (TILE - LINE_W) // 2          # 7
    hi = lo + LINE_W - 1               # 8

    if lf and rt:      xr = range(TILE)
    elif lf:           xr = range(0, lo + 1)
    elif rt:           xr = range(hi, TILE)
    else:              xr = range(0)
    for y in range(lo, hi + 1):
        for x in xr:
            g[y][x] = P_LINE

    if up and dn:      yr = range(TILE)
    elif up:           yr = range(0, lo + 1)
    elif dn:           yr = range(hi, TILE)
    else:              yr = range(0)
    for x in range(lo, hi + 1):
        for y in yr:
            g[y][x] = P_LINE


def draw_stone(g, color, hi_color):
    """实心圆 + 左上角高光（点光源在左上，看起来是凸的）。"""
    for y in range(TILE):
        for x in range(TILE):
            dx = x - (TILE - 1) / 2.0
            dy = y - (TILE - 1) / 2.0
            d2 = dx * dx + dy * dy
            if d2 <= STONE_R * STONE_R:
                # 高光：圆心往左上偏 2px 的另一个圆
                hx, hy = dx + 2.0, dy + 2.0
                g[y][x] = hi_color if (hx * hx + hy * hy) <= 4.0 else color


def draw_cursor(g):
    """空心圈 —— 画在空交叉点上，不能挡住棋盘的线。"""
    for y in range(TILE):
        for x in range(TILE):
            dx = x - (TILE - 1) / 2.0
            dy = y - (TILE - 1) / 2.0
            d2 = dx * dx + dy * dy
            if (CURSOR_R - 1.5) ** 2 <= d2 <= CURSOR_R * CURSOR_R:
                g[y][x] = P_CURSOR


def make_tile(shape, state):
    img = blank()
    draw_lines(img, SHAPES[shape])
    if state == 1:
        draw_stone(img, P_BLACK, P_BLACK_HI)
    elif state == 2:
        draw_stone(img, P_WHITE, P_WHITE_EDGE)   # 白子高光用描边色，避免太白看不出立体
    elif state == 3:
        draw_cursor(img)
    return img


# ---------------------------------------------------------------------------
# ASCII 字库（HUD 用）：紧凑 5x7 位图，上电时 render.c 放大 2x 成 16x16 图块。
# 只画大写/数字/常用标点；小写折叠到大写，其余可打印字符落到空格。
# 前景 FONT_FG（黑子主体色）/ 背景 FONT_BG（棋盘底色）。
# ---------------------------------------------------------------------------
FONT_W = 5
FONT_H = 7
FONT_SCALE = 2
FONT_BASE = 0x20

# ---------------------------------------------------------------------------
# [T6-R3] 8x8 系小字"加宽"：字模从 5x7 拉伸到 8x7。
# 动机：nametable 每字符占 1 个 16x16 图块 = 16px 步进，5px 字形意味着
# 字间空 11px（≈2 倍字宽），视觉上像 P O W E R E D。字形拉宽到 8px 后
# 字距 = 16-8 = 8px = 字宽，密度与正常英文一致。
# 拉伸在【生成脚本层】做（本文件），font.h 里的 8x8 系字模直接就是 8 位宽：
#   WIDEN5_8[d] = 目标列 d 取的源列。左右缘/中列各占 2px、次列 1px，
#   无裂缝（每个目标列都有源），竖线/点 2px、笔画加粗均匀。
# 覆盖：FONT8（暗灰提示）/ FONT8G（暗金 POWERED 行）/ FONT_TITLE_GRAY
# （标题中灰）三个子集；16x16 主字库与中文**保持 5x7 原样**（logo 还要用）。
# ---------------------------------------------------------------------------
FONT8_W = 8
WIDEN5_8 = (0, 0, 1, 2, 2, 3, 4, 4)


def font_row_bits8(ch, fy):
    """8x8 系字形第 fy 行打包成 8 位：bit7..bit0 = 列0..列7（拉伸后）。"""
    s = font_rows(ch)[fy]
    b = 0
    for dx in range(FONT8_W):
        if s[WIDEN5_8[dx]] == '#':
            b |= 1 << (FONT8_W - 1 - dx)
    return b

# ---------------------------------------------------------------------------
# 五子棋 UI 的 16x16 字库：**只做子集**（v2 交接文档 §2.2/§6.1）。
# 只收大写、数字和 UI 实际用到的符号；小写运行时折叠到大写。
# CoreMark 的控制台需要完整 95 字（含小写），单独生成 font_coremark.h，
# 不进五子棋镜像 —— 两边虽是同一块显存，但固件是两颗独立镜像，互不占位。
# ---------------------------------------------------------------------------
# [!] 2026-10-19 T6：回收 J/Q/X/Z（16x16 界面文案均不使用），51 -> 47 字，
#     36..86 区缩到 36..82，尾部 83..86 让给暗金 8x8 子集。
# [!] 2026-10-19 T6-R2：再回收 11 个符号 : - / | + % ( ) , ? ! —— 已全局搜索
#     确认 16x16 渲染调用（菜单/值/弹窗/HUD/GOMOKU/THINKING）零使用，其中
#     % ( ) , ? ! 的字模本来就是空表；未收录字符渲染时自动落空格图块，不会缺字。
#     47 -> 36 字（36..71），72..86 空出给暗金字库搬新家。
#     保留 . < > 三个：12.8K 的小数点、菜单值 < NORMAL > 的括号。
FONT_CHARS = " 0123456789ABCDEFGHIJKLMNOPRSTUVWY.<>"
FONT_N_GLYPHS = len(FONT_CHARS)
FONT_TILE_BASE = N_TILE     # 36：棋盘图块 0..35 之后

# ASCII 0x20..0x7E -> 子集下标；0xFF = 该字符不在子集里（运行时落空格）。
FONT_INDEX = [0xFF] * 95
for _i, _ch in enumerate(FONT_CHARS):
    FONT_INDEX[ord(_ch) - FONT_BASE] = _i
for _i in range(ord('A'), ord('Z') + 1):
    # 小写折叠到大写：渲染层先折叠，这里也建一份，方便生成/测试共用。
    FONT_INDEX[_i - FONT_BASE + 32] = FONT_INDEX[_i - FONT_BASE]

# ---------------------------------------------------------------------------
# 8x8 提示字库：5x7 位图按 1x 放在 16x16 图块中央（一个字符一块）。
# 只收 HUD 标签/提示用得上的字符；颜色是 PAL_UI_DIM（暗灰）。
# ---------------------------------------------------------------------------
# [!] 2026-10-19：回收 J/Q/X 三块（界面文案不用），给 8x16 小字腾 tile。
# [!] 2026-10-19 T6：回收 Z/-（全部界面文案均不使用；含 '-' 的 RISC-V
#     由下面的暗金子集负责渲染；F 要保留 —— 提示行 "LEFT" 用）。
# [!] 2026-10-19 T7：CoreMark 终端演示屏（GAME_COREMARK）要写 RISC-V / MHZ /
#     分隔线，'-','Z' 回归 —— 90..127 共 38 字（127 由暗金子集让出，见下）。
FONT8_CHARS = " 0123456789ABCDEFGHIKLMNOPRSTUVWY:-Z/|."
FONT8_N_GLYPHS = len(FONT8_CHARS)
FONT8_TILE_BASE = 90          # 16x16 子集 36..86 / 中文 87..89 之后
FONT8_INDEX = [0xFF] * 95
for _i, _ch in enumerate(FONT8_CHARS):
    FONT8_INDEX[ord(_ch) - FONT_BASE] = _i
for _i in range(ord('A'), ord('Z') + 1):
    FONT8_INDEX[_i - FONT_BASE + 32] = FONT8_INDEX[_i - FONT_BASE]

# ---------------------------------------------------------------------------
# [T6 2026-10-19] 8x16 小字整库退役（LAST COREMARK 区改用 8x8 后再无使用者），
# 释放 135..149 / 178..185 / 251..252 共 25 块；加上 8x8 缩容腾出的 127..128、
# 16x16 主子集回收 J/Q/X/Z 腾出的 83..86，共 31 块重新分配（用掉 28，空闲 3）：
#   FONT_GREEN16  绿色 16x16（HUD "THINKING"）：135..140（6 字 THINGK）
#   FONT_GOLD16   金色 16x16（HUD "GOMOKU" 标题）：141..145（5 字 GOMKU）
#   FONT8G        暗金 8x8（标题屏 "POWERED BY RISC-V & RT-THREAD"）：
#                 17 字 &-ABCDEHIOPRSTVWY -> 83..86 / 127 / 146..149 / 178..185
# 空闲：128、251..252。
# ---------------------------------------------------------------------------
FONT_GREEN16_CHARS = "THINGK"
GREEN16_TILE_NUMS = list(range(135, 141))
assert len(GREEN16_TILE_NUMS) == len(FONT_GREEN16_CHARS), "绿色 16x16 图块号数量必须等于字符数"
FONT_GREEN16_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT_GREEN16_CHARS):
    FONT_GREEN16_TILE[ord(_ch) - FONT_BASE] = GREEN16_TILE_NUMS[_i]
for _i in range(ord('A'), ord('Z') + 1):
    FONT_GREEN16_TILE[_i - FONT_BASE + 32] = FONT_GREEN16_TILE[_i - FONT_BASE]

FONT_GOLD16_CHARS = "GOMKU"
GOLD16_TILE_NUMS = list(range(141, 146))
assert len(GOLD16_TILE_NUMS) == len(FONT_GOLD16_CHARS), "金色 16x16 图块号数量必须等于字符数"
FONT_GOLD16_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT_GOLD16_CHARS):
    FONT_GOLD16_TILE[ord(_ch) - FONT_BASE] = GOLD16_TILE_NUMS[_i]
for _i in range(ord('A'), ord('Z') + 1):
    FONT_GOLD16_TILE[_i - FONT_BASE + 32] = FONT_GOLD16_TILE[_i - FONT_BASE]

# 暗金 8x8：只收 "POWERED BY RISC-V & RT-THREAD" 用到的 17 个字形。
# [T6-R2] 图块号搬到 73..86（16x16 主字库缩容腾出）+ 127/128/251，
# 腾出的 146..149 / 178..185 让给标题中灰子集。
# [T7] 127/128 让回给 8x8 灰字库（'-','Z'），换 180/181 两块空闲块
# （72 实际是 16x16 子集末字符 '>' 的图块 —— T6-R2 注释"72 空闲"已过时；
#   255 不能用 —— test_render 断言 RENDER_TILE_MAX=255 之后必须从未被写）。
FONT8G_CHARS = "&-ABCDEHIOPRSTVWY"
FONT8G_N_GLYPHS = len(FONT8G_CHARS)
FONT8G_TILE_NUMS = (list(range(73, 87)) + [180, 181, 251])
assert len(FONT8G_TILE_NUMS) == FONT8G_N_GLYPHS, "暗金 8x8 图块号数量必须等于字符数"
FONT8G_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT8G_CHARS):
    FONT8G_TILE[ord(_ch) - FONT_BASE] = FONT8G_TILE_NUMS[_i]
for _i in range(ord('A'), ord('Z') + 1):
    FONT8G_TILE[_i - FONT_BASE + 32] = FONT8G_TILE[_i - FONT_BASE]

# [T7 2026-10-19] 标题中灰 8x8 子集（T6-R2 的 AHIMNSUV @ 129/130/146..149/178/179）
# 【整集退役】：痛点二把二级菜单大标题改用 16x16 亮白（render_text_center）之后
# 全库再无使用者。图块号 129/130/146..149/178..179 释放为空闲；PAL_UI_MID
# 调色板项保留（免得 reindex，只是没人引用）。

# ---------------------------------------------------------------------------
# [2026-10-19 T7] CoreMark 终端演示屏（GAME_COREMARK，SW6+SW7 复位进入）专用
# 变色子集。图块是「借」的：演示屏期间覆写【标题屏专用】图块（4x logo /
# WINS / 中文 / GOMKU / THINKING 的一部分）—— 这些借主在演示屏上都不出现，
# 退出时 render_term_end() 调 render_init() 全量重建恢复。
#   TERM_GREEN16  亮绿 16x16（[ RUNNING ] / [ PASS ]）：[]RUNIGPAS 10 字
#                 -> 154..163（4x logo 前 10 块）
#   TERM_GOLD16   亮金 16x16（COREMARK SCORE / COREMARK/MHZ 两行大字）：
#                 COREMAKS/:.0123456789HZ 23 字
#                 -> 164..177（logo 后 14 块）+ 131..134（WINS）
#                    + 87..89（中文 3 字）+ 141..142（GOMKU 前 2 块）
#   TERM_GREEN8   亮绿 8x8（CRC OK）：OK 2 字 -> 143..144（GOMKU 中 2 块）
#   TERM_GRAY8    暗灰 8x8（进度百分比 %）：1 字 -> 145（GOMKU 末块）
# 实心块（进度条填充/空轨）不是字形：编号 135/136（THINKING 的 T/H），
# 定义在 render.h（RENDER_TILE_TERM_FILL/TRACK），同样由 render_init 恢复。
# 前景色：绿 = P_OK（#2ECC71，与规格完全相同）、亮金 = P_GOLD_BRIGHT（#FFD700）。
# ---------------------------------------------------------------------------
FONT_TERM_GREEN16_CHARS = "[]RUNIGPAS"
FONT_TERM_GREEN16_N = len(FONT_TERM_GREEN16_CHARS)
FONT_TERM_GREEN16_TILE_NUMS = list(range(154, 164))
FONT_TERM_GREEN16_FG = P_OK
FONT_TERM_GREEN16_BG = P_UI_BG
FONT_TERM_GREEN16_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT_TERM_GREEN16_CHARS):
    FONT_TERM_GREEN16_TILE[ord(_ch) - FONT_BASE] = FONT_TERM_GREEN16_TILE_NUMS[_i]

FONT_TERM_GOLD16_CHARS = "COREMAKS/:.0123456789HZ"
FONT_TERM_GOLD16_N = len(FONT_TERM_GOLD16_CHARS)
FONT_TERM_GOLD16_TILE_NUMS = (list(range(164, 178)) + [131, 132, 133, 134] +
                              [87, 88, 89] + [141, 142])
FONT_TERM_GOLD16_FG = P_GOLD_BRIGHT
FONT_TERM_GOLD16_BG = P_UI_BG
FONT_TERM_GOLD16_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT_TERM_GOLD16_CHARS):
    FONT_TERM_GOLD16_TILE[ord(_ch) - FONT_BASE] = FONT_TERM_GOLD16_TILE_NUMS[_i]

FONT_TERM_GREEN8_CHARS = "OK"
FONT_TERM_GREEN8_N = len(FONT_TERM_GREEN8_CHARS)
FONT_TERM_GREEN8_TILE_NUMS = [143, 144]
FONT_TERM_GREEN8_FG = P_OK
FONT_TERM_GREEN8_BG = P_UI_BG
FONT_TERM_GREEN8_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT_TERM_GREEN8_CHARS):
    FONT_TERM_GREEN8_TILE[ord(_ch) - FONT_BASE] = FONT_TERM_GREEN8_TILE_NUMS[_i]

FONT_TERM_GRAY8_CHARS = "%"
FONT_TERM_GRAY8_N = len(FONT_TERM_GRAY8_CHARS)
FONT_TERM_GRAY8_TILE_NUMS = [145]
FONT_TERM_GRAY8_FG = P_UI_DIM
FONT_TERM_GRAY8_BG = P_UI_BG
FONT_TERM_GRAY8_TILE = [0xFF] * 95
for _i, _ch in enumerate(FONT_TERM_GRAY8_CHARS):
    FONT_TERM_GRAY8_TILE[ord(_ch) - FONT_BASE] = FONT_TERM_GRAY8_TILE_NUMS[_i]

assert len(FONT_TERM_GREEN16_TILE_NUMS) == FONT_TERM_GREEN16_N
assert len(FONT_TERM_GOLD16_TILE_NUMS) == FONT_TERM_GOLD16_N
assert len(FONT_TERM_GREEN8_TILE_NUMS) == FONT_TERM_GREEN8_N
assert len(FONT_TERM_GRAY8_TILE_NUMS) == FONT_TERM_GRAY8_N

# ---------------------------------------------------------------------------
# 中文 3 字：五 / 子 / 棋。16x16 1bit，离线用 SimHei 14px Bold 渲染后
# 居中裁进 16x16（不依赖运行时字体；不引入整库中文）。
# ---------------------------------------------------------------------------
CJK_TILE_BASE = 87            # 16x16 子集 36..86 之后
CJK_GLYPHS = [
    ("五", [
        0x0000, 0x0000, 0x0000, 0x3FF8, 0x0300, 0x0300, 0x0300, 0x3FF0,
        0x0630, 0x0630, 0x0630, 0x0630, 0x7FFC, 0x0000, 0x0000, 0x0000]),
    ("子", [
        0x0000, 0x0000, 0x3FF8, 0x0038, 0x00E0, 0x0380, 0x0380, 0x7FFC,
        0x0380, 0x0380, 0x0380, 0x0380, 0x0380, 0x0700, 0x0000, 0x0000]),
    ("棋", [
        0x0000, 0x0000, 0x1998, 0x1BFC, 0x7D98, 0x3998, 0x39F8, 0x3D98,
        0x79F8, 0x7998, 0x1FFC, 0x1800, 0x19B8, 0x1F0C, 0x0000, 0x0000]),
]

# 每字 7 行 x 5 列，'#' 亮 / '.' 灭（左到右 = 列0..列4）
FONT_GLYPHS = {
    ' ': [".....",
          ".....",
          ".....",
          ".....",
          ".....",
          ".....",
          "....."],
    '!': ["..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          ".....",
          "..#.."],
    '0': [".###.",
          "#...#",
          "#..##",
          "#.#.#",
          "##..#",
          "#...#",
          ".###."],
    '1': ["..#..",
          ".##..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          ".###."],
    '2': [".###.",
          "#...#",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          "#####"],
    '3': [".###.",
          "#...#",
          "....#",
          "..##.",
          "....#",
          "#...#",
          ".###."],
    '4': ["...#.",
          "..##.",
          ".#.#.",
          "#..#.",
          "#####",
          "...#.",
          "...#."],
    '5': ["#####",
          "#....",
          "####.",
          "....#",
          "....#",
          "#...#",
          ".###."],
    '6': [".###.",
          "#....",
          "#....",
          "####.",
          "#...#",
          "#...#",
          ".###."],
    '7': ["#####",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          ".#...",
          ".#..."],
    '8': [".###.",
          "#...#",
          "#...#",
          ".###.",
          "#...#",
          "#...#",
          ".###."],
    '9': [".###.",
          "#...#",
          "#...#",
          ".####",
          "....#",
          "....#",
          ".###."],
    '&': [".##..",
          "#..#.",
          "#..#.",
          ".##..",
          "#.#.#",
          "#..#.",
          ".##.#"],
    'A': [".###.",
          "#...#",
          "#...#",
          "#####",
          "#...#",
          "#...#",
          "#...#"],
    'B': ["####.",
          "#...#",
          "#...#",
          "####.",
          "#...#",
          "#...#",
          "####."],
    'C': [".###.",
          "#...#",
          "#....",
          "#....",
          "#....",
          "#...#",
          ".###."],
    'D': ["####.",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "####."],
    'E': ["#####",
          "#....",
          "#....",
          "####.",
          "#....",
          "#....",
          "#####"],
    'F': ["#####",
          "#....",
          "#....",
          "####.",
          "#....",
          "#....",
          "#...."],
    'G': [".###.",
          "#...#",
          "#....",
          "#.###",
          "#...#",
          "#...#",
          ".####"],
    'H': ["#...#",
          "#...#",
          "#...#",
          "#####",
          "#...#",
          "#...#",
          "#...#"],
    'I': [".###.",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          ".###."],
    'J': ["..###",
          "...#.",
          "...#.",
          "...#.",
          "...#.",
          "#..#.",
          ".##.."],
    'K': ["#...#",
          "#..#.",
          "#.#..",
          "##...",
          "#.#..",
          "#..#.",
          "#...#"],
    'L': ["#....",
          "#....",
          "#....",
          "#....",
          "#....",
          "#....",
          "#####"],
    'M': ["#...#",
          "##.##",
          "#.#.#",
          "#.#.#",
          "#...#",
          "#...#",
          "#...#"],
    'N': ["#...#",
          "##..#",
          "#.#.#",
          "#..##",
          "#...#",
          "#...#",
          "#...#"],
    'O': [".###.",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          ".###."],
    'P': ["####.",
          "#...#",
          "#...#",
          "####.",
          "#....",
          "#....",
          "#...."],
    'Q': [".###.",
          "#...#",
          "#...#",
          "#...#",
          "#.#.#",
          "#..#.",
          ".##.#"],
    'R': ["####.",
          "#...#",
          "#...#",
          "####.",
          "#.#..",
          "#..#.",
          "#...#"],
    'S': [".####",
          "#....",
          "#....",
          ".###.",
          "....#",
          "....#",
          "####."],
    'T': ["#####",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#.."],
    'U': ["#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          ".###."],
    'V': ["#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          ".#.#.",
          "..#.."],
    'W': ["#...#",
          "#...#",
          "#...#",
          "#.#.#",
          "#.#.#",
          "##.##",
          "#...#"],
    'X': ["#...#",
          "#...#",
          ".#.#.",
          "..#..",
          ".#.#.",
          "#...#",
          "#...#"],
    'Y': ["#...#",
          "#...#",
          ".#.#.",
          "..#..",
          "..#..",
          "..#..",
          "..#.."],
    'Z': ["#####",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          "#....",
          "#####"],
    ':': [".....",
          "..#..",
          "..#..",
          ".....",
          "..#..",
          "..#..",
          "....."],
    # [2026-10-18 第二轮] 界面文案要用 '='（HOLD = OK / ITER = 3900）
    '=': [".....",
          ".....",
          "#####",
          ".....",
          "#####",
          ".....",
          "....."],
    # v2 子菜单的值用 < > 括起来（< NORMAL >）
    '<': ["...#.",
          "..#..",
          ".#...",
          "#....",
          ".#...",
          "..#..",
          "...#."],
    '>': ["#....",
          ".#...",
          "..#..",
          "...#.",
          "..#..",
          ".#...",
          "#...."],
    # 提示行用 '|' 分两段（UP/DN MOVE | L/R CHANGE）。5x7 里就是一列竖线。
    '|': ["..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#.."],
    # CoreMark 结果页要给 @ 76.5MHz 用
    '@': [".###.",
          "#...#",
          "#.##.",
          "#.#.#",
          "#.##.",
          "#....",
          ".###."],
    # [2026-10-18] 标题屏副标题 "RISC-V + RT-THREAD" 要用 '+'。
    #   原字库没有它（会落成空格），补一个 5x7 的十字。
    '+': [".....",
          "..#..",
          "..#..",
          "#####",
          "..#..",
          "..#..",
          "....."],
    # [2026-10-19 T7] CoreMark 终端演示屏要用 [ ]（[ RUNNING ]）与 %（百分比）。
    '[': [".###.",
          ".#...",
          ".#...",
          ".#...",
          ".#...",
          ".#...",
          ".###."],
    ']': [".###.",
          "...#.",
          "...#.",
          "...#.",
          "...#.",
          "...#.",
          ".###."],
    '%': ["##..#",
          "##..#",
          "...#.",
          "..#..",
          ".#...",
          "#..##",
          "#..##"],
    '.': [".....",
          ".....",
          ".....",
          ".....",
          ".....",
          "..#..",
          "....."],
    '-': [".....",
          ".....",
          ".....",
          ".###.",
          ".....",
          ".....",
          "....."],
    '/': ["....#",
          "....#",
          "...#.",
          "..#..",
          ".#...",
          "#....",
          "#...."],
}


def font_rows(ch):
    """返回 ch 的 7x5 位图（字符串列表）。小写折叠到大写，未定义 -> 空格。"""
    if ch == ' ':
        return FONT_GLYPHS[' ']
    if 'a' <= ch <= 'z':
        ch = chr(ord(ch) - 32)
    return FONT_GLYPHS.get(ch, FONT_GLYPHS[' '])


def font_row_bits(ch, fy):
    """字形第 fy 行打包成 5 位：bit4..bit0 = 列0..列4，1 = 亮。"""
    s = font_rows(ch)[fy]
    b = 0
    for fx in range(FONT_W):
        if s[fx] == '#':
            b |= 1 << (FONT_W - 1 - fx)
    return b


def make_font_tile(ch):
    """把 ch 放大 FONT_SCALE 倍成 16x16 图块（预览用；固件在 render.c 做同一件事）。"""
    rows = font_rows(ch)
    img = [[P_UI_BG] * TILE for _ in range(TILE)]
    ox = (TILE - FONT_W * FONT_SCALE) // 2
    oy = (TILE - FONT_H * FONT_SCALE) // 2
    for fy in range(FONT_H):
        for fx in range(FONT_W):
            if rows[fy][fx] == '#':
                for sy in range(FONT_SCALE):
                    for sx in range(FONT_SCALE):
                        img[oy + fy * FONT_SCALE + sy][ox + fx * FONT_SCALE + sx] = P_UI_FG
    return img


def _c_string(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def _emit_index(f, name, chars):
    """输出 95 项的 ASCII -> 子集下标表（0xFF = 不在子集里）。"""
    idx = [0xFF] * 95
    for i, ch in enumerate(chars):
        idx[ord(ch) - FONT_BASE] = i
    for c in range(ord('A'), ord('Z') + 1):
        idx[c - FONT_BASE + 32] = idx[c - FONT_BASE]
    f.write("static const uint8_t %s[95] = {\n" % name)
    for row in range(0, 95, 16):
        vals = idx[row:row + 16]
        f.write("    " + ", ".join("0x%02X" % v for v in vals) + ",\n")
    f.write("};\n\n")


def _emit_tile_map(f, name, chars, tiles):
    """输出 95 项 ASCII -> 绝对图块号（0xFF = 不在子集里）。"""
    tbl = [0xFF] * 95
    for ch, t in zip(chars, tiles):
        tbl[ord(ch) - FONT_BASE] = t
    for c in range(ord('A'), ord('Z') + 1):
        tbl[c - FONT_BASE + 32] = tbl[c - FONT_BASE]
    f.write("static const uint8_t %s[95] = {\n" % name)
    for row in range(0, 95, 16):
        vals = tbl[row:row + 16]
        f.write("    " + ", ".join("0x%02X" % v for v in vals) + ",\n")
    f.write("};\n\n")


def _emit_glyphs(f, name, chars, w=FONT_W):
    """输出子集字模位图。w=FONT_W(5) → 原始 5x7（16x16 系）；
    w=FONT8_W(8) → 8x7 拉宽（T6-R3，8x8 系三个子集）。"""
    bits_fn = font_row_bits if w == FONT_W else font_row_bits8
    f.write("static const uint8_t %s[%d][FONT_H] = {\n" % (name, len(chars)))
    for ch in chars:
        bits = [bits_fn(ch, fy) for fy in range(FONT_H)]
        f.write("    { %s },   /* '%s' 0x%02X */\n"
                % (", ".join("0x%02X" % b for b in bits), ch, ord(ch)))
    f.write("};\n\n")


def emit_font(path):
    """生成五子棋 UI 的 font.h：16x16 子集 + 8x8 提示子集 + 中文 3 字。

    [!] CoreMark 的控制台**不 include 这个文件**（它要完整 95 字含小写），
        见 emit_font_coremark() 生成的 font_coremark.h。
    """
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * font.h —— 五子棋 UI 字库（16x16 子集 / 8x8 提示 / 暗金·中灰·金绿子集 / 中文 3 字）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" * [!] CoreMark 控制台用 font_coremark.h（完整 95 字）；两边是独立镜像。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_FONT_H\n#define GOMOKU_FONT_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define FONT_W          %d\n" % FONT_W)
        f.write("#define FONT_H          %d\n" % FONT_H)
        f.write("#define FONT8_W         %d   /* 8x8 系小字字模宽（T6-R3 拉宽）*/\n" % FONT8_W)
        f.write("#define FONT_SCALE      %d\n" % FONT_SCALE)
        f.write("#define FONT_BASE       %d   /* ASCII 表起点 */\n" % FONT_BASE)
        f.write("#define FONT_N_GLYPHS   %d   /* 子集字数 */\n" % FONT_N_GLYPHS)
        f.write("#define FONT_TILE_BASE  %d   /* 棋盘图块 0..35 之后 */\n" % FONT_TILE_BASE)
        f.write("#define FONT_FG         %d   /* 文字前景（暖白，见 palette.h）*/\n" % P_UI_FG)
        f.write("#define FONT_BG         %d   /* 文字背景（深色 UI 底，见 palette.h）*/\n\n" % P_UI_BG)
        f.write("/* 子集字符表（顺序 = 图块顺序）；小写运行时折叠到大写 */\n")
        f.write("static const char FONT_CHARS[FONT_N_GLYPHS + 1] = %s;\n\n" % _c_string(FONT_CHARS))
        f.write("/* ASCII 0x20..0x7E -> 子集下标；0xFF = 不在子集里（落空格）*/\n")
        _emit_index(f, "FONT_INDEX", FONT_CHARS)
        f.write("/* FONT_GLYPH[字模][行] = 5 位位图：bit4..bit0 = 列0..列4，1 = 亮 */\n")
        _emit_glyphs(f, "FONT_GLYPH", FONT_CHARS)

        # ---- 8x8 提示子集（5x7 1x，居中放进 16x16 图块）----
        f.write("/* ---- 8x8 提示字库：5x7 按 1x 居中，一个字符一块 ---- */\n")
        f.write("#define FONT8_N_GLYPHS   %d\n" % FONT8_N_GLYPHS)
        f.write("#define FONT8_TILE_BASE  %d\n" % FONT8_TILE_BASE)
        f.write("#define FONT8_FG         %d   /* 暗灰，见 palette.h */\n" % P_UI_DIM)
        f.write("#define FONT8_BG         %d\n\n" % P_UI_BG)
        f.write("static const char FONT8_CHARS[FONT8_N_GLYPHS + 1] = %s;\n\n" % _c_string(FONT8_CHARS))
        _emit_index(f, "FONT8_INDEX", FONT8_CHARS)
        _emit_glyphs(f, "FONT8_GLYPH", FONT8_CHARS, w=FONT8_W)

        # ---- 暗金 8x8 子集（标题屏 POWERED 行）：同 8x8 几何，前景暗金 ----
        f.write("/* ---- 暗金 8x8 子集（标题屏 POWERED 行）：5x7 1x 居中，暗金 ---- */\n")
        f.write("#define FONT8G_N_GLYPHS   %d\n" % FONT8G_N_GLYPHS)
        f.write("#define FONT8G_FG         %d   /* 暗金，见 palette.h */\n" % P_GOLD_DIM)
        f.write("#define FONT8G_BG         %d\n\n" % P_UI_BG)
        f.write("static const char FONT8G_CHARS[FONT8G_N_GLYPHS + 1] = %s;\n\n" % _c_string(FONT8G_CHARS))
        _emit_glyphs(f, "FONT8G_GLYPH", FONT8G_CHARS, w=FONT8_W)
        f.write("/* ASCII 0x20..0x7E -> 绝对图块号；0xFF = 不在子集里 */\n")
        f.write("static const uint8_t FONT8G_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT8G_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        # ---- [T7] 标题中灰 8x8 子集已整集退役（痛点二后无使用者）----
        f.write("/* [T7] 标题中灰 8x8 子集已退役（二级菜单大标题改 16x16 亮白）；\n")
        f.write(" * 图块号 129/130/146..149/178..179 释放为空闲。 */\n\n")

        # ---- 金色 16x16 子集（HUD 标题 GOMOKU）：2x 字模，金色 ----
        f.write("/* ---- 金色 16x16 子集（HUD 标题 GOMOKU）：2x 字模，金色 ---- */\n")
        f.write("#define FONT_GOLD16_N      %d\n" % len(FONT_GOLD16_CHARS))
        f.write("#define FONT_GOLD16_FG     %d   /* 金色，见 palette.h */\n" % P_GOLD)
        f.write("#define FONT_GOLD16_BG     %d\n\n" % P_UI_BG)
        f.write("static const char FONT_GOLD16_CHARS[FONT_GOLD16_N + 1] = %s;\n\n" % _c_string(FONT_GOLD16_CHARS))
        f.write("/* ASCII 0x20..0x7E -> 绝对图块号；0xFF = 不在子集里 */\n")
        f.write("static const uint8_t FONT_GOLD16_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT_GOLD16_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        # ---- 绿色 16x16 子集（HUD THINKING）：2x 字模，柔和绿 ----
        f.write("/* ---- 绿色 16x16 子集（HUD THINKING）：2x 字模，柔和绿 ---- */\n")
        f.write("#define FONT_GREEN16_N     %d\n" % len(FONT_GREEN16_CHARS))
        f.write("#define FONT_GREEN16_FG    %d   /* 柔和绿，见 palette.h */\n" % P_OK)
        f.write("#define FONT_GREEN16_BG    %d\n\n" % P_UI_BG)
        f.write("static const char FONT_GREEN16_CHARS[FONT_GREEN16_N + 1] = %s;\n\n" % _c_string(FONT_GREEN16_CHARS))
        f.write("/* ASCII 0x20..0x7E -> 绝对图块号；0xFF = 不在子集里 */\n")
        f.write("static const uint8_t FONT_GREEN16_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT_GREEN16_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        # ---- CoreMark 终端演示屏专用子集（T7，图块借标题屏专用块，见上）----
        f.write("/* ---- 终端演示屏（GAME_COREMARK）：绿/亮金 16x16 + 绿/灰 8x8 ----\n")
        f.write(" * [!] 图块号是「借」标题屏专用块的（logo/WINS/中文/GOMKU/THINKING），\n")
        f.write(" *     只在 render_term_begin() 之后有效；render_term_end() 全量恢复。 */\n\n")
        f.write("#define FONT_TERM_GREEN16_N  %d\n" % FONT_TERM_GREEN16_N)
        f.write("#define FONT_TERM_GREEN16_FG %d   /* 柔和绿 #2ECC71 */\n" % FONT_TERM_GREEN16_FG)
        f.write("#define FONT_TERM_GREEN16_BG %d\n\n" % FONT_TERM_GREEN16_BG)
        f.write("static const char FONT_TERM_GREEN16_CHARS[FONT_TERM_GREEN16_N + 1] = %s;\n\n" % _c_string(FONT_TERM_GREEN16_CHARS))
        _emit_glyphs(f, "FONT_TERM_GREEN16_GLYPH", FONT_TERM_GREEN16_CHARS)
        f.write("static const uint8_t FONT_TERM_GREEN16_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT_TERM_GREEN16_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        f.write("#define FONT_TERM_GOLD16_N   %d\n" % FONT_TERM_GOLD16_N)
        f.write("#define FONT_TERM_GOLD16_FG  %d   /* 亮金 #FFD700 */\n" % FONT_TERM_GOLD16_FG)
        f.write("#define FONT_TERM_GOLD16_BG  %d\n\n" % FONT_TERM_GOLD16_BG)
        f.write("static const char FONT_TERM_GOLD16_CHARS[FONT_TERM_GOLD16_N + 1] = %s;\n\n" % _c_string(FONT_TERM_GOLD16_CHARS))
        _emit_glyphs(f, "FONT_TERM_GOLD16_GLYPH", FONT_TERM_GOLD16_CHARS)
        f.write("static const uint8_t FONT_TERM_GOLD16_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT_TERM_GOLD16_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        f.write("#define FONT_TERM_GREEN8_N   %d\n" % FONT_TERM_GREEN8_N)
        f.write("#define FONT_TERM_GREEN8_FG  %d\n" % FONT_TERM_GREEN8_FG)
        f.write("#define FONT_TERM_GREEN8_BG  %d\n\n" % FONT_TERM_GREEN8_BG)
        f.write("static const char FONT_TERM_GREEN8_CHARS[FONT_TERM_GREEN8_N + 1] = %s;\n\n" % _c_string(FONT_TERM_GREEN8_CHARS))
        _emit_glyphs(f, "FONT_TERM_GREEN8_GLYPH", FONT_TERM_GREEN8_CHARS, w=FONT8_W)
        f.write("static const uint8_t FONT_TERM_GREEN8_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT_TERM_GREEN8_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        f.write("#define FONT_TERM_GRAY8_N    %d\n" % FONT_TERM_GRAY8_N)
        f.write("#define FONT_TERM_GRAY8_FG   %d\n" % FONT_TERM_GRAY8_FG)
        f.write("#define FONT_TERM_GRAY8_BG   %d\n\n" % FONT_TERM_GRAY8_BG)
        f.write("static const char FONT_TERM_GRAY8_CHARS[FONT_TERM_GRAY8_N + 1] = %s;\n\n" % _c_string(FONT_TERM_GRAY8_CHARS))
        _emit_glyphs(f, "FONT_TERM_GRAY8_GLYPH", FONT_TERM_GRAY8_CHARS, w=FONT8_W)
        f.write("static const uint8_t FONT_TERM_GRAY8_TILE[95] = {\n")
        for row in range(0, 95, 16):
            f.write("    " + ", ".join("0x%02X" % v for v in FONT_TERM_GRAY8_TILE[row:row + 16]) + ",\n")
        f.write("};\n\n")

        # ---- 中文 3 字 ----
        f.write("/* ---- 中文 3 字：五 / 子 / 棋（16x16 1bit，金色）---- */\n")
        f.write("#define FONT_CJK_N         3\n")
        f.write("#define FONT_CJK_TILE_BASE %d\n\n" % CJK_TILE_BASE)
        f.write("static const uint16_t FONT_CJK_BITS[FONT_CJK_N][16] = {\n")
        for ch, rows in CJK_GLYPHS:
            f.write("    {   /* %s */\n        " % ch)
            f.write(", ".join("0x%04X" % v for v in rows))
            f.write("\n    },\n")
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_FONT_H */\n")


def emit_font_coremark(path):
    """生成 CoreMark 控制台的 font.h 等价物：完整 95 字（含小写）。

    CoreMark 的 video_text.c 按 ASCII 顺序索引字模，不能子集化。
    """
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * font_coremark.h —— CoreMark HDMI 控制台字库（完整 95 字）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" * [!] 五子棋 UI 用 font.h（子集）；这是独立镜像，互不占 tile。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_FONT_COREMARK_H\n#define GOMOKU_FONT_COREMARK_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define FONT_W          %d\n" % FONT_W)
        f.write("#define FONT_H          %d\n" % FONT_H)
        f.write("#define FONT_SCALE      %d\n" % FONT_SCALE)
        f.write("#define FONT_BASE       %d\n" % FONT_BASE)
        f.write("#define FONT_N_GLYPHS   95\n")
        f.write("#define FONT_TILE_BASE  %d\n" % FONT_TILE_BASE)
        f.write("#define FONT_FG         %d\n" % P_UI_FG)
        f.write("#define FONT_BG         %d\n\n" % P_UI_BG)
        full = "".join(chr(c) for c in range(FONT_BASE, FONT_BASE + 95))
        _emit_glyphs(f, "FONT_GLYPH", full)
        f.write("#endif /* GOMOKU_FONT_COREMARK_H */\n")


def dump_font_preview(s="GOMOKU AI 123"):
    print("\n--- 字库预览（5x7 放大前）---")
    for ch in s:
        print("   [%s]" % ch)
        for row in font_rows(ch):
            print("    " + row.replace('.', ' '))
    print("\n--- 8x7 拉宽后（T6-R3，8x8 系小字实际字形；检查笔画清晰/无粘连）---")
    for ch in "PRESS0:|&":
        print("   [%s]" % ch)
        for fy in range(FONT_H):
            b = font_row_bits8(ch, fy)
            print("    " + "".join('#' if (b >> (FONT8_W - 1 - dx)) & 1 else ' '
                                   for dx in range(FONT8_W)))
    print("   放大 2x 后 'A'（16x16，'.'=背景 '#'=前景）:")
    img = make_font_tile('A')
    for row in img:
        print("    " + "".join('#' if v == P_BLACK else '.' for v in row))


PAL_NAMES = [
    ("PAL_BG",         "棋盘底色（浅木）"),
    ("PAL_LINE",       "棋盘线"),
    ("PAL_BLACK",      "黑子主体"),
    ("PAL_BLACK_HI",   "黑子高光"),
    ("PAL_WHITE",      "白子主体"),
    ("PAL_WHITE_EDGE", "白子描边"),
    ("PAL_RED",        "光标 / 最后一手"),
    ("PAL_UI_BG",      "UI 深色底（= FONT_BG）"),
    ("PAL_UI_FG",      "UI 文字暖白（= FONT_FG）"),
    ("PAL_GOLD",       "金色强调（logo / 选中框）"),
    ("PAL_SHADOW",     "阴影（比 UI 底更深）"),
    ("PAL_UI_LINE",    "细分隔线"),
    ("PAL_UI_BAND",    "标题屏顶部/底部细带"),
    ("PAL_OK",         "OK / WINS（柔和绿）"),
    ("PAL_UI_DIM",     "8x8 提示文字（暗灰）"),
    ("PAL_UI_FAINT",   "极暗分隔线"),
    ("PAL_GOLD_DIM",   "暗金（说明行锚点）"),
    ("PAL_UI_MID",     "标题中灰（子菜单大标题）"),
    ("PAL_GOLD_BRIGHT", "亮金（CoreMark 终端演示屏大分数）"),
]


def emit_palette(path):
    """调色板单独一份头文件。

    为什么要拆出来：CoreMark 的 HDMI 文本控制台（scripts/coremark_port/video_text.c）
    也要写同一张调色板。让它 include 这个 18 项的小表，而不是 tiles.h —— 后者带
    36 块 x 256B 的棋盘图块（9KB），CoreMark 镜像不该为了一行颜色把它装进去。
    """
    assert len(PAL_NAMES) == len(PAL)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * palette.h —— 调色板（五子棋 + CoreMark 文本控制台共用）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" *     改颜色改那个脚本再重跑。\n")
        f.write(" *\n")
        f.write(" * 前 7 项是棋盘/棋子色（对局界面已上板，不要动）；\n")
        f.write(" * 7..12 是深色 UI 配色；13=柔和绿（OK/WINS），14=8x8 提示暗灰，\n")
        f.write(" * 15=极暗分隔线，16=暗金说明锚点。\n")
        f.write(" * [" + "!" + "] FONT_BG / FONT_FG（font.h）分别取 PAL_UI_BG / PAL_UI_FG，\n")
        f.write(" *     所以整屏文字底、CoreMark 控制台底、标题屏底色**必然是同一个颜色**。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_PALETTE_H\n#define GOMOKU_PALETTE_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define TILE_N_PALETTE %d\n\n" % len(PAL))
        for i, (name, desc) in enumerate(PAL_NAMES):
            f.write("#define %-15s %2d   /* %s */\n" % (name, i, desc))
        f.write("\nstatic const uint32_t TILE_PALETTE[TILE_N_PALETTE] = {\n")
        for i, c in enumerate(PAL):
            f.write("    0x%06Xu%s   /* %d  %s */\n"
                    % (c, "," if i < len(PAL) - 1 else " ", i, PAL_NAMES[i][1]))
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_PALETTE_H */\n")


def emit(path):
    tiles = []
    for shape in range(N_SHAPE):
        for state in range(N_STATE):
            tiles.append(make_tile(shape, state))
    assert len(tiles) == N_TILE

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * tiles.h —— 五子棋的调色板与图块表\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" *     改颜色/线宽/棋子大小请改那个脚本再重跑。\n")
        f.write(" *\n")
        f.write(" * 图块编号：tile = shape * 4 + state\n")
        f.write(" *   shape 0..8 = 内部/上边/下边/左边/右边/左上/右上/左下/右下\n")
        f.write(" *   state 0..3 = 空 / 黑子 / 白子 / 光标\n")
        f.write(" * 共 %d 块 × 256 字节 = %d 字节。\n" % (N_TILE, N_TILE * 256))
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_TILES_H\n#define GOMOKU_TILES_H\n\n")
        f.write("#include <stdint.h>\n")
        f.write("#include \"palette.h\"   /* 调色板独立一份：CoreMark 的文本控制台也 include 它 */\n\n")
        f.write("#define TILE_W         %d\n" % TILE)
        f.write("#define TILE_BYTES     %d\n" % (TILE * TILE))
        f.write("#define TILE_N_SHAPE   %d\n" % N_SHAPE)
        f.write("#define TILE_N_STATE   %d\n" % N_STATE)
        f.write("#define TILE_N_TOTAL   %d\n\n" % N_TILE)
        f.write("#define TILE_SHAPE_INNER       0\n")
        f.write("#define TILE_SHAPE_TOP         1\n")
        f.write("#define TILE_SHAPE_BOTTOM      2\n")
        f.write("#define TILE_SHAPE_LEFT        3\n")
        f.write("#define TILE_SHAPE_RIGHT       4\n")
        f.write("#define TILE_SHAPE_TOPLEFT     5\n")
        f.write("#define TILE_SHAPE_TOPRIGHT    6\n")
        f.write("#define TILE_SHAPE_BOTLEFT     7\n")
        f.write("#define TILE_SHAPE_BOTRIGHT    8\n\n")
        f.write("#define TILE_ST_EMPTY  0\n")
        f.write("#define TILE_ST_BLACK  1\n")
        f.write("#define TILE_ST_WHITE  2\n")
        f.write("#define TILE_ST_CURSOR 3\n\n")
        f.write("#define TILE_OF(shape, state)  ((uint8_t)((shape) * TILE_N_STATE + (state)))\n\n")
        f.write("/* 调色板（TILE_N_PALETTE / TILE_PALETTE）在 palette.h 里，见上面的 include */\n\n")
        f.write("/* [!] 2026-10-18：36 块棋盘图块的**像素表**已从本文件移走 ——\n")
        f.write(" *     render.c 现在按同一套几何**运行时合成**（synth_board_tile），\n")
        f.write(" *     省下 9,216 字节 .rodata（RT-Thread 镜像就靠这 9KB 才装得下堆）。\n")
        f.write(" *     像素表在 tiles_data.h，**只给 x86 单测当参考真值**，不进固件。 */\n\n")
        f.write("#endif /* GOMOKU_TILES_H */\n")

    # ---- 参考像素表（只给单测用，不进固件）----
    dpath = path.replace("tiles.h", "tiles_data.h")
    with open(dpath, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* " + "=" * 74 + "\n")
        f.write(" * tiles_data.h —— 36 块棋盘图块的**参考像素表**（只给 x86 单测）\n")
        f.write(" *\n")
        f.write(" * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。\n")
        f.write(" * [!] **不要 include 进固件**：9,216 字节的常量表会把 RT-Thread 镜像顶爆。\n")
        f.write(" *     固件侧用 render.c 的 synth_board_tile() 运行时合成；\n")
        f.write(" *     test_render.c 拿这张表逐像素对拍，保证两边画出来的完全一样。\n")
        f.write(" * " + "=" * 74 + " */\n\n")
        f.write("#ifndef GOMOKU_TILES_DATA_H\n#define GOMOKU_TILES_DATA_H\n\n")
        f.write("#include \"tiles.h\"\n\n")
        f.write("/* [TILE_OF(shape,state)][py*16+px] = 调色板索引 */\n")
        f.write("static const uint8_t TILE_PATTERN[TILE_N_TOTAL][TILE_BYTES] = {\n")
        for i, img in enumerate(tiles):
            sh, st = i // N_STATE, i % N_STATE
            f.write("    {   /* tile %2d = shape %d state %d */\n" % (i, sh, st))
            for y in range(TILE):
                f.write("        " + ",".join("%d" % v for v in img[y]) + ",\n")
            f.write("    },\n")
        f.write("};\n\n")
        f.write("#endif /* GOMOKU_TILES_DATA_H */\n")


def dump_preview(n=2):
    """在终端里用字符画预览前 n 个 shape 的 4 个状态 —— 生成完扫一眼别画歪了。"""
    chars = {P_BG: ".", P_LINE: "#", P_BLACK: "@", P_BLACK_HI: "*",
             P_WHITE: "O", P_WHITE_EDGE: "o", P_CURSOR: "+"}
    for shape in range(n):
        print("--- shape %d ---" % shape)
        for state in range(N_STATE):
            img = make_tile(shape, state)
            for y in range(TILE):
                print("   " + "".join(chars[v] for v in img[y]) + "")
            print()


# ---- 2x2 棋盘（对局 480x480 / 标题小棋盘共用）-----------------------------
# 每个交叉点 32x32，切成 4 个 16x16 象限；去重后只输出「映射 + 描述表」。
# render.c 在 init 时按描述表重新合成唯一图块，**不把 62 x 256B 的像素表
# 放进 .rodata**（RT-Thread 镜像装不下）。
def make_cell32(shape, state):
    N = 32
    img = [[P_BG] * N for _ in range(N)]
    up, dn, lf, rt = SHAPES[shape]
    if lf or rt:
        x0 = 0 if lf else 16
        x1 = N - 1 if rt else 15
        for y in range(14, 18):
            for x in range(x0, x1 + 1):
                img[y][x] = P_LINE
    if up or dn:
        y0 = 0 if up else 16
        y1 = N - 1 if dn else 15
        for x in range(14, 18):
            for y in range(y0, y1 + 1):
                img[y][x] = P_LINE
    if state in (1, 2):
        color, hi = (P_BLACK, P_BLACK_HI) if state == 1 else (P_WHITE, P_WHITE_EDGE)
        for y in range(N):
            for x in range(N):
                dx = 2 * x - (N - 1)
                dy = 2 * y - (N - 1)
                if dx * dx + dy * dy <= 576:          # r = 12
                    hx = dx + 8                        # 高光圆心偏移 4px
                    hy = dy + 8
                    img[y][x] = hi if hx * hx + hy * hy <= 64 else color
    elif state == 3:
        # 金色对焦角标（v2 §5.5.8）：4 个 L 形角，替换旧的红色空心圈。
        # 几何必须与 render.c 的 synth_cell32() 逐像素一致。
        arm, th = 8, 3
        for y in range(N):
            for x in range(N):
                tl = (2 <= x < 2 + arm and 2 <= y < 2 + th) or \
                     (2 <= x < 2 + th and 2 <= y < 2 + arm)
                tr = (N - 2 - arm <= x < N - 2 and 2 <= y < 2 + th) or \
                     (N - 2 - th <= x < N - 2 and 2 <= y < 2 + arm)
                bl = (2 <= x < 2 + arm and N - 2 - th <= y < N - 2) or \
                     (2 <= x < 2 + th and N - 2 - arm <= y < N - 2)
                br = (N - 2 - arm <= x < N - 2 and N - 2 - th <= y < N - 2) or \
                     (N - 2 - th <= x < N - 2 and N - 2 - arm <= y < N - 2)
                if tl or tr or bl or br:
                    img[y][x] = P_GOLD
    return img


def quad_of(img, q):
    qy, qx = divmod(q, 2)
    return tuple(tuple(img[qy * 16 + y][qx * 16 + x] for x in range(16))
                 for y in range(16))


def emit_board2(path):
    uniq = {}
    order = []
    mp = [[[0] * 4 for _ in range(4)] for _ in range(9)]
    for shape in range(9):
        for state in range(4):
            img = make_cell32(shape, state)
            for q in range(4):
                t = quad_of(img, q)
                if t not in uniq:
                    uniq[t] = len(order)
                    order.append((shape, state, q))
                mp[shape][state][q] = uniq[t]
    n = len(uniq)
    if n > 68:
        raise SystemExit("2x2 board needs %d unique tiles > 68 free" % n)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/* Auto-generated by gen_tiles.py -- do not hand-edit. */\n")
        f.write("#ifndef GOMOKU_BOARD2_MAP_H\n#define GOMOKU_BOARD2_MAP_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("#define BOARD2_N_UNIQUE %d\n\n" % n)
        f.write("/* [shape][state][quad] -> unique index; quad: 0=TL 1=TR 2=BL 3=BR */\n")
        f.write("static const uint8_t BOARD2_MAP[9][4][4] = {\n")
        for shape in range(9):
            f.write("  {")
            for state in range(4):
                f.write("{" + ",".join(str(mp[shape][state][q]) for q in range(4)) + "}")
                if state != 3:
                    f.write(",")
            f.write("},\n")
        f.write("};\n\n")
        f.write("/* unique index -> packed (shape<<2)|state, and quadrant */\n")
        f.write("static const uint8_t BOARD2_DESC[BOARD2_N_UNIQUE] = {\n  ")
        f.write(",".join(str((s << 2) | st) for s, st, q in order))
        f.write("\n};\n")
        f.write("static const uint8_t BOARD2_QUAD[BOARD2_N_UNIQUE] = {\n  ")
        f.write(",".join(str(q) for s, st, q in order))
        f.write("\n};\n\n")
        f.write("#endif /* GOMOKU_BOARD2_MAP_H */\n")
    print("已生成 %s（unique=%d）" % (path, n))


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    pout = os.path.join(here, "palette.h")
    emit_palette(pout)
    print("已生成 %s" % pout)
    out = os.path.join(here, "tiles.h")
    emit(out)
    print("已生成 %s" % out)
    fout = os.path.join(here, "font.h")
    emit_font(fout)
    print("已生成 %s" % fout)
    fcout = os.path.join(here, "font_coremark.h")
    emit_font_coremark(fcout)
    print("已生成 %s" % fcout)
    emit_board2(os.path.join(here, "board2_map.h"))
    dump_preview(2)
    dump_font_preview()
