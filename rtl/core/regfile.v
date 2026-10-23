`timescale 1ns/1ps
// ============================================================================
// regfile —— 通用寄存器堆 · 4 读 2 写（双发射）
// ----------------------------------------------------------------------------
// 写口 A = 较老的 lane（slot A），写口 B = 较年轻的 lane（slot B）。
// 同一拍两口写同一个 rd 时 B 赢（程序序更年轻者生效）—— 靠非阻塞赋值
// "后写覆盖前写" 实现，所以两个 if 的先后顺序不能颠倒。
//
// 每个读口一个 3:1 旁路（write-first，与单发射版语义一致）：
//     rs == 0            → 0
//     we_b && rd_b == rs → wd_b     （最年轻，最高优先级）
//     we_a && rd_a == rs → wd_a
//     否则                → rf[rs]
//
// [DUAL_ISSUE=0] core 把 we_b 恒 0、且不消费 rdata*_b。综合会把这些端口连同
//   第二个写译码器一起裁掉，结果等价于原来的 2 读 1 写版本。
// ============================================================================
module regfile (
    input  wire        clk,
    input  wire        resetn,

    // ---- 写口 A（lane A，较老）----
    input  wire        we_a,
    input  wire [4:0]  rd_a,
    input  wire [31:0] wd_a,

    // ---- 写口 B（lane B，较年轻）----
    input  wire        we_b,
    input  wire [4:0]  rd_b,
    input  wire [31:0] wd_b,

    // ---- 读口 1：lane A 的 rs1 ----
    input  wire [4:0]  rs1_a,
    output wire [31:0] rdata1_a,
    // ---- 读口 2：lane A 的 rs2 ----
    input  wire [4:0]  rs2_a,
    output wire [31:0] rdata2_a,
    // ---- 读口 3：lane B 的 rs1 ----
    input  wire [4:0]  rs1_b,
    output wire [31:0] rdata1_b,
    // ---- 读口 4：lane B 的 rs2 ----
    input  wire [4:0]  rs2_b,
    output wire [31:0] rdata2_b
);
    reg [31:0] rf [0:31];
    integer i;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            for (i = 0; i < 32; i = i + 1) rf[i] <= 32'd0;
        end else begin
            if (we_a && (rd_a != 5'd0)) rf[rd_a] <= wd_a;
            if (we_b && (rd_b != 5'd0)) rf[rd_b] <= wd_b;   // B 后写 ⇒ 同址时 B 赢
        end
    end

    // write-first：同拍 WB 写对 ID 读可见。B 比 A 年轻，旁路优先级更高。
    assign rdata1_a = (rs1_a == 5'd0) ? 32'd0 :
                      (we_b && (rd_b == rs1_a)) ? wd_b :
                      (we_a && (rd_a == rs1_a)) ? wd_a : rf[rs1_a];
    assign rdata2_a = (rs2_a == 5'd0) ? 32'd0 :
                      (we_b && (rd_b == rs2_a)) ? wd_b :
                      (we_a && (rd_a == rs2_a)) ? wd_a : rf[rs2_a];
    assign rdata1_b = (rs1_b == 5'd0) ? 32'd0 :
                      (we_b && (rd_b == rs1_b)) ? wd_b :
                      (we_a && (rd_a == rs1_b)) ? wd_a : rf[rs1_b];
    assign rdata2_b = (rs2_b == 5'd0) ? 32'd0 :
                      (we_b && (rd_b == rs2_b)) ? wd_b :
                      (we_a && (rd_a == rs2_b)) ? wd_a : rf[rs2_b];
endmodule
