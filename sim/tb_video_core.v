`timescale 1ns/1ps
`include "addr_map.vh"
// ============================================================================
// tb_video_core —— 显存 CPU 口 + 视频窗口译码 + PPU 扫描输出，端到端
// ----------------------------------------------------------------------------
// 例化 mem_bus + video_core（**不例化 video_top**：它含 pll_video，iverilog 里
// 不存在；所有逻辑都在 video_core 里，见其文件头）。TB 扮演 core 的 MEM 级，
// 按 core.v 的契约驱动 mem_addr/mem_wdata/mem_byte_en/mem_we。
//
// 两个时钟周期不同、且刻意不成整数比（20ns : 39ns，上板是 23:45），这样两个域
// 的相对相位在整个仿真里缓慢漂移 —— 真双口 BRAM 不需要任何握手，漂到哪儿都对。
//
// ----------------------------------------------------------------------------
// 方法论：分两段测，因为这两段能证明的东西【不一样】，缺一不可
// ----------------------------------------------------------------------------
//   [A] 总线与显存口：写进去 → 从总线读回来 → 比对。
//       这一段证明的是**写通路 + 读通路 + 译码**对不对（字节使能有没有落到
//       正确的字节、读回有没有错拍、地址有没有落到错误的窗口）。
//
//   [B] 逐像素比对：期望值由 TB **直接读显存的数组**算出（u_core.u_nt.mem[...]），
//       而不是把 ppu.v 的寻址公式重抄一遍。
//       这一段证明的是**PPU 的寻址**对不对，尤其是 vram_b32 里那个 4:1 字节选择。
//
//   [重点] 为什么 [B] 单独测不出字节使能的 bug：[B] 的期望值读的就是数组，
//     如果 sb 只写对了 1 个字节而另外 3 个没写，数组本身就是"半对"的，期望值
//     会跟着一起错 ⇒ 比对依然全过。所以字节使能必须由 [A] 的读回来证明。
//     反过来 [A] 也测不出字节选择的错位：[A] 只从 32 位字里按地址取字节，走的
//     是 mem_bus 的路径而不是 PPU 的 B 口。两段各管一头。
//
// 跑法（iverilog 装在 D:\iverilog，不在 PATH）：
//   cd sim
//   /d/iverilog/bin/iverilog.exe -g2012 -o /tmp/tb_vc.vvp -I ../rtl/bus \
//       tb_video_core.v ../rtl/bus/mem_bus.v ../rtl/mem/unified_mem.v \
//       ../rtl/video/vram_b32.v ../rtl/video/vram_pal.v \
//       ../rtl/video/sync_vg.v ../rtl/video/ppu.v ../rtl/video/video_core.v
//   /d/iverilog/bin/vvp.exe /tmp/tb_vc.vvp
// ============================================================================
module tb_video_core;

    // ------------------------------------------------------------------
    // 两个时钟：20ns（50MHz）与 39ns（25.6MHz）。不成整数比是故意的。
    // ------------------------------------------------------------------
    reg clk_sys = 1'b0;
    reg pix_clk = 1'b0;
    always #10.0 clk_sys = ~clk_sys;
    always #19.5 pix_clk = ~pix_clk;

    reg rstn_sys = 1'b0;    // clk_sys 域复位
    reg rstn_vid = 1'b0;    // pix 域复位（上板 = resetn & PLL locked）

    integer errors = 0;

    localparam integer H_TOTAL = 810;   // 与 video_core.v 同步（60Hz 修正，2026-10-07）
    localparam integer V_TOTAL = 525;
    localparam integer FRAME   = H_TOTAL * V_TOTAL;   // 420000 个 pix 拍
    localparam integer H_ACT   = 640;

    // ==================================================================
    // TB 扮演的 core MEM 级（T 拍给地址，T+1 拍取数据，见 mem_bus 头注释）
    // ==================================================================
    reg  [31:0] d_addr  = 32'd0, d_wdata = 32'd0;
    reg  [3:0]  d_be    = 4'd0;
    reg         d_we    = 1'b0,  d_re    = 1'b0;

    wire [31:0] mem_rdata;
    wire        mem_ready;

    // 外设读回：给固定值，(11) 用它验证外设区译码没被视频窗口改坏
    wire [31:0] gpio_rdata    = 32'hDEAD_BEEF;
    wire [31:0] uart_rx_rdata = 32'h0000_0055;

    wire        gpio_we, uart_tx_we, uart_rx_ack;
    wire [31:0] periph_wdata;
    wire        done_mmio, irq_timer;

    // ---- 视频口（mem_bus ↔ video_core）----
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;
    wire [31:0] vid_rdata;

    mem_bus u_bus (
        .clk          (clk_sys),
        .resetn       (rstn_sys),
        .imem_addr    (15'd0),   // 取指口宽度 = 128KB 的 word 索引；本测试台不用取指，只求不报宽度警告
        .imem_rd      (),
        .imem_addr2   (15'd0),
        .imem_rd2     (),
        .ld_addr      (15'd0),   // [任务 C] 提前 load 读口：本测试台不用，只求不悬空
        .ld_rdata     (),
        .mem_addr     (d_addr),
        .mem_wdata    (d_wdata),
        .mem_byte_en  (d_be),
        .mem_we       (d_we),
        .mem_re       (d_re),
        .mem_rdata    (mem_rdata),
        .mem_ready    (mem_ready),
        .gpio_we      (gpio_we),
        .uart_tx_we   (uart_tx_we),
        .uart_rx_ack  (uart_rx_ack),
        .periph_wdata (periph_wdata),
        .gpio_rdata   (gpio_rdata),
        .uart_rx_rdata(uart_rx_rdata),
        .vid_we       (vid_we),
        .vid_vsel     (vid_vsel),
        .vid_waddr    (vid_waddr),
        .vid_be       (vid_be),
        .vid_wdata    (vid_wdata),
        .vid_vsel_d   (vid_vsel_d),
        .vid_waddr_d  (vid_waddr_d),
        .vid_rdata    (vid_rdata),
        .done         (done_mmio),
        .irq_timer    (irq_timer)
    );

    wire [23:0] rgb;
    wire        de, hs, vs;

    video_core u_core (
        .pix_clk    (pix_clk),
        .vid_resetn (rstn_vid),
        .clk_sys    (clk_sys),
        .sys_resetn (rstn_sys),
        .vid_we      (vid_we),
        .vid_vsel    (vid_vsel),
        .vid_waddr   (vid_waddr),
        .vid_be      (vid_be),
        .vid_wdata   (vid_wdata),
        .vid_vsel_d  (vid_vsel_d),
        .vid_waddr_d (vid_waddr_d),
        .vid_rdata   (vid_rdata),
        .rgb (rgb),
        .de  (de),
        .hs  (hs),
        .vs  (vs)
    );

    // ==================================================================
    // 选通脉冲计数：用来证明"该响的时候响、不该响的时候绝不响"
    // ==================================================================
    integer gpio_pulses = 0, utx_pulses = 0, vid_pulses = 0;

    always @(posedge clk_sys) begin
        if (gpio_we)    gpio_pulses = gpio_pulses + 1;
        if (uart_tx_we) utx_pulses  = utx_pulses  + 1;
        if (vid_we)     vid_pulses  = vid_pulses  + 1;
    end

    // ==================================================================
    // 一次访存 = 1 拍给、1 拍取。信号在 negedge 上摆好，跨过中间那个
    // posedge（mem_bus 就在那里寄存 rsel_d 一族、BRAM 也在那里写/读）。
    // ==================================================================
    task mem_wr;
        input [31:0] a, dat;
        input [3:0]  be;
        begin
            @(negedge clk_sys);
            d_addr = a; d_wdata = dat; d_be = be; d_we = 1'b1; d_re = 1'b0;
            @(negedge clk_sys);       // 跨过 capture 沿
            d_we = 1'b0;
        end
    endtask

    task mem_rd;
        input  [31:0] a;
        output [31:0] dat;
        begin
            @(negedge clk_sys);
            d_addr = a; d_be = 4'hF; d_we = 1'b0; d_re = 1'b1;
            @(negedge clk_sys);       // BRAM 输出与 rsel_d 都已更新
            dat = mem_rdata;
            d_re = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // 按 RISC-V 语义的 store / load（与 core.v 的格式化逐条对齐）
    //   mem_wdata  : SB = {4{byte}}  SH = {2{half}}  SW = word
    //   mem_byte_en: SB = 4'b0001<<addr[1:0]  SH = 4'b0011<<addr[1:0]  SW = 4'b1111
    // ------------------------------------------------------------------
    task st;
        input [31:0] a, dat;
        input [1:0]  size;          // 0=SB 1=SH 2=SW
        reg [31:0] wd;
        reg [3:0]  be;
        begin
            case (size)
                2'd0: begin wd = {4{dat[7:0]}};  be = 4'b0001 << a[1:0]; end
                2'd1: begin wd = {2{dat[15:0]}}; be = 4'b0011 << a[1:0]; end
                default: begin wd = dat;         be = 4'b1111;           end
            endcase
            mem_wr(a, wd, be);
        end
    endtask

    task ld;
        input  [31:0] a;
        input  [1:0]  size;
        output [31:0] dat;
        reg [31:0] raw;
        integer    sh;
        begin
            mem_rd(a, raw);
            sh = a[1:0] * 8;
            case (size)
                2'd0:    dat = (raw >> sh) & 32'h0000_00FF;
                2'd1:    dat = (raw >> sh) & 32'h0000_FFFF;
                default: dat = raw;
            endcase
        end
    endtask

    // ------------------------------------------------------------------
    // 比对并计数
    // ------------------------------------------------------------------
    task chk;
        // 用 SV 的 string 而不是 [255:0]：iverilog 把位向量转 %s 时会把非 ASCII
        // 字节打成 '?'，中文测试名会变乱码。string 是字节数组，UTF-8 原样输出。
        input string  name;
        input [31:0]  got, exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got 0x%08x  期望 0x%08x", name, got, exp);
            end else $display("PASS %0s = 0x%08x", name, got);
        end
    endtask

    // ==================================================================
    // 显存图案（[B] 用）。注意：期望值不重算这些公式，而是直接读数组 ——
    // 这里只负责"把东西写进去"。
    // ==================================================================
    function [7:0] pat_b; input integer b; begin pat_b = ((b >> 8) ^ (b & 8'hFF)) & 8'hFF; end endfunction
    function [7:0] nt_b;  input integer a; begin nt_b  = ((a & 8'hFF) + ((a >> 8) * 3)) & 8'hFF; end endfunction

    task paint_all;
        integer w, i;
        reg [31:0] v;
        begin
            $display("  正在填显存（调色板 256 + 图块 16384 字 + 图块表 2048 字）...");
            for (i = 0; i < 256; i = i + 1)
                st(`VIDEO_PAL + i*4, {i[7:0], 8'hA5, ~i[7:0]}, 2'd2);

            for (w = 0; w < 16384; w = w + 1) begin
                v = {pat_b(w*4+3), pat_b(w*4+2), pat_b(w*4+1), pat_b(w*4)};
                st(`VIDEO_PAT + w*4, v, 2'd2);
            end

            for (w = 0; w < 2048; w = w + 1) begin
                v = {nt_b(w*4+3), nt_b(w*4+2), nt_b(w*4+1), nt_b(w*4)};
                st(`VIDEO_NT + w*4, v, 2'd2);
            end
        end
    endtask

    // ==================================================================
    // 期望像素：读【数组】而不是重抄公式
    //   字节地址 nta = tile_row*256 + tile_col  ⇒  字 nta>>2，字节 nta[1:0]
    // ==================================================================
    function [23:0] exp_pix;
        input integer xx, yy;
        input [11:0]  sx, sy;
        integer wxx, wyy, nta, pad;
        reg [31:0] w1, w2;
        reg [7:0]  tid, pv;
        begin
            wxx = (xx + sx) & 12'hFFF;
            wyy = (yy + sy) & 12'hFFF;
            nta = (wyy[8:4] * 256) + wxx[11:4];
            w1  = u_core.u_nt.mem[nta >> 2];
            case (nta[1:0])
                2'd0:    tid = w1[ 7: 0];
                2'd1:    tid = w1[15: 8];
                2'd2:    tid = w1[23:16];
                default: tid = w1[31:24];
            endcase
            pad = (tid * 256) + (wyy[3:0] * 16) + wxx[3:0];
            w2  = u_core.u_pat.mem[pad >> 2];
            case (pad[1:0])
                2'd0:    pv = w2[ 7: 0];
                2'd1:    pv = w2[15: 8];
                2'd2:    pv = w2[23:16];
                default: pv = w2[31:24];
            endcase
            exp_pix = u_core.u_pal.mem[pv][23:0];
        end
    endfunction

    // ==================================================================
    // 扫一帧：逐像素比对
    //   对齐到 **video_core 自己的 vs**（它是 vs_ph 延迟 6 拍并取反的输出）。
    //   若去对齐 vs_ph，量出来的窗口会整体偏 6 拍 —— 那是量法问题不是 DUT 问题。
    //
    //   [重点] 极性：DMT 是负极性，ppu 里 sy0 = {de_ph, ~hs_ph, ~vs_ph}，
    //   所以 vs 在【帧同步那 2 行里是低】，其余 523 行全是高 —— 正好和
    //   "vs 高=帧有效" 的直觉相反。于是对齐要这样：
    //     等 vs 落（进 vsync）→ 等 vs 起（vsync 结束）→ 一直数到 vs 再落。
    //   之前写成"等 vs 起、等 vs 落、再数到 vs 起"，量到的是那 2 行消隐，
    //   de 全 0，于是 np=0、比对 0 个像素还"全对"—— 静默假通过。
    // ==================================================================
    integer np, de_px, hs_bad;

    task scan_frame;
        input  [11:0] sx, sy;
        output integer errs;
        integer c, n, x_, y_, g;
        reg [23:0] er;
        reg        done;
        begin
            errs = 0; n = 0; c = 0; de_px = 0; hs_bad = 0;

            g = 0;
            while (vs !== 1'b0) begin @(negedge pix_clk); g = g + 1;
                if (g > 2*FRAME) begin $display("FATAL: 等不到 vsync 开始"); $finish; end end
            g = 0;
            while (vs !== 1'b1) begin @(negedge pix_clk); g = g + 1;
                if (g > 2*FRAME) begin $display("FATAL: 等不到 vsync 结束"); $finish; end end

            // 此刻 = vsync 刚结束。往下数到下一次 vs 落下（= 下一帧 vsync 开始）。
            done = 1'b0;
            while (!done) begin
                @(negedge pix_clk);
                c = c + 1;

                if (vs !== 1'b1) done = 1'b1;
                else begin
                    if (de) begin
                        de_px = de_px + 1;
                        x_ = n % H_ACT;
                        y_ = n / H_ACT;
                        er = exp_pix(x_, y_, sx, sy);
                        if (rgb !== er) begin
                            errs = errs + 1;
                            if (errs <= 4)
                                $display("    px(%0d,%0d) rgb=%06h 期望 %06h (n=%0d)",
                                         x_, y_, rgb, er, n);
                        end
                        n = n + 1;
                    end
                    // de 有效期间 hs 必须已是"无效"的高电平（负极性）
                    if (de && !hs) hs_bad = hs_bad + 1;
                end

                if (c > 2*FRAME) begin
                    $display("FATAL: 一帧内没有再次看到 vs 落下"); $finish; end
            end
            np = n;
        end
    endtask

    // ==================================================================
    // 主流程
    // ==================================================================
    integer i;
    reg [31:0] r0, r1, r2;
    reg [31:0] nt200_before, nt200_after;
    integer    gpio_before, vid_before, utx_before;
    integer    errs;
    reg        vbl_seen;
    integer    g;

    initial begin
        // ---- 复位释放 ----
        rstn_sys = 1'b0; rstn_vid = 1'b0;
        repeat (8) @(negedge clk_sys);
        rstn_sys = 1'b1;
        repeat (8) @(negedge pix_clk);
        rstn_vid = 1'b1;
        repeat (4) @(negedge clk_sys);

        // ==============================================================
        $display("=== [A] 总线译码 / 字节使能 / 读回契约 ===");
        // ==============================================================

        // ---- (1) 32 位字写 + 读回（nametable）----
        st(`VIDEO_NT + 0, 32'h1234_5678, 2'd2);
        ld(`VIDEO_NT + 0, 2'd2, r0);
        chk("A1  NT 整字写读回", r0, 32'h1234_5678);

        // ---- (2) 同一字里逐字节 sb，验证 byte_en 的四条泳道 ----
        st(`VIDEO_NT + 0, 32'hAA,            2'd0);   // lane0
        st(`VIDEO_NT + 1, 32'hBB,            2'd0);   // lane1
        st(`VIDEO_NT + 2, 32'hCC,            2'd0);   // lane2
        st(`VIDEO_NT + 3, 32'hDD,            2'd0);   // lane3
        ld(`VIDEO_NT + 0, 2'd2, r0);
        chk("A2  NT 四拍 sb 拼成 0xDDCCBBAA", r0, 32'hDDCC_BBAA);
        ld(`VIDEO_NT + 1, 2'd0, r0);
        chk("A3  NT 字节 1 = 0xBB（lb 单独读回）", r0, 32'hBB);

        // ---- (3) sb 只动它那一拍，不伤邻居 ----
        st(`VIDEO_NT + 0, 32'h1, 2'd2);              // 整字重铺
        st(`VIDEO_NT + 2, 32'h99, 2'd0);             // 只改 lane2
        ld(`VIDEO_NT + 0, 2'd2, r0);
        chk("A4  sb 只改 lane2", r0, 32'h0099_0001);

        // ---- (4) sh 跨 lane，且按 addr[1:0] 对齐 ----
        st(`VIDEO_NT + 4, 32'h0000_0000, 2'd2);
        st(`VIDEO_NT + 6, 32'hBEEF,       2'd1);     // 半字落在 lane2/3
        ld(`VIDEO_NT + 4, 2'd2, r0);
        chk("A5  sh 落在 lane2/3", r0, 32'hBEEF_0000);
        ld(`VIDEO_NT + 6, 2'd1, r0);
        chk("A6  lh 读回 0xBEEF", r0, 32'h0000_BEEF);

        // ---- (5) 跨字边界：byte 7→8 是两个不同的 BRAM 字 ----
        st(`VIDEO_NT + 7, 32'h77, 2'd0);
        st(`VIDEO_NT + 8, 32'h88, 2'd0);
        ld(`VIDEO_NT + 7, 2'd0, r0);
        ld(`VIDEO_NT + 8, 2'd0, r1);
        chk("A7  跨字 byte7", r0, 32'h77);
        chk("A8  跨字 byte8", r1, 32'h88);

        // ---- (6) pattern 的地址范围是 16 位字节地址，也走一遍 ----
        st(`VIDEO_PAT + 16'hFFFF, 32'h5A, 2'd0);     // pattern 最后一个字节
        ld(`VIDEO_PAT + 16'hFFFF, 2'd0, r0);
        chk("A9  pattern 末字节 @0xFFFF", r0, 32'h5A);

        // ---- (7) 调色板：一项一字 ----
        st(`VIDEO_PAL + 77*4, 32'h00_12_34_56, 2'd2);
        ld(`VIDEO_PAL + 77*4, 2'd2, r0);
        chk("A10 PAL[77] = 0x00123456", r0, 32'h0012_3456);
        st(`VIDEO_PAL + 0*4, 32'h00FF_00FF, 2'd2);
        ld(`VIDEO_PAL + 0*4, 2'd2, r0);
        chk("A11 PAL[0]  = 0x00FF00FF", r0, 32'h00FF_00FF);

        // ---- (8) 控制寄存器：scroll_x / scroll_y ----
        st(`VIDEO_SCROLL_X, 32'h0000_0123, 2'd2);
        ld(`VIDEO_SCROLL_X, 2'd2, r0);
        chk("A12 scroll_x = 0x123", r0, 32'h0000_0123);
        st(`VIDEO_SCROLL_Y, 32'h0000_0ABC, 2'd2);
        ld(`VIDEO_SCROLL_Y, 2'd2, r0);
        chk("A13 scroll_y = 0xABC", r0, 32'h0000_0ABC);

        // 12 位截断：写进去的高位不该冒出来
        st(`VIDEO_SCROLL_X, 32'hFFFF_F123, 2'd2);
        ld(`VIDEO_SCROLL_X, 2'd2, r0);
        chk("A14 scroll_x 12 位截断", r0, 32'h0000_0123);

        // ---- (9) 寄存器只认整字写 sb/sh 应被静默忽略 ----
        st(`VIDEO_SCROLL_X, 32'h0000_0555, 2'd0);    // sb
        ld(`VIDEO_SCROLL_X, 2'd2, r0);
        chk("A15 sb 写寄存器被忽略", r0, 32'h0000_0123);
        st(`VIDEO_SCROLL_X, 32'h0000_0555, 2'd1);    // sh
        ld(`VIDEO_SCROLL_X, 2'd2, r0);
        chk("A16 sh 写寄存器被忽略", r0, 32'h0000_0123);
        // 恢复成待会 [B] 要用的初值
        st(`VIDEO_SCROLL_X, 32'h0000_0000, 2'd2);
        st(`VIDEO_SCROLL_Y, 32'h0000_0000, 2'd2);

        // ---- (10) 视频写不能顺带点到 GPIO（这正是切窗前的那个 bug）----
        gpio_before = gpio_pulses;
        vid_before  = vid_pulses;
        st(`VIDEO_NT + 0, 32'hA5A5_A5A5, 2'd2);
        chk("A17 视频写不触发 gpio_we", gpio_pulses - gpio_before, 32'd0);
        chk("A18 视频写确实触发 vid_we", vid_pulses  - vid_before,  32'd1);

        gpio_before = gpio_pulses;
        vid_before  = vid_pulses;
        st(`VIDEO_PAL + 4, 32'h0011_2233, 2'd2);
        st(`VIDEO_PAT + 4, 32'h4455_6677, 2'd2);
        st(`VIDEO_SCROLL_X, 32'h0000_0007, 2'd2);
        chk("A19 三次视频写都不碰 gpio_we", gpio_pulses - gpio_before, 32'd0);
        chk("A20 三次视频写 = 3 个 vid_we", vid_pulses  - vid_before,  32'd3);
        st(`VIDEO_SCROLL_X, 32'h0000_0000, 2'd2);

        // ---- (11) 外设区译码没被改坏 ----
        gpio_before = gpio_pulses;
        vid_before  = vid_pulses;
        st(32'h8000_0000, 32'h0000_0008, 2'd2);
        chk("A21 GPIO 写触发 gpio_we", gpio_pulses - gpio_before, 32'd1);
        chk("A22 GPIO 写不触发 vid_we", vid_pulses  - vid_before,  32'd0);
        ld(32'h8000_0000, 2'd2, r0);
        chk("A23 GPIO 读回 0xDEADBEEF", r0, 32'hDEAD_BEEF);
        ld(32'h8000_000C, 2'd2, r0);
        chk("A24 UART_RX 读回 0x55", r0, 32'h0000_0055);

        // 外设区里偏移 0x20（== 旧版会被误当成视频寄存器的位置）必须仍走外设
        gpio_before = gpio_pulses;
        vid_before  = vid_pulses;
        st(32'h8000_0020, 32'hFFFF_FFFF, 2'd2);
        chk("A25 0x80000020 不触发 vid_we", vid_pulses  - vid_before,  32'd0);
        chk("A26 0x80000020 也不触发 gpio_we", gpio_pulses - gpio_before, 32'd0);

        // ---- (12) 兼容区 / RAM 译码没被改坏 ----
        utx_before = utx_pulses;
        st(32'h0000_FFFC, 32'h0000_0041, 2'd2);
        chk("A27 兼容区 0xFFFC 触发 uart_tx_we", utx_pulses - utx_before, 32'd1);

        st(32'h0000_1000, 32'h1234_ABCD, 2'd2);
        ld(32'h0000_1000, 2'd2, r0);
        chk("A28 RAM 写读回（RAM 通路未变）", r0, 32'h1234_ABCD);

        // ---- (13) 视频区里未分配的地址不许写（防野地址砸显存）----
        st(`VIDEO_NT + 2048, 32'h0000_1111, 2'd2);
        ld(`VIDEO_NT + 2048, 2'd2, nt200_before);
        vid_before = vid_pulses;
        st(32'h8003_0800, 32'hFFFF_FFFF, 2'd2);      // 视频区内、四个子窗口之外
        chk("A29 未映射视频地址不触发 vid_we", vid_pulses - vid_before, 32'd0);
        ld(`VIDEO_NT + 2048, 2'd2, nt200_after);
        chk("A30 未映射视频地址没砸到 nametable", nt200_after, nt200_before);

        // ---- (14) vblank 状态位：轮询到它拉高（验证 pix→sys 同步链通）----
        //   轮询量 2*FRAME 个 clk_sys 拍 ≈ 16.8ms > 一个 pix 帧的 16.38ms，
        //   所以必然覆盖到至少一次 vblank（每帧宽 62.7us）。
        d_addr = `VIDEO_STATUS; d_be = 4'hF; d_we = 1'b0; d_re = 1'b1;
        vbl_seen = 1'b0; g = 0;
        while ((g < 2*FRAME) && !vbl_seen) begin
            @(negedge clk_sys);
            g = g + 1;
            if (mem_rdata[0] === 1'b1) vbl_seen = 1'b1;
        end
        d_re = 1'b0;
        if (!vbl_seen) begin
            errors = errors + 1;
            $display("FAIL A31 vblank 状态位一直是 0（pix→sys 同步链或 vs_ph 没接上）");
        end else $display("PASS A31 vblank 状态位在 %0d 拍后拉高（同步链通）", g);

        // ==============================================================
        $display("");
        $display("=== [B] 逐像素比对（每帧 307200 个像素）===");
        $display("  期望值直接读显存数组算，不重抄 ppu.v 的寻址公式");
        // ==============================================================

        paint_all;

        // ---- (B1) 不滚动 ----
        st(`VIDEO_SCROLL_X, 32'h0000_0000, 2'd2);
        st(`VIDEO_SCROLL_Y, 32'h0000_0000, 2'd2);
        scan_frame(12'd0, 12'd0, errs);
        if (np !== 640*480) begin
            errors = errors + 1;
            $display("FAIL B1 一帧内 de 采样数 = %0d，期望 %0d", np, 640*480);
        end
        if (hs_bad !== 0) begin
            errors = errors + 1;
            $display("FAIL B1 de 有效期间 hs/vs 有 %0d 拍为低（负极性应恒高）", hs_bad);
        end else $display("PASS B1 极性：de 有效期间 hs/vs 恒高");
        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL B1 scroll=(0,0) 错 %0d / %0d 像素", errs, np);
        end else $display("PASS B1 scroll=(0,0) %0d 像素全对（含 4:1 字节选择）", np);

        // ---- (B2) 滚 16 像素：块边界正好落在屏幕块边界上 ----
        st(`VIDEO_SCROLL_X, 32'h0000_0010, 2'd2);
        st(`VIDEO_SCROLL_Y, 32'h0000_0010, 2'd2);
        scan_frame(12'd16, 12'd16, errs);
        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL B2 scroll=(16,16) 错 %0d / %0d 像素", errs, np);
        end else $display("PASS B2 scroll=(16,16) %0d 像素全对", np);

        // ---- (B3) 滚到世界右端，行内出现环绕 ----
        st(`VIDEO_SCROLL_X, 32'h0000_0FA0, 2'd2);    // 4000
        st(`VIDEO_SCROLL_Y, 32'h0000_0007, 2'd2);
        scan_frame(12'd4000, 12'd7, errs);
        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL B3 scroll=(4000,7) 错 %0d / %0d 像素（世界环绕）", errs, np);
        end else $display("PASS B3 scroll=(4000,7) 环绕 %0d 像素全对", np);

        // ---- (B4) 非整块偏移：验 scroll 真正逐像素生效、不是只在块边界对 ----
        st(`VIDEO_SCROLL_X, 32'h0000_0005, 2'd2);
        st(`VIDEO_SCROLL_Y, 12'h3E7, 2'd2);    // 999
        scan_frame(12'd5, 12'd999, errs);
        if (errs !== 0) begin
            errors = errors + 1;
            $display("FAIL B4 scroll=(5,999) 错 %0d / %0d 像素", errs, np);
        end else $display("PASS B4 scroll=(5,999) %0d 像素全对", np);

        $display("");
        if (errors == 0) $display(">>> ALL PASS");
        else             $display(">>> %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
