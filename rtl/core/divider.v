`timescale 1ns/1ps
// 多拍迭代除法器：恢复余数法，32 位无符号除法 + 符号-绝对值 + 边界处理。
// 每拍只做一次「移位 + 32 位比较/减法」，关键路径 ~一个减法器，远短于单拍组合除法。
// 支持 DIV/DIVU/REM/REMU，由 is_signed / is_rem 两个控制位区分。
module divider (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,       // 电平：idle 且 start=1 时锁存操作数开始
    input  wire [31:0] a,           // 被除数 / 被取余数（原始，含符号）
    input  wire [31:0] b,           // 除数（原始，含符号）
    input  wire        is_signed,   // 1 = 有符号 (DIV/REM)，0 = 无符号 (DIVU/REMU)
    input  wire        is_rem,      // 1 = 取余 (REM/REMU)，0 = 除 (DIV/DIVU)
    output wire [31:0] result,      // 组合输出，done 为 1 时有效
    output wire        busy,
    output wire        done
);
    reg [31:0] r_rem;       // 迭代余数 A
    reg [31:0] r_quot;      // 迭代商 Q（初始 = |被除数|，结束后 = 商）
    reg [31:0] r_divisor;   // |除数|
    reg [5:0]  r_cnt;       // 0..32，32 = 完成
    reg        r_signed;
    reg        r_rem_op;
    reg [31:0] r_a, r_b;    // 原始操作数（用于符号/边界）
    reg        r_busy;

    assign busy = r_busy;
    assign done = r_busy && (r_cnt == 6'd32);

    // 迭代一步：余数左移、移入商最高位；若 >= 除数则减去除数并商置 1
    wire [31:0] next_rem = {r_rem[30:0], r_quot[31]};
    wire        ge       = (next_rem >= r_divisor);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            r_busy    <= 1'b0;
            r_cnt     <= 6'd0;
            r_rem     <= 32'd0;
            r_quot    <= 32'd0;
            r_divisor <= 32'd0;
            r_signed  <= 1'b0;
            r_rem_op  <= 1'b0;
            r_a       <= 32'd0;
            r_b       <= 32'd0;
        end else if (!r_busy && start) begin
            r_busy    <= 1'b1;
            r_cnt     <= 6'd0;
            r_rem     <= 32'd0;
            // 有符号：取绝对值做无符号除法，再按符号回正；无符号：直接用原始值
            r_quot    <= is_signed ? (a[31] ? (~a + 1'b1) : a) : a;
            r_divisor <= is_signed ? (b[31] ? (~b + 1'b1) : b) : b;
            r_signed  <= is_signed;
            r_rem_op  <= is_rem;
            r_a       <= a;
            r_b       <= b;
        end else if (r_busy) begin
            if (r_cnt == 6'd32) begin
                r_busy <= 1'b0;
            end else begin
                if (ge) begin
                    r_rem  <= next_rem - r_divisor;
                    r_quot <= (r_quot << 1) | 1'b1;
                end else begin
                    r_rem  <= next_rem;
                    r_quot <= r_quot << 1;
                end
                r_cnt <= r_cnt + 1'b1;
            end
        end
    end

    // 符号修正 + 除 0 / INT_MIN/-1 溢出边界
    wire        a_neg      = r_a[31];
    wire        b_neg      = r_b[31];
    wire        div_neg    = a_neg ^ b_neg;
    wire [31:0] q_signed   = div_neg ? (~r_quot + 1'b1) : r_quot;
    wire [31:0] rem_signed = a_neg  ? (~r_rem + 1'b1)  : r_rem;

    wire div_by_zero  = (r_b == 32'd0);
    wire div_overflow = (r_a == 32'h80000000) && (r_b == 32'hFFFFFFFF);

    wire [31:0] div_result =
        r_signed ? (div_by_zero  ? 32'hFFFFFFFF :
                    div_overflow ? 32'h80000000 :
                    q_signed)
                 : (div_by_zero ? 32'hFFFFFFFF : r_quot);

    wire [31:0] rem_result =
        r_signed ? (div_by_zero  ? r_a :
                    div_overflow ? 32'd0 :
                    rem_signed)
                 : (div_by_zero ? r_a : r_rem);

    assign result = r_rem_op ? rem_result : div_result;

endmodule
