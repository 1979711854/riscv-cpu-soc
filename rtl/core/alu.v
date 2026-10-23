`timescale 1ns/1ps
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  alu_op,
    output reg  [31:0] result
);
    // ---- M 扩展：本模块不做乘法，也不做除法 ----
    //
    // [!] alu_op 10..13（MUL/MULH/MULHSU/MULHU）由 core.v 的
    //   rtl/core/multiplier.v 两拍乘法器接管；14..17（DIV/…）由 divider.v 接管。
    //   两者都在 core.v 里通过 `alu_result` 的 mux 覆盖本模块的输出，所以
    //   下面 case 里 10..17 给的是无关项，永远不会被采到。
    //
    //   为什么必须彻底移出而不是"留着但不用"：
    //     * 单拍组合乘法的关键路径实测 10.05 ns —— 它和 BRAM 读出、装载解包、
    //       前递 mux 串在同一条路径上（"lw 紧跟 mul"），占整条数据通路的 56%；
    //     * 32 位单拍组合除法会形成 ~32 级连减，更不可能收敛。
    //   把乘法器摘到独立的两拍单元后，那 10 ns 就从关键路径上消失了。
    //   代价是每条 mul 多 1 拍。CoreMark 每迭代实测 9,396 条 mul
    //   （区间周期 354,119 → 363,515，+2.65%）—— 条数必须以 +PROF 的 c_mul 为准，
    //   静态推算会小 5.8 倍，原因见 rtl/core/multiplier.v 头注释。
    //
    //   [!] 若在这里"顺手保留"一份乘法逻辑，综合会多出一个永远不会被选中
    //       的乘法器（约 4 个 APM + 上千 LUT），既浪费资源又可能被工具当成
    //       真路径去优化，报告会变得难以解读。所以这里是零乘法。

    always @(*) begin
        case (alu_op)
            4'd0  : result = a + b;
            4'd1  : result = a - b;
            4'd2  : result = a << b[4:0];
            4'd3  : result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            4'd4  : result = (a < b) ? 32'd1 : 32'd0;
            4'd5  : result = a ^ b;
            4'd6  : result = a >> b[4:0];
            4'd7  : result = $signed(a) >>> b[4:0];
            4'd8  : result = a | b;
            4'd9  : result = a & b;
            // M 扩展（乘法/除法）：由外部的多拍单元接管，本模块输出无关项。
            // 见文件上方说明 —— 这里必须是零逻辑，不能保留乘法器副本。
            5'd10, 5'd11, 5'd12, 5'd13 : result = 32'd0;   // MUL/MULH/MULHSU/MULHU
            5'd14, 5'd15, 5'd16, 5'd17 : result = 32'd0;   // DIV/DIVU/REM/REMU
            default : result = a + b;
        endcase
    end
endmodule
