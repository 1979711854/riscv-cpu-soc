`timescale 1ns/1ps
// ============================================================================
// gpio —— 8 位 LED 输出 + 8 位按键输入
// ----------------------------------------------------------------------------
// 映射（地址译码在 mem_bus，本模块只认已译好的写选通）：
//   0x8000_0000  W  led[7:0]      R  {16'b0, key[7:0], led[7:0]}
//
// 关于按键去抖：本模块只做 2 级同步，不做硬件消抖。
//   机械按键抖动在 ms 量级，而轮询程序读到抖动最多是"多打印几行"；
//   真正需要消抖时放在软件里更合适（采样—延时—再采样），也便于仿真验证。
//   硬件消抖会让 tb 必须把按键按住几十个周期，得不偿失。
// ============================================================================
module gpio (
    input  wire        clk,
    input  wire        resetn,

    // ---- 总线侧（地址已由 mem_bus 译好）----
    input  wire        we,
    input  wire [31:0] wdata,      // 已按 sb/sh/sw 做过字节复制
    output wire [31:0] rdata,

    // ---- 引脚 ----
    output wire [7:0]  led,
    input  wire [7:0]  key         // 按键低电平有效：按下 = 0，松开 = 1
);
    // ---- LED 输出寄存器 ----
    reg [7:0] led_r;
    assign led = led_r;

    always @(posedge clk or negedge resetn) begin
        if (!resetn)     led_r <= 8'd0;
        else if (we)     led_r <= wdata[7:0];
    end

    // ---- 按键输入同步（跨时钟域 + 防亚稳态）----
    reg [7:0] key_s1, key_s2;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            key_s1 <= 8'hFF;
            key_s2 <= 8'hFF;
        end else begin
            key_s1 <= key;
            key_s2 <= key_s1;
        end
    end

    // 读回：key 是原始电平（低有效，按下为 0），软件需要时自行取反。
    // 同时回读 led 便于软件确认自己写进去的值。
    assign rdata = {16'd0, key_s2, led_r};

endmodule
