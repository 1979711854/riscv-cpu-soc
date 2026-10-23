`timescale 1ns/1ps
// ============================================================================
// tb_ppu —— tile 背景层：世界坐标 / 图块边界 / 滚动 / 流水对齐
// ----------------------------------------------------------------------------
// 仿真里**不例化 video_top**（它含 pll_video / GTP_OSERDES_E2 等 PDS 专有
// 原语）。这里直接例化 sync_vg + ppu + 三块 vram_dp，与将来 video_top 里的
// 接法一致。显存内容由 TB 直接写 BRAM 数组（等价于 CPU 早就写好），
// 省掉几万拍的总线写。
//
// 判定方式：**不数流水拍数**。
//   一帧里 de 为高的第 n 个采样点就是屏幕上第 n 个像素 ⇒ (x,y)=(n%640, n/640)。
//   rgb 与 de 是同一个沿出来的寄存器，所以要么同时对齐、要么一起错位。
//   期望值由 TB 用**同一批显存数组**独立算出（不是重抄一遍公式 —— 重抄的话
//   公式里的错误会被复制，测不出来）。图案设计成每一块、每一个子坐标都不同，
//   所以哪怕只错 1 像素，绝大多数像素也会对不上。
//
// 测什么：
//   [1] 时序没被改坏：帧长 800×525、de 恰好 640×480
//   [2] 负极性：de 有效期间 hs/vs 恒高
//   [3] scroll=(0,0) 全帧 307200 个像素逐个比对
//   [4] scroll=(16,16) 同上（验滚动：此时块边界正好落在屏幕块边界上）
//   [5] scroll_x=4000 同上（验世界环绕）
//
// 跑法（iverilog 装在 D:\iverilog，不在 PATH）：
//   cd sim
//   /d/iverilog/bin/iverilog.exe -g2012 -o /tmp/tb_ppu.vvp \
//       tb_ppu.v ../rtl/video/sync_vg.v ../rtl/video/ppu.v ../rtl/video/vram_dp.v
//   /d/iverilog/bin/vvp.exe /tmp/tb_ppu.vvp
// ============================================================================
module tb_ppu;

    reg clk  = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;      // 节拍只看拍数，不看绝对周期

    integer errors = 0;

    localparam integer H_TOTAL = 800;
    localparam integer V_TOTAL = 525;
    localparam integer FRAME   = H_TOTAL * V_TOTAL;
    localparam integer H_ACT   = 640;
    localparam integer V_ACT   = 480;

    // ---- 控制寄存器（TB 当 CPU 用）----
    reg [11:0] scroll_x = 12'd0;
    reg [11:0] scroll_y = 12'd0;

    // ==================================================================
    // 时序发生器：参数与 rtl/video/colorbar_gen.v 里的完全一致
    // ==================================================================
    wire [11:0] x_act, y_act;
    wire        de_ph, hs_ph, vs_ph;

    sync_vg #(
        .X_BITS (12), .Y_BITS (12),
        .H_TOTAL(H_TOTAL), .H_SYNC(96), .H_BP(48), .H_FP(16), .H_ACT(H_ACT),
        .V_TOTAL(V_TOTAL), .V_SYNC( 2), .V_BP(33), .V_FP(10), .V_ACT(V_ACT)
    ) u_timing (
        .clk    (clk),
        .rstn   (rstn),
        .vs_out (vs_ph),
        .hs_out (hs_ph),
        .de_out (de_ph),
        .de_re  (),
        .x_act  (x_act),
        .y_act  (y_act)
    );

    // ==================================================================
    // PPU
    // ==================================================================
    wire [12:0] nt_addr;   wire [7:0]  nt_rdata;
    wire [15:0] pat_addr;  wire [7:0]  pat_rdata;
    wire [7:0]  pal_addr;  wire [23:0] pal_rdata;
    wire [23:0] rgb;
    wire        de, hs, vs;

    ppu u_ppu (
        .pix_clk (clk),
        .rstn    (rstn),
        .x_act   (x_act),
        .y_act   (y_act),
        .de_ph   (de_ph),
        .hs_ph   (hs_ph),
        .vs_ph   (vs_ph),
        .scroll_x(scroll_x),
        .scroll_y(scroll_y),
        .nt_addr (nt_addr),
        .nt_rdata(nt_rdata),
        .pat_addr(pat_addr),
        .pat_rdata(pat_rdata),
        .pal_addr(pal_addr),
        .pal_rdata(pal_rdata),
        .rgb     (rgb),
        .de      (de),
        .hs      (hs),
        .vs      (vs)
    );

    // ==================================================================
    // 三块显存（仿真里读写都挂 clk；硬件上读口挂 pix_clk）
    // ==================================================================
    vram_dp #(.AW(13), .DW(8)) u_nt (
        .wclk(clk), .we(1'b0), .waddr(13'd0), .wdata(8'd0), .w_rdata(),
        .rclk(clk), .raddr(nt_addr), .rdata(nt_rdata)
    );

    vram_dp #(.AW(16), .DW(8)) u_pat (
        .wclk(clk), .we(1'b0), .waddr(16'd0), .wdata(8'd0), .w_rdata(),
        .rclk(clk), .raddr(pat_addr), .rdata(pat_rdata)
    );

    vram_dp #(.AW(8), .DW(24)) u_pal (
        .wclk(clk), .we(1'b0), .waddr(8'd0), .wdata(24'd0), .w_rdata(),
        .rclk(clk), .raddr(pal_addr), .rdata(pal_rdata)
    );

    // ==================================================================
    // 显存内容
    //   nametable[tr][tc] = tc + tr*3      （相邻块一定不同 ⇒ 块边界可测）
    //   pattern[T][py][px] = T ^ (py<<4|px)（每块、每子坐标都不同 ⇒ 错 1 像素也抓得到）
    //   palette[i] = {i, 8'hA5, ~i}        （单射 ⇒ 颜色索引可从 RGB 反推）
    // ==================================================================
    integer i;
    initial begin
        for (i = 0; i < 8192;  i = i + 1) u_nt.mem[i]  = 8'd0;
        for (i = 0; i < 65536; i = i + 1) u_pat.mem[i] = 8'd0;
        for (i = 0; i < 256;   i = i + 1) u_pal.mem[i] = 24'd0;

        for (i = 0; i < 8192; i = i + 1)
            u_nt.mem[i] = (((i & 8'hFF) + ((i >> 8) * 3)) & 8'hFF);

        for (i = 0; i < 65536; i = i + 1)
            u_pat.mem[i] = (((i >> 8) ^ (i & 8'hFF)) & 8'hFF);

        for (i = 0; i < 256; i = i + 1)
            u_pal.mem[i] = {i[7:0], 8'hA5, ~i[7:0]};
    end

    // ==================================================================
    // 期望像素：用**同一批显存数组**独立算一遍
    //   这里刻意不重抄 ppu.v 的位切片公式 —— 直接查数组，测的是 ppu 的
    //   【寻址】对不对，而不是我的公式抄得对不对。
    // ==================================================================
    function [23:0] exp_pix;
        input integer xx;
        input integer yy;
        input [11:0]  sx;
        input [11:0]  sy;
        integer       wx, wy, nta;
        reg   [7:0]   tc, tr, tid, pv;
        begin
            wx  = (xx + sx) & 12'hFFF;
            wy  = (yy + sy) & 12'hFFF;
            tc  = wx[11:4];
            tr  = wy[8:4];
            nta = (tr * 256) + tc;
            tid = u_nt.mem[nta];
            pv  = u_pat.mem[{tid, wy[3:0], wx[3:0]}];
            exp_pix = u_pal.mem[pv];
        end
    endfunction

    // ==================================================================
    // 观测变量
    // ==================================================================
    integer k, np, xx, yy, nbad;
    integer cyc, de_px, vs_low, hs_rise, frame_cyc;
    integer hs_bad;
    reg [23:0] e_rgb;
    reg        saw_high, done_frame;

    // ------------------------------------------------------------------
    // 复位并对齐到帧首（vs_ph 为高再为低 = v_count 回到 0）
    // ------------------------------------------------------------------
    task align_frame;
        integer g;
        begin
            rstn = 1'b0;
            repeat (4) @(negedge clk);
            rstn = 1'b1;
            g = 0;
            while (vs_ph !== 1'b1) begin
                @(negedge clk); g = g + 1;
                if (g > 2*FRAME) begin $display("FATAL: vs_ph 一直不为高"); $finish; end
            end
            g = 0;
            while (vs_ph !== 1'b0) begin
                @(negedge clk); g = g + 1;
                if (g > 2*FRAME) begin $display("FATAL: vs_ph 一直不为低"); $finish; end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // 扫一帧：逐像素比对，并顺便统计帧长/de 宽度/极性
    // ------------------------------------------------------------------
    task check_frame;
        input  [11:0] sx;
        input  [11:0] sy;
        output integer errs;
        integer c, n, x_, y_;
        reg [23:0] er;
        begin
            scroll_x = sx;
            scroll_y = sy;
            align_frame;

            errs = 0; n = 0; c = 0;
            de_px = 0; hs_bad = 0; vs_low = 0;
            saw_high = 1'b0; done_frame = 1'b0;

            while (!done_frame) begin
                @(negedge clk);
                c = c + 1;

                if (!vs) vs_low = vs_low + 1;
                if (vs) saw_high = 1'b1;
                else if (saw_high) done_frame = 1'b1;

                if (de) begin
                    de_px = de_px + 1;
                    x_ = n % H_ACT;
                    y_ = n / H_ACT;
                    er = exp_pix(x_, y_, sx, sy);
                    if (rgb !== er) begin
                        errs = errs + 1;
                        if (errs <= 4)
                            $display("    px(%0d,%0d) rgb=%06h 期望 %06h  (n=%0d)",
                                     x_, y_, rgb, er, n);
                    end
                    n = n + 1;
                end

                if (de && (!hs || !vs)) hs_bad = hs_bad + 1;

                if (c > 2*FRAME) begin
                    $display("FATAL: 一帧内没有再次看到 vs 下降沿"); $finish;
                end
            end
            frame_cyc = c;
            np = n;
        end
    endtask

    // ==================================================================
    // 主流程
    // ==================================================================
    integer errs;

    initial begin
        $display("=== [A] 时序（与 colorbar_gen 逐项一致，防改坏）===");
        // 量帧长必须**对齐到 PPU 自己的 vs**（那是 vs_ph 延迟 6 拍并取反的
        // 输出）。若像 check_frame 那样对齐 vs_ph，起点会比实际输出早 6 拍，
        // 量出来就是 418406 而不是 420000 —— 是量法问题，不是 DUT 问题。
        scroll_x = 12'd0; scroll_y = 12'd0;
        rstn = 1'b0; repeat (4) @(negedge clk); rstn = 1'b1;
        begin : align_vs
            integer g2;
            g2 = 0;
            while (vs !== 1'b1) begin @(negedge clk); g2 = g2 + 1;
                if (g2 > 2*FRAME) begin $display("FATAL: vs 一直不为高"); $finish; end end
            g2 = 0;
            while (vs !== 1'b0) begin @(negedge clk); g2 = g2 + 1;
                if (g2 > 2*FRAME) begin $display("FATAL: vs 一直不为低"); $finish; end end
        end
        saw_high = 1'b0; done_frame = 1'b0;
        cyc = 0; de_px = 0; vs_low = 0;
        while (!done_frame) begin
            @(negedge clk);
            cyc = cyc + 1;
            if (!vs) vs_low = vs_low + 1;
            if (vs) saw_high = 1'b1;
            else if (saw_high) done_frame = 1'b1;
            if (de) de_px = de_px + 1;
            if (cyc > 2*FRAME) begin $display("FATAL: 帧长异常"); $finish; end
        end

        if (cyc !== FRAME) begin
            errors = errors + 1;
            $display("FAIL [1] 帧周期 = %0d 拍，期望 %0d", cyc, FRAME);
        end else $display("PASS [1] 帧周期 = %0d 拍 = 800 × 525", cyc);

        if (de_px !== 640*480) begin
            errors = errors + 1;
            $display("FAIL [1] de 高 = %0d 拍，期望 %0d", de_px, 640*480);
        end else $display("PASS [1] de 高 %0d 拍 = 640 × 480", de_px);

        if (vs_low !== 2*H_TOTAL) begin
            errors = errors + 1;
            $display("FAIL [1] vs 低 = %0d 拍，期望 %0d (=2×800)", vs_low, 2*H_TOTAL);
        end else $display("PASS [1] 帧同步：每帧 vs 低 %0d 拍 = 2 行 × 800", vs_low);

        $display("");
        $display("=== [B] 逐像素比对（每帧 307200 个像素）===");

        // ---- [3] 不滚动 ----
        check_frame(12'd0, 12'd0, errs);
        if (np !== 640*480) begin
            errors = errors + 1;
            $display("FAIL [3] 一帧内 de 采样数 = %0d，期望 %0d", np, 640*480);
        end
        if (hs_bad !== 0) begin
            errors = errors + 1;
            $display("FAIL [2] de 有效期间 hs/vs 有 %0d 拍为低（负极性应恒高）", hs_bad);
        end else $display("PASS [2] 同步极性为负：de 有效期间 hs/vs 恒高");

        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL [3] scroll=(0,0)  错 %0d / %0d 像素", errs, np);
        end else $display("PASS [3] scroll=(0,0)   %0d 像素全对", np);

        // ---- [4] 滚 16 像素（正好一个整块）----
        check_frame(12'd16, 12'd16, errs);
        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL [4] scroll=(16,16) 错 %0d / %0d 像素", errs, np);
        end else $display("PASS [4] scroll=(16,16) %0d 像素全对", np);

        // ---- [5] 滚到世界右端，行内出现环绕 ----
        check_frame(12'd4000, 12'd7, errs);
        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL [5] scroll=(4000,7) 错 %0d / %0d 像素（世界环绕）", errs, np);
        end else $display("PASS [5] scroll=(4000,7) 环绕 %0d 像素全对", np);

        $display("");
        if (errors == 0) $display(">>> ALL PASS");
        else             $display(">>> %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
