`timescale 1ns/1ps
// ============================================================================
// 彩条固件端到端测试台 —— HDMI 首次上板前的功能门
// ----------------------------------------------------------------------------
// 与 tb_demo.v 的区别：这里把 **cpu_top 和 video_core 连起来**（tb_demo 只接
// cpu_top，视频口悬空）。所以本测试台覆盖的是 tb_video_core.v 覆盖不到的那段：
//
//   [1] 串口自检：CPU 写显存 → mem_bus 视频窗口 → 显存 A 口 → 再读回来
//       固件最后会打印 "SELFCHECK OK"，比对它即可判定这一段通不通。
//   [2] 像素：固件写好的显存被 PPU 扫出来，采一条有效行，验证
//       8 条竖条（白黄青绿品红蓝黑，各 80px）的颜色与边界。
//
// 覆盖不到（仿真里没有、只能上板看的）：pll_video 锁没锁、GTP_OSERDES /
// TMDS 编码与相位、显示器认不认这个时序。所以本测试台 PASS 不等于屏幕会亮，
// 只等于"喂给 TMDS 之前的像素全对"。
//
// 时钟：clk 同时当 clk_sys 和 pix_clk（显存是真双口，仿真里同源无妨；
//   真板上是 49.8927 与 25.5MHz 两个锁相输出）。
// 波特率：cpu_top 默认 UART_DIV=234（27MHz 口径），配上 100MHz 仿真时钟
//   一位就是 234 拍 = 2340ns。换 UART_DIV 必须同步改 BIT_NS。
//
// [重点] 换行一律用 CRLF 常量拼，不要在字符串字面量里写 \r —— Verilog 的转义
//   只有 \n \t \\ \" 和 \ddd，没有 \r，iverilog 会把 \r 当成字面字符 'r'。
// ============================================================================

// 统一存储器行为模型（指令+数据共用一块）
`include "mem_model.vh"

module tb_video_bars;
    reg         clk = 1'b0;
    reg         resetn;
    wire [7:0]  led;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;

    // 视频：mem_bus 译码出的显存口
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;
    wire [31:0] vid_rdata;

    // 画面
    wire [23:0] rgb;
    wire        de, hs, vs;

    always #5 clk = ~clk;          // 100MHz 仿真时钟

    cpu_top u_soc (
        .clk        (clk),
        .resetn     (resetn),
        .pc         (pc),
        .uart_tx    (uart_tx),
        .uart_rx    (1'b1),
        .led        (led),
        .key        (8'hFF),       // 全部松开（本固件不看按键）
        .done       (done),
        .vid_we     (vid_we),
        .vid_vsel   (vid_vsel),
        .vid_waddr  (vid_waddr),
        .vid_be     (vid_be),
        .vid_wdata  (vid_wdata),
        .vid_vsel_d (vid_vsel_d),
        .vid_waddr_d(vid_waddr_d),
        .vid_rdata  (vid_rdata)
    );

    // video_top 里那层壳（pll_video / rgb2tmds / OSERDES）是 PDS 专有原语，
    // iverilog 里不存在，所以这里直接例化 video_core —— 这正是当初把全部逻辑
    // 从 video_top 搬进 video_core 的原因。
    video_core u_vid (
        .pix_clk    (clk),
        .vid_resetn (resetn),
        .clk_sys    (clk),
        .sys_resetn (resetn),
        .vid_we     (vid_we),
        .vid_vsel   (vid_vsel),
        .vid_waddr  (vid_waddr),
        .vid_be     (vid_be),
        .vid_wdata  (vid_wdata),
        .vid_vsel_d (vid_vsel_d),
        .vid_waddr_d(vid_waddr_d),
        .vid_rdata  (vid_rdata),
        .rgb        (rgb),
        .de         (de),
        .hs         (hs),
        .vs         (vs)
    );

    // ------------------------------------------------------------------
    // UART TX 解码（同 tb_demo.v）：收到的字节按顺序压进 rxtext，
    // 最近一个字节在 rxtext[7:0]，再往前在 rxtext[15:8] ……
    // ------------------------------------------------------------------
    localparam BIT_NS = 2340;      // 115200 @ 27MHz 口径的 UART_DIV=234 拍
    localparam [15:0] CRLF = 16'h0D0A;

    reg [8*512-1:0] rxtext  = 0;
    integer         rxcount = 0;
    reg  [7:0]      rxb;
    integer         bi;

    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS / 2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rxb[bi] = uart_tx;
                #(BIT_NS);
            end
            rxtext  = {rxtext[8*512-9:0], rxb};
            rxcount = rxcount + 1;
        end
    end

    // ------------------------------------------------------------------
    // 像素采集：de 有效期内按像素序号 px 计数，在 0/80/…/560 处各采一个点。
    //   !de 时 px 归零 ⇒ 每行的第一个有效像素就是 px=0，与 PPU 的 LAT=6
    //   延迟链对齐（sy5 与 rgb_r 同拍，都是 6 拍），所以 px 就是 x_act。
    // ------------------------------------------------------------------
    integer     px = 0;
    reg [23:0]  cap [0:7];
    reg         px_armed  = 1'b0;   // 自检拍完后才采，避开填显存期间的中间态
    reg         line_done = 1'b0;

    always @(posedge clk) begin
        if (!de) begin
            px <= 0;
        end else begin
            if (px_armed) begin
                if ((px % 80) == 0) cap[px / 80] <= rgb;
                if (px == 639)      line_done <= 1'b1;
            end
            px <= px + 1;
        end
    end

    // ------------------------------------------------------------------
    // 激励与比对
    // ------------------------------------------------------------------
    integer errors = 0;
    integer i;

    task dump_rx;                  // 把收到的字符按顺序打出来（失败时定位用）
        input integer n;
        integer j;
        begin
            $write("      RX text (%0d bytes): \"", n);
            for (j = n - 1; j >= 0; j = j - 1)
                $write("%c", rxtext[8*j +: 8]);
            $write("\"\n");
        end
    endtask

    task check_px;
        input [8*40-1:0] name;
        input integer    k;
        input [23:0]     want;
        begin
            if (cap[k] === want)
                $display("ok    2.%0d %0s: RGB=%06x", k, name, cap[k]);
            else begin
                $display("FAIL  2.%0d %0s: RGB=%06x，期望 %06x", k, name, cap[k], want);
                errors = errors + 1;
            end
        end
    endtask

    // 固件自检全文的字节数（SELFCHECK OK 分支）：
    //   "VIDEO colorbar ready" + CRLF                          22
    //   PAL[1] / PAL[5] / PAL[7]：6+1+8 再 +CRLF 各             17 × 3
    //   NT[0][0] / NT[0][5] = 8+1+2 再 +CRLF 各                13 × 2
    //   NT[0][35] / NT[0][39] = 9+1+2 再 +CRLF 各              14 × 2
    //   NT[31][200] = 11+1+2 再 +CRLF                          16
    //   PAT[7][0] = 9+1+2 再 +CRLF                             14
    //   PAT[3][255] = 11+1+2 再 +CRLF                          16
    //   "SELFCHECK OK" + CRLF                                  14
    localparam integer OK_LEN     = 22 + 17*3 + 13*2 + 14*2 + 16 + 14 + 16 + 14;
    localparam integer BANNER_LEN = 22;

    initial begin
        resetn = 1'b0;
        #100;
        resetn = 1'b1;

        // ---- 1. 等固件把显存填完 + 自检打印完 ----
        $display("---- 1. 等固件跑完并打印自检 ----");
        // 填显存约 1 万次字节写 + 189 字节串口输出；给足 30ms（100MHz 下 300 万拍）
        #30000000;

        if (rxcount == 0) begin
            $display("FAIL  1: 串口一个字节都没收到（CPU 没跑起来？pc=0x%h）", pc);
            errors = errors + 1;
        end else begin
            $display("      收到 %0d 字节", rxcount);
            // rxtext 是移位寄存器：最新字节在 rxtext[7:0]，最早的在高位端，
            // 所以 banner（最早那 22 个字节）要从 [8*rxcount-1] 往下取。
            if (rxcount === OK_LEN &&
                rxtext[8*OK_LEN-1 -: 8*BANNER_LEN] === {"VIDEO colorbar ready", CRLF})
                $display("ok    1a: banner");
            else begin
                $display("FAIL  1a: banner（rxcount=%0d，期望 %0d）", rxcount, OK_LEN);
                dump_rx(rxcount);
                errors = errors + 1;
            end

            if (rxcount === OK_LEN && rxtext[8*14-1:0] === {"SELFCHECK OK", CRLF})
                $display("ok    1b: 显存读回自检 OK（CPU→mem_bus→显存 全通）");
            else begin
                $display("FAIL  1b: 自检未通过或输出长度不符（rxcount=%0d，期望 %0d）",
                         rxcount, OK_LEN);
                dump_rx(rxcount);
                errors = errors + 1;
            end
        end

        // ---- 2. 采一条有效行，逐条比 8 个竖条的颜色 ----
        $display("---- 2. 扫出的像素（一条有效行，每 80px 采一点）----");
        px_armed = 1'b1;
        // 一帧 800×525 = 42 万拍，给 2 帧的时间
        i = 0;
        while (line_done !== 1'b1 && i < 2000000) begin
            @(negedge clk);
            i = i + 1;
        end

        if (line_done !== 1'b1) begin
            $display("FAIL  2: 一直没等到一行有效像素跑完（de 没动？）");
            errors = errors + 1;
        end else begin
            check_px("竖条0 白", 0, 24'hFFFFFF);
            check_px("竖条1 黄", 1, 24'hFFFF00);
            check_px("竖条2 青", 2, 24'h00FFFF);
            check_px("竖条3 绿", 3, 24'h00FF00);
            check_px("竖条4 品红", 4, 24'hFF00FF);
            check_px("竖条5 红", 5, 24'hFF0000);
            check_px("竖条6 蓝", 6, 24'h0000FF);
            check_px("竖条7 黑", 7, 24'h000000);
        end

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d 处) ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #200000000;
        $display("=== TIMEOUT (pc=0x%h, rxcount=%0d, px=%0d, de=%b) ===",
                 pc, rxcount, px, de);
        $finish;
    end
endmodule
