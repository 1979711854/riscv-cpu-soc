`timescale 1ns/1ps
// ============================================================================
// tb_video —— 480p 时序 / 图案 / TMDS 控制令牌 的功能仿真
// ----------------------------------------------------------------------------
// 只测**能被 iverilog 编译的部分**：colorbar_gen（纯逻辑）+ tmds_encoder。
// video_top 里含 pll_video / GTP_OSERDES_E2 / GTP_OUTBUFDS 原语（PDS 专有），
// 仿真里不存在 —— 所以这里直接例化 colorbar_gen，不例化 video_top。
//
// 测什么（每项对应一个真实会挂掉的风险）：
//   [1] 行/帧总长 800 / 525 —— 参数写错显示器就"无信号"
//   [2] de 有效区恰好 640×480，且 x_act/y_act 走满 0..639 / 0..479
//   [3] 同步极性为负（DMT），且 de 有效期间 hs/vs 都在"空闲高"电平
//   [4] 8 条彩条的颜色与边界 + 外圈 2 像素白边框
//   [5] tmds_encoder 在 de=0 时输出四个标准控制令牌
//
// 跑法（iverilog 装在 D:\iverilog，不在 PATH）：
//   cd sim
//   /d/iverilog/bin/iverilog.exe -g2012 -o /tmp/tb_video.vvp \
//       tb_video.v ../rtl/video/sync_vg.v ../rtl/video/colorbar_gen.v \
//       ../rtl/video/tmds_encoder.v
//   /d/iverilog/bin/vvp.exe /tmp/tb_video.vvp
//
// [重点] 采样对齐：colorbar_gen 的输出又打了一拍（为了喂 tmds_encoder），
//   所以在 negedge 采样时，rgb/de/hs/vs 对应的是**上一拍**的 x_act/y_act。
//   为此 TB 把 x_act/y_act 也延迟一拍（x_d1/y_d1）再跟 rgb 比 —— 不这么做
//   会整体错一位，右边缘多出一条竖线，看起来像 DUT bug。
// ============================================================================
module tb_video;

    reg clk  = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;      // 100MHz 仿真节拍；被测逻辑只看拍数，不看绝对周期

    integer errors = 0;

    localparam integer H_TOTAL = 800;
    localparam integer V_TOTAL = 525;
    localparam integer FRAME   = H_TOTAL * V_TOTAL;   // 420000

    // ==================================================================
    // [A] colorbar_gen：480p 时序 + 图案
    // ==================================================================
    wire [23:0] rgb;
    wire        de, hs, vs;

    colorbar_gen u_cb (
        .pix_clk(clk), .rstn(rstn),
        .rgb(rgb), .de(de), .hs(hs), .vs(vs)
    );

    // ------------------------------------------------------------------
    // [B] 的 DUT —— 必须在模块级例化（Verilog 不允许实例放进过程块）
    // ------------------------------------------------------------------
    reg  [7:0] din_e = 8'h00;
    reg        c0_e  = 1'b0;
    reg        c1_e  = 1'b0;
    reg        de_e  = 1'b0;
    wire [9:0] dout_e;

    tmds_encoder u_enc (
        .pix_clk(clk), .rstn(rstn),
        .din(din_e), .c0(c0_e), .c1(c1_e), .de(de_e), .dout(dout_e)
    );

    // ---- 观测变量 ----
    integer cyc, de_px, hs_low, vs_low, hs_rise, frame_cyc;
    integer bar_bad, border_bad;
    reg [11:0] min_x, max_x, min_y, max_y;   // [！] 必须无符号：用 integer(-1) 当
                                             //     上限会被零扩展成 0xFFFFFFFF，比较恒假
    reg [11:0] x_d1, y_d1;        // 延迟一拍的 x_act/y_act（见文件头对齐说明）
    reg        hs_d;
    reg        saw_high, done_one_frame;
    reg [11:0] xa, ya;
    integer    bi;
    reg [23:0] exp_bar [0:7];

    integer t0, guard;

    initial begin
        exp_bar[0] = 24'hC0C0C0;  exp_bar[1] = 24'hC0C000;
        exp_bar[2] = 24'h00C0C0;  exp_bar[3] = 24'h00C000;
        exp_bar[4] = 24'hC000C0;  exp_bar[5] = 24'hC00000;
        exp_bar[6] = 24'h0000C0;  exp_bar[7] = 24'h000000;

        $display("=== [A] colorbar_gen: 480p60 timing / pattern ===");

        // 复位 4 拍后释放
        rstn = 1'b0;
        repeat (4) @(negedge clk);
        rstn = 1'b1;

        // ---- 对齐到帧首：先等 vs 变高，再等它变低（= v_count 回到 0）----
        guard = 0;
        while (vs !== 1'b1) begin @(negedge clk); guard = guard + 1;
            if (guard > 2*FRAME) begin $display("FATAL: vs 一直不为高"); $finish; end end
        guard = 0;
        while (vs !== 1'b0) begin @(negedge clk); guard = guard + 1;
            if (guard > 2*FRAME) begin $display("FATAL: vs 一直不为低"); $finish; end end

        // 此刻正好是帧首那一拍
        x_d1 = u_cb.x_act;  y_d1 = u_cb.y_act;
        hs_d = hs;
        de_px = 0; hs_low = 0; vs_low = 0; hs_rise = 0; cyc = 0;
        min_x = 12'hFFF; max_x = 12'h000;
        min_y = 12'hFFF; max_y = 12'h000;
        bar_bad = 0; border_bad = 0;
        saw_high = 1'b0; done_one_frame = 1'b0; t0 = 0;

        // ---- 观测整整一帧：从这次 vs 下降沿到下一次 ----
        while (!done_one_frame) begin
            @(negedge clk);
            cyc = cyc + 1;

            // 本拍输出 = 上一拍的图案坐标
            xa = x_d1;  ya = y_d1;

            if (!vs) vs_low = vs_low + 1;          // 负极性：低 = 帧首那 2 行
            if (vs) begin
                saw_high = 1'b1;
            end else if (saw_high) begin
                done_one_frame = 1'b1;      // 下一帧帧首
            end

            if (!hs) hs_low = hs_low + 1;          // 负极性：低 = 同步脉冲
            if (hs && !hs_d) hs_rise = hs_rise + 1;
            hs_d = hs;

            if (de) begin
                de_px = de_px + 1;
                if (xa < min_x) min_x = xa;
                if (xa > max_x) max_x = xa;
                if (ya < min_y) min_y = ya;
                if (ya > max_y) max_y = ya;

                if ((xa < 2) || (xa >= 638) || (ya < 2) || (ya >= 478)) begin
                    if (rgb !== 24'hFFFFFF) border_bad = border_bad + 1;
                end else begin
                    if      (xa <  80) bi = 0;
                    else if (xa < 160) bi = 1;
                    else if (xa < 240) bi = 2;
                    else if (xa < 320) bi = 3;
                    else if (xa < 400) bi = 4;
                    else if (xa < 480) bi = 5;
                    else if (xa < 560) bi = 6;
                    else               bi = 7;
                    if (rgb !== exp_bar[bi]) bar_bad = bar_bad + 1;
                end
            end

            // 为下一拍准备延迟一拍坐标
            x_d1 = u_cb.x_act;  y_d1 = u_cb.y_act;

            if (cyc > 2*FRAME) begin
                $display("FATAL: 一帧内没有再次看到 vs 下降沿"); $finish;
            end
        end
        frame_cyc = cyc;

        // ---- [1] 帧长 ----
        if (frame_cyc !== FRAME) begin
            errors = errors + 1;
            $display("FAIL [1] 帧周期 = %0d 拍，期望 %0d (=%0d×%0d)",
                     frame_cyc, FRAME, H_TOTAL, V_TOTAL);
        end else $display("PASS [1] 帧周期 = %0d 拍 = 800 × 525", frame_cyc);

        // ---- [1] 行同步（负极性：**低** 96 拍/行）----
        if (hs_low !== 96 * V_TOTAL) begin
            errors = errors + 1;
            $display("FAIL [1] hs 低电平 = %0d 拍，期望 %0d (=96×525)", hs_low, 96*V_TOTAL);
        end else $display("PASS [1] 行同步: 每帧 hs 低 %0d 拍 = 96 × 525 行", hs_low);

        if (hs_rise !== V_TOTAL) begin
            errors = errors + 1;
            $display("FAIL [1] 每帧 hs 脉冲数 = %0d，期望 %0d", hs_rise, V_TOTAL);
        end else $display("PASS [1] 每帧 %0d 个行同步脉冲", hs_rise);

        // ---- [1] 帧同步（负极性：**低** 2 行 × 800）----
        if (vs_low !== 2 * H_TOTAL) begin
            errors = errors + 1;
            $display("FAIL [1] vs 低电平 = %0d 拍，期望 %0d (=2×800)", vs_low, 2*H_TOTAL);
        end else $display("PASS [1] 帧同步: 每帧 vs 低 %0d 拍 = 2 行 × 800", vs_low);

        // ---- [2] 有效区 ----
        if (de_px !== 640 * 480) begin
            errors = errors + 1;
            $display("FAIL [2] de 高电平 = %0d 拍，期望 %0d", de_px, 640*480);
        end else $display("PASS [2] 有效区: de 高 %0d 拍 = 640 × 480", de_px);

        if ((min_x !== 0) || (max_x !== 639)) begin
            errors = errors + 1;
            $display("FAIL [2] x_act 范围 = %0d..%0d，期望 0..639", min_x, max_x);
        end else $display("PASS [2] x_act 走满 0..639");

        if ((min_y !== 0) || (max_y !== 479)) begin
            errors = errors + 1;
            $display("FAIL [2] y_act 范围 = %0d..%0d，期望 0..479", min_y, max_y);
        end else $display("PASS [2] y_act 走满 0..479");

        // ---- [3] 极性 ----
        // 负极性 = 空闲为高。de 有效期间不应出现同步脉冲，即 hs/vs 必须都是高。
        // 用整帧重新扫一遍来独立验证（每次 de && (!hs||!vs) 都算错）。
        begin : chk_polarity
            integer bad, n;
            bad = 0;
            rstn = 1'b0; repeat (4) @(negedge clk); rstn = 1'b1;
            for (n = 0; n < FRAME; n = n + 1) begin
                @(negedge clk);
                if (de && (!hs || !vs)) bad = bad + 1;
            end
            if (bad !== 0) begin
                errors = errors + 1;
                $display("FAIL [3] de 有效期间 hs/vs 有 %0d 拍为低（负极性应恒高）", bad);
            end else $display("PASS [3] 同步极性为负：de 有效期间 hs/vs 恒高");
        end

        // ---- [4] 图案 ----
        if (bar_bad !== 0) begin
            errors = errors + 1;
            $display("FAIL [4] 彩条颜色/边界错误 %0d 处", bar_bad);
        end else $display("PASS [4] 8 条彩条颜色与边界全部正确");

        if (border_bad !== 0) begin
            errors = errors + 1;
            $display("FAIL [4] 白边框错误 %0d 处", border_bad);
        end else $display("PASS [4] 外圈 2 像素白边框正确");

        // ==============================================================
        // [B] tmds_encoder：de=0 时的四个控制令牌
        // ==============================================================
        $display("");
        $display("=== [B] tmds_encoder: de=0 控制令牌 ===");
        begin : chk_tokens
            integer c;
            reg [9:0] exp;
            for (c = 0; c < 4; c = c + 1) begin
                case (c)
                    0: begin c1_e = 1'b0; c0_e = 1'b0; exp = 10'b1101010100; end
                    1: begin c1_e = 1'b0; c0_e = 1'b1; exp = 10'b0010101011; end
                    2: begin c1_e = 1'b1; c0_e = 1'b0; exp = 10'b0101010100; end
                    default: begin c1_e = 1'b1; c0_e = 1'b1; exp = 10'b1010101011; end
                endcase
                // dout 相对输入有 3 级流水
                repeat (5) @(negedge clk);
                if (dout_e !== exp) begin
                    errors = errors + 1;
                    $display("FAIL [5] c1c0=%b  dout=%b  期望 %b", {c1_e, c0_e}, dout_e, exp);
                end else $display("PASS [5] c1c0=%b  dout=%b", {c1_e, c0_e}, dout_e);
            end
        end

        $display("");
        if (errors == 0) $display(">>> ALL PASS");
        else             $display(">>> %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
