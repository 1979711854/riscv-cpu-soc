`timescale 1ns/1ps
// ============================================================================
// vram_b32 —— 视频显存（nametable / pattern 用）：32 位字，字节使能写 + 字节读
// ----------------------------------------------------------------------------
// 为什么不是 vram_dp 那样的 8 位口：
//   CPU 的 sb/sh/sw 全都在一个 clk_sys 拍里提交，而 BRAM 写口一拍只能写一
//   个字。显存若是 8 位宽，一次 sw 只有 1 个字节落得下去，另外 3 个静默丢失 ——
//   不报错、不挂死，只是画出来少了一半像素，属于最难查的一类 bug。
//   所以 CPU 口做成 32 位 + 字节使能：sw 一次写 4 字节、sh 写 2 字节、sb 写 1
//   字节，全都 1 拍完成，且与统一存储器 B 口（unified_mem）语义一致。
//
// 两个端口，各自时钟（真双口；CPU 在 clk_sys 域、PPU 在 pix_clk 域，两个频率
// 无整数对齐关系，理由见 vram_dp.v 文件头）：
//
//   A 口 CPU ▸ clk_sys  32bit 读 + 字节使能写   满足 mem_bus 的 1 拍读契约
//   B 口 PPU ▸ pix_clk  字节地址进、字节数据出
//
// B 口的字节选择为什么不多花一拍（这决定了 ppu.v 的 LAT 还是不是 6）：
//   BRAM 的地址在第 N 拍给，数据在第 N+1 拍出。只要把字节选择位 raddr[1:0] 和
//   地址一起打进一级寄存器（bsel_d），它在第 N+1 拍就与 rword 同时就绪，
//   于是 rdata 是纯组合选择，整条路仍是"地址进→1 拍后数据出"，与 8 位的
//   vram_dp 完全同拍。若图省事把 rdata 再寄一拍，LAT 就变 7 而 ppu.v 的同步链
//   还是 6 —— 画面整体左移 1 像素、右边缘多一条竖带，且块内看不出来。
//
// 读优先写（read_first）：同址同拍读到旧值，与 vram_dp / unified_mem 一致。
//   这不影响"sb 之后立刻 lb"：那是相隔一整拍的两笔访问，CPU 在第 N 拍写、第
//   N+1 拍读，读口在 N+1→N+2 的沿上采到的已经是写之后的值。
//
// 本模块不含任何原语，可以整体进 iverilog（见 sim/tb_video_mem.v）。
// ============================================================================
module vram_b32 #(
    parameter AW = 13       // 字节地址位宽 ⇒ 容量 2^AW 字节 = 2^(AW-2) 个字
) (
    // ---- A 口：CPU（clk_sys）----
    input  wire          wclk,
    input  wire          we,
    input  wire [AW-3:0] waddr,      // 字地址
    input  wire [3:0]    wbe,        // 字节使能，来自 mem_byte_en
    input  wire [31:0]   wdata,
    output reg  [31:0]   w_rdata,

    // ---- B 口：PPU（pix_clk）----
    input  wire          rclk,
    input  wire [AW-1:0] raddr,      // 字节地址（ppu.v 给的本来就是字节地址）
    output wire [7:0]    rdata
);

    (* syn_ramstyle = "block_ram" *) reg [31:0] mem [0:(1 << (AW-2)) - 1];

    always @(posedge wclk) begin
        w_rdata <= mem[waddr];
        if (we) begin
            if (wbe[0]) mem[waddr][ 7: 0] <= wdata[ 7: 0];
            if (wbe[1]) mem[waddr][15: 8] <= wdata[15: 8];
            if (wbe[2]) mem[waddr][23:16] <= wdata[23:16];
            if (wbe[3]) mem[waddr][31:24] <= wdata[31:24];
        end
    end

    reg [1:0]  bsel_d;
    reg [31:0] rword;

    always @(posedge rclk) begin
        rword  <= mem[raddr[AW-1:2]];
        bsel_d <= raddr[1:0];
    end

    // 4:1 字节选择。写成 case 而不是 rword[8*bsel_d +: 8] —— 变量基址的位选
    // 各家综合器支持程度不一，这里要的是"绝不出意外"。
    assign rdata = (bsel_d == 2'd0) ? rword[ 7: 0] :
                   (bsel_d == 2'd1) ? rword[15: 8] :
                   (bsel_d == 2'd2) ? rword[23:16] : rword[31:24];

endmodule
