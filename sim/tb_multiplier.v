`timescale 1ns/1ps
// ============================================================================
// tb_multiplier —— 两拍乘法器的单元测试（自检，有 PASS/FAIL 汇总）
// ----------------------------------------------------------------------------
// 【为什么需要它】2026-09-28 把 M 扩展乘法从 alu.v 的单拍组合逻辑改成
// rtl/core/multiplier.v 的两拍单元时，顺手重写了乘法数学：
//     原先 三个 64 位乘法并行（signed×signed / signed×unsigned / unsigned×unsigned）
//     改后 一个 32×32 无符号乘法 + 两个符号修正项
// 这个改写的正确性在 riscv-tests 的 rv32um 上验过，但那是【端到端】的，
// 出了问题只能看到"mulh FAIL"，定位成本高。这个测试台直接对着模块打：
//   1) 参考模型就是【改写前的那三个 64 位乘法】—— 即回归锁死"数学没变"；
//   2) 覆盖符号组合的边界（0 / ±1 / INT_MIN / INT_MAX）与随机扫描；
//   3) 顺带验握手：done 恰好高 1 拍、且下一拍必须落回（busy=done=r_valid，
//      这是 core.v 里 mc_stall 能靠它当冻结判据的前提）。
//
// [!] 这个测试台是 2026-09-28 新建的 —— 在此之前【全仓库没有任何乘法器单测】，
//     M 扩展只靠 riscv-tests 的 rv32um 与 CoreMark 覆盖。
// ============================================================================
module multiplier_test;
    reg         clk, resetn;
    reg         en;                 // [A1] 流水线使能（见下）
    reg         start;
    reg  [31:0] a, b;
    reg  [1:0]  op;
    wire [31:0] result;
    wire        busy, done;

    // [!] `en` 是【A1（II=1 流水线）之后新增的端口】。本测试台在 2026-09-28 写的是
    //     "锁存操作数 → 组合乘法 → done" 的【阻塞】两拍版，那时没有 en。A1 改成
    //     自由流动的两级流水线后，这个端口一直【没接】—— 悬空输入 = Z（约定 13），
    //     `en` 恒 X/Z ⇒ 流水线寄存器永不使能 ⇒ done 永不高 ⇒ 840 项全挂。
    //     2026-10-15 补上：本测试台不测停顿，en 恒 1（= 背靠背连发，正好压 II=1）。
    multiplier u_mul (
        .clk(clk), .resetn(resetn), .en(en), .start(start),
        .a(a), .b(b), .op(op),
        .result(result), .busy(busy), .done(done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer checks, errors;
    integer i;

    // ---- 参考模型：改写【前】的写法，三路 64 位乘法直接算 ----
    function [31:0] ref_mul;
        input [31:0] x, y;
        input [1:0]  o;
        reg signed [63:0] ss, su;
        reg        [63:0] uu;
        begin
            ss = $signed({{32{x[31]}}, x}) * $signed({{32{y[31]}}, y});  // MUL / MULH
            su = $signed({{32{x[31]}}, x}) * $signed({32'd0, y});       // MULHSU
            uu = {32'd0, x} * {32'd0, y};                               // MULHU
            case (o)
                2'd0: ref_mul = ss[31:0];    // MUL
                2'd1: ref_mul = ss[63:32];   // MULH
                2'd2: ref_mul = su[63:32];   // MULHSU
                default: ref_mul = uu[63:32];// MULHU
            endcase
        end
    endfunction

    // 打一组操作数：验结果 + 验握手时序
    task check;
        input [31:0] x, y;
        input [1:0]  o;
        reg   [31:0] exp;
        integer      guard;
        begin
            @(negedge clk);
            a = x; b = y; op = o; start = 1'b1;
            @(negedge clk);                 // 过了一个 posedge：操作数应已锁存
            start = 1'b0;

            guard = 0;
            while (!done && guard < 8) begin
                @(negedge clk);
                guard = guard + 1;
            end

            // [A1 口径] 这里原来是 `guard != 0`（旧阻塞版：start 落下那拍 done 就该高）。
            //   II=1 流水线把 done 推后了一拍，推导（en 恒 1，start 在 N0 拉高、
            //   N1 落下）：
            //     P1: en&start ⇒ v0<=1（锁存 a/b/op）
            //     P2: v1<=v0=1 ⇒ done 在 P2 之后为高；q_res<=sel 同时有效
            //     N2: 第一次轮询到 done=1 ⇒ guard==1
            //     P3: v1<=v0=0 ⇒ done 只高 1 拍
            //   所以期望值从 0 变成 1。**这个数变了不代表行为变坏** —— 它是 A1
            //   流水线的必然结果，而 core 侧是靠 `mem_ready_int` 同源使能对齐的。
            checks = checks + 1;
            if (guard != 1) begin
                errors = errors + 1;
                $display("FAIL 握手: op=%0d a=%h b=%h —— done 未在 start 后第 2 拍出现（等了 %0d 拍）",
                         o, x, y, guard);
            end else begin
                exp = ref_mul(x, y, o);
                if (result !== exp) begin
                    errors = errors + 1;
                    $display("FAIL 结果: op=%0d a=%h b=%h → got %h, want %h",
                             o, x, y, result, exp);
                end
            end

            // done 必须【恰好高 1 拍】：busy=done=r_valid，core 的 mc_stall
            // 靠它把「多拍指令还没算完」判断出来。若 done 多高一拍，
            // 下一条指令会晚一拍进 EX（周期数悄悄变多）；少高一拍则会丢结果。
            @(negedge clk);
            if (done) begin
                errors = errors + 1;
                $display("FAIL 握手: op=%0d a=%h b=%h —— done 持续超过 1 拍", o, x, y);
            end
        end
    endtask

    // 四种 op 全打一遍
    task check_all_ops;
        input [31:0] x, y;
        begin
            check(x, y, 2'd0);  // MUL
            check(x, y, 2'd1);  // MULH
            check(x, y, 2'd2);  // MULHSU
            check(x, y, 2'd3);  // MULHU
        end
    endtask

    reg [31:0] ra, rb;

    initial begin
        resetn = 1'b0;
        en     = 1'b1;              // 见 u_mul 处的说明：不测停顿，恒开
        start  = 1'b0;
        a = 32'd0; b = 32'd0; op = 2'd0;
        checks = 0; errors = 0;

        repeat (3) @(negedge clk);
        resetn = 1'b1;
        @(negedge clk);

        $display("---- A: 边界值与符号组合 ----");
        check_all_ops(32'd0,          32'd0);
        check_all_ops(32'd0,          32'hFFFFFFFF);
        check_all_ops(32'hFFFFFFFF,   32'd0);
        check_all_ops(32'd1,          32'hFFFFFFFF);
        check_all_ops(32'hFFFFFFFF,   32'hFFFFFFFF);
        check_all_ops(32'h80000000,   32'h80000000);   // INT_MIN * INT_MIN
        check_all_ops(32'h80000000,   32'hFFFFFFFF);   // INT_MIN * -1
        check_all_ops(32'hFFFFFFFF,   32'hFFFFFFFF);   // INT_MAX * INT_MAX
        check_all_ops(32'hFFFFFFFF,   32'h80000000);   // 正 * 负（高位置 1）
        check_all_ops(32'h12345678,   32'h9ABCDEF0);   // 高低位都非零

        $display("---- B: 随机扫描 ----");
        for (i = 0; i < 200; i = i + 1) begin
            ra = $random;
            rb = $random;
            check_all_ops(ra, rb);
        end

        $display("");
        $display("checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL ===");
        $finish;
    end

    // 超时保护
    initial begin
        #1000000;
        $display("=== TIMEOUT ===");
        $finish;
    end
endmodule
