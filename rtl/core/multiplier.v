`timescale 1ns/1ps
// ============================================================================
// multiplier —— II=1 流水线乘法器（latency 2）
//
// 结构：第 0 级锁存操作数，第 1 级寄存选中的乘积；result 在 start 后第 2 拍有效，
//       每拍可接收新乘法（II=1，busy 恒 0）。
//
// 为什么做成流水线：此前的阻塞式乘法器每条 mul 占用 EX 两拍，CoreMark 每迭代
// 约 9,400 条 mul，折合约 3.9% 的周期数。流水化后只有紧邻消费结果的那一小部分
// 指令需要停顿一拍（core.v 的 stall 中有对应的 mul 项，判据与 load-use 同构），
// 净收益约 9,300 拍/迭代。实测数据见 doc/reports/ 的 A1 报告，此处不重复维护。
//
// 时序：操作数寄存器到结果寄存器的路径（APM 链 + 符号修正 + 4 选 1）与阻塞版
// 完全一致，只是终点寄存器换名，关键路径不变长。
//
// [!] en 必须与 core 的流水线寄存器同源（接 mem_ready_int）：core 冻结时若本
//     模块继续前进，q_res 会与 WB 级的 is_mul 标志错位，写回别的 mul 的结果。
//     该错位只在停顿密集的配置下出现（如 +MEMWAIT=3），回归必须覆盖。
// ============================================================================
module multiplier (
    input  wire        clk,
    input  wire        resetn,
    input  wire        en,          // 流水线使能，与 EX/MEM、MEM/WB 寄存器同源
    input  wire        start,       // 电平有效：en=1 期间每拍可接收一条（II=1）
    input  wire [31:0] a,           // 已前递的操作数 1
    input  wire [31:0] b,           // 已前递的操作数 2
    input  wire [1:0]  op,          // 0=MUL 1=MULH 2=MULHSU 3=MULHU
    output wire [31:0] result,      // start 后第 2 拍有效
    output wire        busy,        // II=1 恒 0，仅为端口兼容保留
    output wire        done         // result 有效标志
);
    // 第 0 级：操作数与有效位
    reg [31:0] r_a, r_b;
    reg [1:0]  r_op;
    reg        v0;
    // 第 1 级：选中后的乘积与有效位
    reg [31:0] q_res;
    reg        v1;

    assign busy   = 1'b0;
    assign done   = v1;
    assign result = q_res;

    // 32x32 无符号乘法 + 符号修正，与 alu.v 为同一套推导：
    // 三种符号组合的低 32 位相同（乘积模 2^32 与符号无关）；
    // 高 32 位只需减去带 <<32 的修正项，不会向位 31 借位。
    wire [63:0] pu     = {32'd0, r_a} * {32'd0, r_b};
    wire [31:0] corr_a = r_a[31] ? r_b : 32'd0;
    wire [31:0] corr_b = r_b[31] ? r_a : 32'd0;
    wire [31:0] hi_ss  = pu[63:32] - corr_a - corr_b;   // MUL/MULH 的高半
    wire [31:0] hi_su  = pu[63:32] - corr_a;            // MULHSU 的高半

    wire [31:0] sel = (r_op == 2'd0) ? pu[31:0]  :      // MUL
                      (r_op == 2'd1) ? hi_ss     :      // MULH
                      (r_op == 2'd2) ? hi_su     :      // MULHSU
                                       pu[63:32];       // MULHU

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            r_a   <= 32'd0;
            r_b   <= 32'd0;
            r_op  <= 2'd0;
            v0    <= 1'b0;
            q_res <= 32'd0;
            v1    <= 1'b0;
        end else if (en) begin
            // 第 0 级：每拍接收（II=1）
            v0 <= start;
            if (start) begin
                r_a  <= a;
                r_b  <= b;
                r_op <= op;
            end
            // 第 1 级：结果打一拍，start 后第 2 拍出现在 result 上
            q_res <= sel;
            v1    <= v0;
        end
        // en=0 时整体保持：与 core 的冻结行为对齐，原因见文件头
    end
endmodule
