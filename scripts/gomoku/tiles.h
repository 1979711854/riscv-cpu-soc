/* ==========================================================================
 * tiles.h —— 五子棋的调色板与图块表
 *
 * [!] 本文件由 scripts/gomoku/gen_tiles.py **自动生成，不要手改**。
 *     改颜色/线宽/棋子大小请改那个脚本再重跑。
 *
 * 图块编号：tile = shape * 4 + state
 *   shape 0..8 = 内部/上边/下边/左边/右边/左上/右上/左下/右下
 *   state 0..3 = 空 / 黑子 / 白子 / 光标
 * 共 36 块 × 256 字节 = 9216 字节。
 * ========================================================================== */

#ifndef GOMOKU_TILES_H
#define GOMOKU_TILES_H

#include <stdint.h>
#include "palette.h"   /* 调色板独立一份：CoreMark 的文本控制台也 include 它 */

#define TILE_W         16
#define TILE_BYTES     256
#define TILE_N_SHAPE   9
#define TILE_N_STATE   4
#define TILE_N_TOTAL   36

#define TILE_SHAPE_INNER       0
#define TILE_SHAPE_TOP         1
#define TILE_SHAPE_BOTTOM      2
#define TILE_SHAPE_LEFT        3
#define TILE_SHAPE_RIGHT       4
#define TILE_SHAPE_TOPLEFT     5
#define TILE_SHAPE_TOPRIGHT    6
#define TILE_SHAPE_BOTLEFT     7
#define TILE_SHAPE_BOTRIGHT    8

#define TILE_ST_EMPTY  0
#define TILE_ST_BLACK  1
#define TILE_ST_WHITE  2
#define TILE_ST_CURSOR 3

#define TILE_OF(shape, state)  ((uint8_t)((shape) * TILE_N_STATE + (state)))

/* 调色板（TILE_N_PALETTE / TILE_PALETTE）在 palette.h 里，见上面的 include */

/* [!] 2026-10-18：36 块棋盘图块的**像素表**已从本文件移走 ——
 *     render.c 现在按同一套几何**运行时合成**（synth_board_tile），
 *     省下 9,216 字节 .rodata（RT-Thread 镜像就靠这 9KB 才装得下堆）。
 *     像素表在 tiles_data.h，**只给 x86 单测当参考真值**，不进固件。 */

#endif /* GOMOKU_TILES_H */
