`timescale 1ns/1ps
// ============================================================================
// colorbar_gen —— 480p60 测试图案发生器（纯逻辑，可仿真）
// ----------------------------------------------------------------------------
// 输入像素时钟，输出已寄存的 RGB + de/hs/vs（可直接喂 rgb2tmds / tmds_encoder，
// 它们都要求输入已寄存）。
//
// 这里刻意把"时序 + 图案"独立成一个模块，不掺 PLL 和 OSERDES：
//   * 前者能进 iverilog（GTP_* 原语不能）→ 参数/极性/图案都能功能仿真，
//     见 sim/tb_video.v；
//   * 后续要做 tile 背景，只要把下面的彩条逻辑换成"从显存取像素"，
//     video_top 那一层不用动。
//
// 为什么所有输出都在同一个 always 块里寄存：
//   x_act/y_act 与 de/hs/vs 都是 sync_vg 同一级的输出，天然同拍；
//   再一起打一拍，是为了满足 tmds_encoder 的 "din expect registered"。
//   分开打拍会引入 1 像素的错位，画面右边缘会出现一条竖线。
//
// 同步极性：640×480@60 的 VESA DMT 标准是 HS/VS 负极性，sync_vg 给的是
//   正脉冲（脉冲落在行/帧起始）。取反后 "同步→后肩→有效区→前肩" 的结构与
//   DMT 完全一致，无需移动脉冲位置。
// ============================================================================
module colorbar_gen (
    input  wire        pix_clk,   // 25.5MHz
    input  wire        rstn,      // 低有效

    output reg  [23:0] rgb,       // 已寄存
    output reg         de,        // 数据有效（已寄存）
    output reg         hs,        // 行同步，负极性（已寄存）
    output reg         vs         // 帧同步，负极性（已寄存）
);

    parameter H_TOTAL = 800, H_SYNC = 96, H_BP = 48, H_FP = 16, H_ACT = 640;
    parameter V_TOTAL = 525, V_SYNC =  2, V_BP = 33, V_FP = 10, V_ACT = 480;

    // ------------------------------------------------------------------
    // 时序发生器（例化 sync_vg，只改参数）
    // ------------------------------------------------------------------
    wire [11:0] x_act, y_act;
    wire        de_ph, hs_ph, vs_ph;

    sync_vg #(
        .X_BITS (12),
        .Y_BITS (12),
        .H_TOTAL(H_TOTAL), .H_SYNC(H_SYNC), .H_BP(H_BP), .H_FP(H_FP), .H_ACT(H_ACT),
        .V_TOTAL(V_TOTAL), .V_SYNC(V_SYNC), .V_BP(V_BP), .V_FP(V_FP), .V_ACT(V_ACT)
    ) u_timing (
        .clk    (pix_clk),
        .rstn   (rstn),
        .vs_out (vs_ph),
        .hs_out (hs_ph),
        .de_out (de_ph),
        .de_re  (),            // 后端显存读使能，本阶段不用
        .x_act  (x_act),
        .y_act  (y_act)
    );

    // ------------------------------------------------------------------
    // 8 条 75% 彩条，每条 H_ACT/8 = 80 像素
    // ------------------------------------------------------------------
    wire [2:0] bar =
        (x_act <  80) ? 3'd0 :
        (x_act < 160) ? 3'd1 :
        (x_act < 240) ? 3'd2 :
        (x_act < 320) ? 3'd3 :
        (x_act < 400) ? 3'd4 :
        (x_act < 480) ? 3'd5 :
        (x_act < 560) ? 3'd6 : 3'd7;

    reg [23:0] bar_rgb;
    always @(*) begin
        case (bar)
            3'd0:    bar_rgb = 24'hC0C0C0;   // 白
            3'd1:    bar_rgb = 24'hC0C000;   // 黄
            3'd2:    bar_rgb = 24'h00C0C0;   // 青
            3'd3:    bar_rgb = 24'h00C000;   // 绿
            3'd4:    bar_rgb = 24'hC000C0;   // 品红
            3'd5:    bar_rgb = 24'hC00000;   // 红
            3'd6:    bar_rgb = 24'h0000C0;   // 蓝
            default: bar_rgb = 24'h000000;   // 黑
        endcase
    end

    // 有效区外圈 2 像素白边框 —— 用来确认画面居中、没有被裁掉
    wire border = (x_act < 12'd2) || (x_act >= H_ACT - 2) ||
                  (y_act < 12'd2) || (y_act >= V_ACT - 2);

    wire [23:0] rgb_c = border ? 24'hFFFFFF : bar_rgb;

    // ------------------------------------------------------------------
    // 统一打一拍（见文件头说明）
    // ------------------------------------------------------------------
    always @(posedge pix_clk) begin
        rgb <= rstn ? rgb_c         : 24'd0;
        de  <= rstn ? de_ph         : 1'b0;
        hs  <= rstn ? ~hs_ph        : 1'b0;   // 负极性
        vs  <= rstn ? ~vs_ph        : 1'b0;   // 负极性
    end

endmodule
