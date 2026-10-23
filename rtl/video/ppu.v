`timescale 1ns/1ps
// ============================================================================
// ppu —— tile 背景层像素引擎（无精灵、无窗口、无颜色强调）
// ----------------------------------------------------------------------------
// 把 (x_act, y_act) 变成 24bit RGB，每个像素走 3 次 BRAM 读：
//
//   E1  (x_act,y_act) + scroll → nametable 地址；顺手锁住子块坐标 px/py
//   E2  nametable 读出 tile_id（8bit）
//   E3  {tile_id,py,px} → pattern 地址
//   E4  pattern 读出颜色索引（8bit）
//   E5  palette 查出 RGB（24bit）
//   E6  RGB 打一拍输出
//
// [!] 总延迟 LAT = 6 拍。de/hs/vs 用与像素流水同深度的移位链同步延迟，深度必须
//     严格等于 LAT：差 1 拍图像整体横向错位，"de 有效区"与"rgb"对不上，
//     屏幕左边多出一条错位竖带（tb_ppu.v 逐像素比对）。
//
// 为什么是 tile 而不是线性 framebuffer：横向滚动是硬需求。线性 640x480 显存
// 要 300KB，且滚动一次要 CPU 重画整屏，每帧可用拍数根本不够；tile 方案下
// 滚动只是改 scroll_x 一个寄存器，PPU 自己算该取哪块图块。
//
// 世界坐标与环绕：
//   world_x = x_act + scroll_x   12bit 自然截断 ⇒ 世界宽 4096px = 256 块
//   world_y = y_act + scroll_y   12bit 自然截断
//   tile_col = world_x[11:4]     8bit，256 列
//   tile_row = world_y[8:4]      5bit，32 行（世界高 512px ≥ 屏高 480）
//   nametable 地址 = {tile_row[4:0], tile_col[7:0]} = 13bit = 8KB
//   12 位自然截断 = 环绕：滚到世界右端会环回左端，属预期行为。
//
// 图块 16×16 ⇒ 屏上 40 列 × 30 行；pattern 每块 256 字节，256 块 = 64KB。
//
// 本模块不含任何原语，可以整体进 iverilog（见 sim/tb_ppu.v）。
// ============================================================================
module ppu (
    input  wire        pix_clk,
    input  wire        rstn,

    // ---- 时序输入（sync_vg 输出，与本模块同拍）----
    input  wire [11:0] x_act,
    input  wire [11:0] y_act,
    input  wire        de_ph,
    input  wire        hs_ph,
    input  wire        vs_ph,

    // ---- 控制寄存器（clk_sys 域写，本模块按准静态处理）----
    input  wire [11:0] scroll_x,
    input  wire [11:0] scroll_y,

    // ---- nametable 读口（8bit × 8K）----
    output wire [12:0] nt_addr,
    input  wire [7:0]  nt_rdata,

    // ---- pattern 读口（8bit × 64K）----
    output wire [15:0] pat_addr,
    input  wire [7:0]  pat_rdata,

    // ---- palette 读口（24bit × 256）；地址是组合的，见 E5 说明 ----
    output wire [7:0]  pal_addr,
    input  wire [23:0] pal_rdata,

    // ---- 输出（已寄存、负极性，可直接喂 rgb2tmds）----
    output wire [23:0] rgb,
    output wire        de,
    output wire        hs,
    output wire        vs
);

    // ------------------------------------------------------------------
    // 同步信号延迟链：深度必须严格等于像素流水延迟 LAT = 6
    //   sy0 在第 1 拍有效，sy5 在第 6 拍有效 —— 正好与 rgb_r 同拍。
    //   极性在这里取反：640×480@60 的 VESA DMT 是负极性
    //   （sync_vg 给的是行/帧起始的正脉冲，取反即得 DMT 结构）。
    // ------------------------------------------------------------------
    reg [2:0] sy0, sy1, sy2, sy3, sy4, sy5;

    always @(posedge pix_clk) begin
        if (!rstn) begin
            sy0 <= 3'd0; sy1 <= 3'd0; sy2 <= 3'd0;
            sy3 <= 3'd0; sy4 <= 3'd0; sy5 <= 3'd0;
        end else begin
            sy0 <= {de_ph, ~hs_ph, ~vs_ph};
            sy1 <= sy0;
            sy2 <= sy1;
            sy3 <= sy2;
            sy4 <= sy3;
            sy5 <= sy4;
        end
    end

    assign {de, hs, vs} = sy5;

    // ------------------------------------------------------------------
    // E1：世界坐标 → nametable 地址；同时锁住子块坐标 px/py（E3 要用）
    //
    //   加法的 12bit 截断就是环绕（见文件头）。这里用到的位：
    //     nt_addr = {world_y[8:4], world_x[11:4]}
    //     px      = world_x[3:0]   块内列
    //     py      = world_y[3:0]   块内行
    // ------------------------------------------------------------------
    wire [11:0] world_x = x_act + scroll_x;
    wire [11:0] world_y = y_act + scroll_y;

    reg [12:0] nt_addr_r;
    reg [11:0] wx_r, wy_r;

    always @(posedge pix_clk) begin
        if (!rstn) begin
            nt_addr_r <= 13'd0;
            wx_r      <= 12'd0;
            wy_r      <= 12'd0;
        end else begin
            nt_addr_r <= {world_y[8:4], world_x[11:4]};
            wx_r      <= world_x;
            wy_r      <= world_y;
        end
    end

    assign nt_addr = nt_addr_r;

    // ------------------------------------------------------------------
    // E2：世界坐标再锁一拍 —— 这一级是必需的，不是凑数。
    //
    //   nametable 是 1 拍 BRAM：E1 给出的地址要到第 2 拍数据才出来。
    //   块内坐标必须拖到同一拍，否则 tile_id 说的是像素 X 那一块，
    //   而 px 已经走到 X+1 —— 取出来的是"X 块的 X+1 列"，整屏右移 1 像素，
    //   且块内看不出来，只有块边界那几列会突然跳一格。
    // ------------------------------------------------------------------
    reg [11:0] wx_r2, wy_r2;

    always @(posedge pix_clk) begin
        if (!rstn) begin
            wx_r2 <= 12'd0;
            wy_r2 <= 12'd0;
        end else begin
            wx_r2 <= wx_r;
            wy_r2 <= wy_r;
        end
    end

    // ------------------------------------------------------------------
    // E3：{tile_id, py, px} → pattern 地址
    //   16×16 块 ⇒ 每块 256 字节，地址 = tile_id*256 + py*16 + px，
    //   也就是把三段直接拼起来，不需要乘法器。
    // ------------------------------------------------------------------
    reg [15:0] pat_addr_r;

    always @(posedge pix_clk) begin
        if (!rstn) pat_addr_r <= 16'd0;
        else       pat_addr_r <= {nt_rdata, wy_r2[3:0], wx_r2[3:0]};
    end

    assign pat_addr = pat_addr_r;

    // ------------------------------------------------------------------
    // E5：palette 地址 = pattern 的颜色索引，直接组合接出去
    //   pat_rdata 是 E4 出来的 BRAM 输出寄存器，palette 在 E5 采样它，
    //   E6 得到 RGB —— 中间不再插寄存器。插了的话 LAT 变 7，
    //   上面的同步链也要跟着加一级，所以这里保持组合。
    // ------------------------------------------------------------------
    assign pal_addr = pat_rdata;

    // ------------------------------------------------------------------
    // E6：RGB 输出（本模块最后一级寄存器）
    // ------------------------------------------------------------------
    reg [23:0] rgb_r;

    always @(posedge pix_clk) begin
        if (!rstn) rgb_r <= 24'd0;
        else       rgb_r <= pal_rdata;
    end

    assign rgb = rgb_r;

endmodule
