`timescale 1ns/1ps
// ============================================================================
// vram_dp —— 视频显存：真双口 BRAM，两个端口各跑各的时钟
// ----------------------------------------------------------------------------
// CPU 与 PPU 之间的唯一交汇点：
//   A 口（CPU）：clk_sys 域，可读可写 —— mem_bus 的 1 拍读契约也走这里
//   B 口（PPU）：pix_clk 域，只读 —— 扫描输出
//
// 为什么必须是"两个独立时钟"的真双口，而不是同钟双口：
//   CPU 在 clk_sys 域、PPU 在 pix_clk 域，两个时钟同源但分频比无整数拍对齐
//   关系。用同一块 BRAM 的两个独立时钟口是唯一不需要握手/FIFO 就能跨过去的
//   办法；Pango 的 DRM 原生支持 TDP。
//
// [!] 综合后须核对 device_map 报告里的 DRM 数量：64KB pattern 应占 32 块；
//   若翻倍（64 块）说明被拆成两块单口 BRAM，需显式例化 DRM 原语或换写法。
//
// 同址同拍：读口读到旧值(read_first)，与 Pango DRM 默认一致，也与
//   unified_mem 的 B 口行为一致。画面撕裂在这里是允许的 —— CPU 改 tile 号
//   的那一刻，扫描线可能正好扫到那一行，下一帧就正了。
// ============================================================================
module vram_dp #(
    parameter AW = 13,      // 地址位宽 ⇒ 字数 = 2^AW
    parameter DW = 8        // 数据位宽
) (
    // ---- A 口：CPU（clk_sys），读 + 写 ----
    input  wire          wclk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    output reg  [DW-1:0] w_rdata,

    // ---- B 口：PPU（pix_clk），只读 ----
    input  wire          rclk,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);

    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    // A 口：同步读 + 写。读在前写在后 ⇒ 同址同拍读到旧值。
    always @(posedge wclk) begin
        w_rdata <= mem[waddr];
        if (we) mem[waddr] <= wdata;
    end

    // B 口：同步读
    always @(posedge rclk) begin
        rdata <= mem[raddr];
    end

endmodule
