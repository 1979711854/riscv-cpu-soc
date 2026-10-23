`timescale 1ns/1ps
// ============================================================================
// video_core —— 480p60 时序 + tile PPU 背景层 + 显存 + 控制寄存器
// ----------------------------------------------------------------------------
// 这是视频链的全部逻辑，故意不含 PLL 和 OSERDES —— 它们（pll_video /
// GTP_*）是 PDS 专有原语，iverilog 里不存在。video_top 只是给本模块套上
// pll_video 和 rgb2tmds 的一层壳，所以 sim/tb_video_core.v 能直接例化本模块，
// 把"显存怎么被写、PPU 怎么读、读回值对不对"整条通路逐像素验证掉。
//
//   pix_clk 域（25.5MHz）：sync_vg → ppu → rgb/de/hs/vs（已寄存、负极性）
//   显存三块真双口 BRAM：A 口 clk_sys（CPU 写/读回），B 口 pix_clk（PPU 扫）
//   scroll_x/scroll_y：clk_sys 域写，两级同步进 pix_clk
//
// 为什么 tile 而不是线性 framebuffer，见 ppu.v 文件头。
// 软件怎么写显存 / 寄存器，见 rtl/bus/addr_map.vh 的视频区小节。
//
// [!] 两个时钟域的分工与不变量
//   * 显存必须真双口：分频比 13.5:45 无整数拍对齐关系，跨域不握手、不留 FIFO。
//   * CPU 口必须遵守 mem_bus 的 1 拍读契约：写通路零寄存器（组合打进 BRAM A
//     口），读数据由 BRAM A 口自己寄存 —— 与 unified_mem 的 B 口同规格。
//   * scroll 是准静态量（软件一帧改一次），两级同步足够。多比特同时变理论上
//     可能采到中间值，代价是某一帧滚动位置错一下、下一帧自动正 —— 对背景滚动
//     可接受，也是 ppu.v 头部"按准静态处理"那句话的含义。
//
// [!] 读回选择线为什么要 vid_vsel_d / vid_waddr_d
//   BRAM A 口在 MEM 拍收地址、WB 拍出数据，所以"选哪块显存 / 选哪个寄存器"
//   这两根线必须与地址一起在 MEM→WB 沿寄存（由 mem_bus 做，与 rsel_d 同族）。
//   本模块收到的是已经延迟好的 vid_vsel_d / vid_waddr_d，只做纯组合选择，
//   不再寄拍 —— 再寄一拍读数据就被推到 T+2，core 在 T+1 采样，直接读错。
// ============================================================================
module video_core (
    // ---- 两个时钟域 ----
    input  wire        pix_clk,     // 25.5MHz（= 1147.5MHz VCO / 45）
    input  wire        vid_resetn,  // pix 域复位，低有效（PLL 锁定前必须为 0）
    input  wire        clk_sys,     // CPU 时钟（与 pix_clk 同 VCO，见 video_top.v）
    input  wire        sys_resetn,  // clk_sys 域复位，低有效

    // ---- 显存 / 寄存器 CPU 口（来自 mem_bus 的译码结果）----
    input  wire        vid_we,      // 写使能（子窗口由 vid_vsel 选）
    input  wire [1:0]  vid_vsel,    // 0=nametable 1=pattern 2=palette 3=寄存器
    input  wire [13:0] vid_waddr,   // 区域相对字地址
    input  wire [3:0]  vid_be,      // 字节使能 = mem_byte_en
    input  wire [31:0] vid_wdata,
    input  wire [1:0]  vid_vsel_d,  // 与读数据同拍的两根选择线
    input  wire [13:0] vid_waddr_d,
    output wire [31:0] vid_rdata,

    // ---- 像素输出（已寄存、负极性，可直接喂 rgb2tmds）----
    output wire [23:0] rgb,
    output wire        de,
    output wire        hs,
    output wire        vs
);

    // ==================================================================
    // 先声明所有模块间连线
    // ==================================================================
    wire [12:0] nt_addr;    wire [7:0]  nt_byte;    // PPU → nametable
    wire [15:0] pat_addr;   wire [7:0]  pat_byte;   // PPU → pattern
    wire [7:0]  pal_addr;   wire [23:0] pal_rgb;    // PPU → palette
    wire [31:0] nt_q, pat_q, pal_q;                 // CPU 侧读回

    wire [11:0] x_act, y_act;
    wire        de_ph, hs_ph, vs_ph;

    // ==================================================================
    // 显存：三块真双口 BRAM
    //   A 口 CPU  clk_sys  32bit 读 + 字节使能写（一次 sb/sh/sw 一拍完成）
    //   B 口 PPU  pix_clk  字节地址进、字节数据出
    // 为什么要 32 位字而不是 8 位，见 vram_b32.v 文件头。
    // ==================================================================
    wire nt_we  = vid_we && (vid_vsel == 2'd0);
    wire pat_we = vid_we && (vid_vsel == 2'd1);
    wire pal_we = vid_we && (vid_vsel == 2'd2);
    wire reg_we = vid_we && (vid_vsel == 2'd3);

    vram_b32 #(.AW(13)) u_nt (               // 8KB：2048 字 = 8192 个 tile 号
        .wclk   (clk_sys),
        .we     (nt_we),
        .waddr  (vid_waddr[10:0]),
        .wbe    (vid_be),
        .wdata  (vid_wdata),
        .w_rdata(nt_q),
        .rclk   (pix_clk),
        .raddr  (nt_addr),
        .rdata  (nt_byte)
    );

    vram_b32 #(.AW(16)) u_pat (              // 64KB：16384 字 = 65536 个像素
        .wclk   (clk_sys),
        .we     (pat_we),
        .waddr  (vid_waddr[13:0]),
        .wbe    (vid_be),
        .wdata  (vid_wdata),
        .w_rdata(pat_q),
        .rclk   (pix_clk),
        .raddr  (pat_addr),
        .rdata  (pat_byte)
    );

    vram_pal u_pal (                         // 1KB：256 项 × 24bit
        .wclk   (clk_sys),
        .we     (pal_we),
        .waddr  (vid_waddr[7:0]),
        .wbe    (vid_be),
        .wdata  (vid_wdata),
        .w_rdata(pal_q),
        .rclk   (pix_clk),
        .raddr  (pal_addr),
        .rdata  (pal_rgb)
    );

    // ==================================================================
    // 控制寄存器（clk_sys 域）
    //   只接受整字写 sw —— 滚动值没有"半字有效"的语义，sb/sh 带来的部分字节
    //   更新只会产生难以复现的错位（与 mtimecmp 同一理由）。
    // ==================================================================
    reg [11:0] scroll_x, scroll_y;

    always @(posedge clk_sys or negedge sys_resetn) begin
        if (!sys_resetn) begin
            scroll_x <= 12'd0;
            scroll_y <= 12'd0;
        end else if (reg_we && (vid_be == 4'b1111)) begin
            case (vid_waddr[1:0])
                2'd0:    scroll_x <= vid_wdata[11:0];
                2'd1:    scroll_y <= vid_wdata[11:0];
                default: ;          // 2 = 状态寄存器，只读
            endcase
        end
    end

    // vblank 状态位：直接拿 sync_vg 的 vs_ph（行/帧起始正脉冲，宽 V_SYNC = 2 行）。
    //   2 行 = 2×800 = 1600 个 pixelclk = 62.7us ≈ CPU 侧 3100 拍。软件在这个
    //   窗口里改 scroll_x/scroll_y，改动就落在帧消隐期 —— 否则一帧扫到一半时
    //   换世界坐标，上半屏和下半屏会来自世界里的不同位置（撕裂）。
    //   62.7us 看着窄，但"改 scroll + 补几块 tile 号"只要几十拍。
    //   要更宽的窗口（整个 33 行后肩 ≈ 1.04ms）再加行计数，现在不必要。
    reg vs_meta, vblank_s;

    always @(posedge clk_sys or negedge sys_resetn) begin
        if (!sys_resetn) begin
            vs_meta  <= 1'b0;
            vblank_s <= 1'b0;
        end else begin
            vs_meta  <= vs_ph;
            vblank_s <= vs_meta;
        end
    end

    // 寄存器读回：vid_waddr_d 由 mem_bus 与 rsel_d 同拍寄存，所以这里纯组合按
    // 字偏移选（三个值本身都是稳定寄存器）。
    wire [31:0] reg_q =
        (vid_waddr_d[1:0] == 2'd0) ? {20'd0, scroll_x} :
        (vid_waddr_d[1:0] == 2'd1) ? {20'd0, scroll_y} :
        (vid_waddr_d[1:0] == 2'd2) ? {31'd0, vblank_s} : 32'd0;

    // 读回总选择（纯组合，选择线已延迟好，见文件头）
    assign vid_rdata = (vid_vsel_d == 2'd1) ? pat_q :
                       (vid_vsel_d == 2'd2) ? pal_q :
                       (vid_vsel_d == 2'd3) ? reg_q : nt_q;

    // ==================================================================
    // scroll 从 clk_sys 同步到 pix_clk（准静态，两级即可，见文件头）
    // ==================================================================
    reg [11:0] sx_meta, sy_meta;
    reg [11:0] scroll_x_p, scroll_y_p;

    always @(posedge pix_clk or negedge vid_resetn) begin
        if (!vid_resetn) begin
            sx_meta    <= 12'd0;
            sy_meta    <= 12'd0;
            scroll_x_p <= 12'd0;
            scroll_y_p <= 12'd0;
        end else begin
            sx_meta    <= scroll_x;
            sy_meta    <= scroll_y;
            scroll_x_p <= sx_meta;
            scroll_y_p <= sy_meta;
        end
    end

    // ==================================================================
    // 时序发生器 + 像素引擎
    // 参数与 colorbar_gen.v 里的完全一致（那里已被 tb_video.v 验证过）
    // ==================================================================
    // [!] 刷新率校准：像素时钟 25.5MHz（不是 VESA 的 25.175，见 video_top.v），
    //   行总周期用 800 时刷新率为 60.71Hz，偏出标准档、过缩放器会抖动/撕裂。
    //   修法：有效像素不动，行前肩 16→26、行总周期 800→810，
    //   25.5e6 / (810 × 525) = 59.97Hz，落回标准档。
    localparam H_TOTAL = 810, H_SYNC = 96, H_BP = 48, H_FP = 26;
    // 校验：640(有效) + 26(前肩) + 96(同步) + 48(后肩) = 810 [OK]
    localparam V_TOTAL = 525, V_SYNC =  2, V_BP = 33, V_FP = 10;

    sync_vg #(
        .X_BITS (12), .Y_BITS (12),
        .H_TOTAL(H_TOTAL), .H_SYNC(H_SYNC), .H_BP(H_BP), .H_FP(H_FP), .H_ACT(640),
        .V_TOTAL(V_TOTAL), .V_SYNC(V_SYNC), .V_BP(V_BP), .V_FP(V_FP), .V_ACT(480)
    ) u_timing (
        .clk    (pix_clk),
        .rstn   (vid_resetn),
        .vs_out (vs_ph),
        .hs_out (hs_ph),
        .de_out (de_ph),
        .de_re  (),            // 行提前启动使能，本设计用不到
        .x_act  (x_act),
        .y_act  (y_act)
    );

    ppu u_ppu (
        .pix_clk (pix_clk),
        .rstn    (vid_resetn),
        .x_act   (x_act),
        .y_act   (y_act),
        .de_ph   (de_ph),
        .hs_ph   (hs_ph),
        .vs_ph   (vs_ph),
        .scroll_x(scroll_x_p),
        .scroll_y(scroll_y_p),
        .nt_addr (nt_addr),
        .nt_rdata(nt_byte),
        .pat_addr(pat_addr),
        .pat_rdata(pat_byte),
        .pal_addr(pal_addr),
        .pal_rdata(pal_rgb),
        .rgb     (rgb),
        .de      (de),
        .hs      (hs),
        .vs      (vs)
    );

endmodule
