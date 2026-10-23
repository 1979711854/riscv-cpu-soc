`timescale 1ns/1ps
// ============================================================================
// vram_pal —— 调色板：256 项 × 24bit，一项占一个 32 位字
// ----------------------------------------------------------------------------
// 与 vram_b32 同一套端口约定（CPU 32 位字节使能写 + 整字读，PPU 1 拍读），
// 只是 PPU 侧读的是整项而不是字节：
//
//   * 索引 0..255 直接就是 A 口的字地址（一项一字），所以 CPU 用 sw 写
//     地址 = VIDEO_PAL + index*4，低 24 位是 RGB，高 8 位忽略。
//   * PPU 侧 raddr = ppu.v 的 pal_addr（8 位索引），rdata 24 位，1 拍延迟 ——
//     正好对上 ppu.v 的 E5（组合给地址）→ E6（寄存 RGB）。
//
// 为什么还留字节使能：sb 写一项的低字节也该能改（画渐变/闪烁调色板时有用），
// 成本只是 4 个写使能分支，不额外占资源。
// ============================================================================
module vram_pal (
    // ---- A 口：CPU（clk_sys）----
    input  wire        wclk,
    input  wire        we,
    input  wire [7:0]  waddr,       // 字地址 = 调色板索引
    input  wire [3:0]  wbe,
    input  wire [31:0] wdata,
    output reg  [31:0] w_rdata,

    // ---- B 口：PPU（pix_clk）----
    input  wire        rclk,
    input  wire [7:0]  raddr,       // 调色板索引
    output reg  [23:0] rdata
);

    (* syn_ramstyle = "block_ram" *) reg [31:0] mem [0:255];

    always @(posedge wclk) begin
        w_rdata <= mem[waddr];
        if (we) begin
            if (wbe[0]) mem[waddr][ 7: 0] <= wdata[ 7: 0];
            if (wbe[1]) mem[waddr][15: 8] <= wdata[15: 8];
            if (wbe[2]) mem[waddr][23:16] <= wdata[23:16];
            if (wbe[3]) mem[waddr][31:24] <= wdata[31:24];
        end
    end

    always @(posedge rclk) rdata <= mem[raddr][23:0];

endmodule
