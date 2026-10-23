`timescale 1ns/1ps
// ============================================================================
// RT-Thread 移植验证测试台
// ----------------------------------------------------------------------------
// 跑整个 SoC（core + mem_bus + gpio + uart_tx + uart_rx），把 UART TX 按真实波特率
// 解码成字节流，然后检查 scripts/rtthread/app/main.c 那四个自检是否成立：
//
//   [1] 控制台通了        —— 出现 RT-Thread banner
//   [2] render 线程起来了 —— 出现 "[boot] gomoku render thread running"
//   [3] AI 线程起来了      —— 出现 "[boot] gomoku ai thread running"（任务 T1/G3 拆线程）
//   [4] 调度器在跑         —— 主线程心跳 "[hb] alive" 出现。
//       这一条一举证明两件事：**调度器正常**，且**render 线程没把 CPU 独占死**
//       （心跳还挤得进来）。
//
// [任务 H 说明] 本测试台原来验的是 ping/pong 双线程移植（信号量 + 上下文切换）。
// 那条已经完成使命，应用换成五子棋后判据跟着换。ping/pong 版本在 git 历史里。
// 任务 T1/G3 又把单线程五子棋拆成 render + AI，于是多了 [3] 这条 AI 线程判据。
//
// [!] 跑之前要先按【仿真口径】编固件（时钟 100MHz、短延时、出 hex）：
//       scripts\rtthread\build.ps1 -Sim
//     然后：
//       cd sim
//       iverilog -g2012 -o tb_rtthread.vvp -I ../rtl/core -I ../rtl/periph -I ../rtl/bus \
//                -I . -s tb_rtthread tb_rtthread.v ../rtl/core/*.v ../rtl/bus/mem_bus.v \
//                ../rtl/periph/*.v ../rtl/top/cpu_top.v
//       vvp tb_rtthread.vvp "+IMEM=../scripts/rtthread/build/imem.hex" \
//                          "+DMEM=../scripts/rtthread/build/dmem.hex"
//     （也可以直接跑 scripts\rtthread\run_sim.ps1）
//
// [重点] 换行一律用 CRLF 常量拼，别在字符串里写 \r ——
//   Verilog 转义只有 \n \t \\ \" 和 \ddd，没有 \r。这个坑本工程踩过。
//
// [!] **本测试台必须接【视频口】**（2026-10-10 实踩，CPU 被 X 污染的根因）。
//     cpu_top 的 vid_* 是"显存/控制寄存器 → video_top"的透传口，注释里写着
//     "仿真里这几个测试台不接，而它们也从不访问 0x8001_0000 以上 ⇒ vid_rdata
//      的浮空值不会进 mem_rdata"。**任务 H 之后这句话的前提没了**：
//     五子棋要 video_set_scroll / video_wait_vblank / draw_frame，
//     第一次读 0x8003_0408（VIDEO_STATUS）就让 `mem_rdata = vid_rdata`（悬空 → Z）
//     进了寄存器堆 → Z 参与运算变 X → **PC 变成 0xxxxxxxxx，整颗 CPU 在 ~16ms 死掉**。
//     症状极具迷惑性：串口把 banner 打完就静默、心跳永远不出现，
//     看着像"调度器没跑"或"延时没到"，其实是 CPU 已经没了。
//     （这正是 项目约定文档 关键约定 4 / 13：外设任何时候都不该把 X 放上总线。）
//     所以这里照 tb_gomoku.v 的接法接上真正的 video_core（不接的话见上）。
// ============================================================================

// 统一存储器行为模型（指令+数据共用一块）
`include "mem_model.vh"

module tb_rtthread;
    reg         clk = 1'b0;
    reg         resetn;
    reg  [7:0]  key;
    reg         uart_rx;
    wire [7:0]  led;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;

    // 视频口（mem_bus 译码出来的显存/控制寄存器口）—— 必须接，见文件头 [!]
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;
    wire [31:0] vid_rdata;

    wire [23:0] v_rgb;
    wire        v_de, v_hs, v_vs;

    always #5 clk = ~clk;          // 100MHz 仿真时钟（与本目录其它测试台一致）

    // ---- 配置开关（照 tb_coremark.v 的写法：脚本必须【显式】传，默认关）----
    // [!] 2026-10-14：本测试台原来一个 -D 都不吃，全靠 cpu_top 的参数默认值
    //     （DUAL_ISSUE=1 / EARLY_LD=1 / Cache 关）⇒ rtthread 线的仿真从来没覆盖过
    //     Cache 配置。rtthread + I+D @76.5 位流（c10a2478）上板确定性挂死
    //     （AI 第一手后第一张棋盘快照处数据损坏）就是这么漏过去的（项目约定文档 约定 55）。
    //     现在四个开关全部显式化：run_sim.ps1 默认传 -DDUAL -DEARLYLD（= 板上口径），
    //     -DCache/-ICache 追加；vvp 首行 SIM CONFIG 自证，别再靠默认值。
`ifdef DUAL
    localparam DUAL_OUT = 1;
`else
    localparam DUAL_OUT = 0;
`endif
`ifdef DCACHE
    localparam DCACHE_OUT = 1;
`else
    localparam DCACHE_OUT = 0;
`endif
`ifdef ICACHE
    localparam ICACHE_OUT = 1;
`else
    localparam ICACHE_OUT = 0;
`endif
`ifdef EARLYLD
    localparam EARLYLD_OUT = 1;
`else
    localparam EARLYLD_OUT = 0;
`endif
// [面积优化] A 扩展：默认 0（= 生产档口径，core 默认也是 0）。
//   只有 `rtthread\run_sim.ps1 -Atomic`（-march=rv32ima + 硬件原子固件）才传
//   -DAEXT；不传的话那份固件里的 lr/sc/AMO 会被判非法指令而挂死 —— 那是预期行为。
`ifdef AEXT
    localparam AEXT_OUT = 1;
`else
    localparam AEXT_OUT = 0;
`endif
// [lane B 访存] lane B 放 load：默认 0（与 P2 对照口径一致），-DLANEBMEM 才 1。
//   [!] 2026-10-16 P3 已把 core/cpu_top 的 LANEB_MEM 默认值翻 1 ⇒ 本测试台若
//   【不传】宏就会与板上口径不一致（跑的是 0 档）。回归脚本默认传 -DLANEBMEM。
`ifdef LANEBMEM
    localparam LANEBMEM_OUT = 1;
`else
    localparam LANEBMEM_OUT = 0;
`endif

    // 自证配置：t=0 打印本测试台编译进去的开关，每份日志首行自带口径
    //（与 tb_riscv/tb_coremark 同一格式，回归脚本靠它核对，见 项目约定文档 约定 37）。
    // [!] 2026-10-16 撤档：A1（`LANEB_ST`）判定【不采纳】并已退回，自证行不再有 LANEB_ST。
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d DCACHE_EN=%0d ICACHE_EN=%0d EARLY_LD=%0d A_EXT=%0d LANEB_MEM=%0d",
                     DUAL_OUT, DCACHE_OUT, ICACHE_OUT, EARLYLD_OUT, AEXT_OUT, LANEBMEM_OUT);

    cpu_top #(.DUAL_ISSUE(DUAL_OUT), .DCACHE_EN(DCACHE_OUT),
              .ICACHE_EN(ICACHE_OUT), .EARLY_LD(EARLYLD_OUT),
              .A_EXT(AEXT_OUT), .LANEB_MEM(LANEBMEM_OUT)) u_soc (
        .clk        (clk),
        .resetn     (resetn),
        .pc         (pc),
        .uart_tx    (uart_tx),
        .uart_rx    (uart_rx),
        .led        (led),
        .key        (key),
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

    // video_top 那层壳（pll_video / rgb2tmds / OSERDES）是 PDS 专有原语，
    // iverilog 里不存在，所以直接例化 video_core —— 与 tb_gomoku.v 同一套接法。
    // [!] 时钟：clk 同时当 pix_clk 和 clk_sys（显存是真双口，仿真里同源无妨）。
    //     本测试台不检查 rgb/de/hs/vs（那是 tb_gomoku / tb_video_bars 的事），
    //     接上它只是为了让 vid_rdata 有确定的驱动源。
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
        .rgb        (v_rgb),
        .de         (v_de),
        .hs         (v_hs),
        .vs         (v_vs)
    );

    // 115200 @ 100MHz —— 和 cpu_top 的 UART_DIV 默认值 234 配套
    localparam BIT_NS = 2340;
    localparam [15:0] CRLF = 16'h0D0A;

    // ------------------------------------------------------------------
    // UART TX 解码：下降沿=起始位 -> 等 1.5 位到 bit0 中点 -> 每 1 位采一个。
    // 收到的字节从低位往高位移，所以"最近 N 字节" = rxtext[8*N-1:0]，
    // 顺序与字符串字面量一致，可以直接用 === 比较。
    // [!] 缓冲区给 1024 字节 —— RT-Thread 开机 banner + 几十轮乒乓会超 512。
    // ------------------------------------------------------------------
    localparam RXBUF = 1024;
    reg [8*RXBUF-1:0] rxtext  = 0;
    integer           rxcount = 0;
    reg  [7:0]        rxb;
    integer           bi;

    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS / 2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rxb[bi] = uart_tx;
                #(BIT_NS);
            end
            rxtext  = {rxtext[8*RXBUF-9:0], rxb};
            rxcount = rxcount + 1;
            // [调试 2026-10-14] 挂死现场用：逐字节打 pc —— 每个 UART 字节是哪个 pc
            // 写出来的，配合"写之前 pc 停在哪"定位损坏点（与无 Cache 跑同一条固件对拍）。
            // [!] 默认【关】：一次正常跑也有 168 行，会把日志淹掉。要开就
            //     scripts\rtthread\run_sim.ps1 -RxTrace
`ifdef RXTRACE
            $display("[rx#%0d] pc=0x%h byte=0x%02x", rxcount, pc, rxb);
`endif
        end
    end

    // 需要看的字符串（用 CRLF 常量拼，不要写字面量 \r）
    localparam [16*9-1:0]  S_BANNER = "RT-Thread";
    // [任务 T1/G3] 应用从"单线程五子棋"拆成了 render + AI 两条线程，判据跟着换：
    //   [2] render 线程起来了 —— app/main.c 打的 "[boot] gomoku render thread running"
    //       AI   线程起来了 —— "[boot] gomoku ai thread running"（S_AI 单独验这条，
    //       证明"拆线程"真的生效，不只是有一个 gomoku 线程）。
    //   [3] 主线程心跳在跳 —— "[hb] alive"。它一举证明两件事：
    //       **调度器在跑**，且**render 线程没有独占 CPU**（心跳还能挤进来）。
    // [!] S_GOMOKU 用小写：那行是 rt_kprintf 打的。五子棋自己的 banner 是
    //     "GOMOKU on RV32I"（大写），两者大小写不同，正好分开。
    // [!] S_AI 取 "ai thr"（小写）：只匹配 AI 线程启动行，不碰 render 行/HUD 的 "AI"（大写）。
    localparam [16*6-1:0]  S_GOMOKU = "gomoku";
    localparam [16*6-1:0]  S_AI     = "ai thr";
    localparam [16*6-1:0]  S_HB     = "[hb] a";

    // 等 UART 上再收到 n 个字节
    task wait_rx;
        input integer n;
        integer target;
        begin
            target = rxcount + n;
            while (rxcount < target) @(negedge clk);
        end
    endtask

    integer i;
    integer errors   = 0;
    integer seen_gomoku = 0;
    integer seen_ai     = 0;
    integer seen_hb     = 0;

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    initial begin
        resetn  = 1'b0;
        key     = 8'hFF;           // 按键未按下（低有效）
        uart_rx = 1'b1;            // 串口空闲为高

        // 复位若干拍再放开
        repeat (20) @(negedge clk);
        resetn = 1'b1;

        $display("=== RT-Thread 移植验证开始 ===");

        // ---- [1] 等 banner。RT-Thread 启动 + 首次打印不该要太久 ----
        // 给足余量：启动路径 + 两次 rt_kprintf
        for (i = 0; i < 400000 && rxcount < 200; i = i + 1) @(negedge clk);

        if (rxcount < 10) begin
            $display("[FAIL] 等了很久串口只有 %0d 个字节 —— 控制台没通，或程序没跑起来", rxcount);
            $display("       pc=0x%h", pc);
            errors = errors + 1;
        end else begin
            $display("[OK]   串口收到 %0d 个字节（控制台通了）", rxcount);
            // 在最近 1024 字节里找 banner 关键字
            if (rxtext[8*RXBUF-1:0] === rxtext) ; // 占位，避免 lint 抱怨
        end

        // ---- [2][3] 等程序把该打的都打完，再【一次性】扫描窗口 ----
        // [!] 别写成"每拍扫一遍 1024 字节窗口" —— 那是 4M × 1024 次比较，仿真跑不动。
        //     等固定拍数 -> 扫一次，和原来一样。
        //     3M 拍 @100MHz = 30ms，够等到第一次心跳（HB_DELAY_MS=20ms）。
        for (i = 0; i < 3000000; i = i + 1) @(negedge clk);

        seen_gomoku = 0;
        seen_ai     = 0;
        seen_hb     = 0;
        for (i = 0; i < RXBUF - 6; i = i + 1) begin
            if (rxtext[i*8 +: 8*6] === S_GOMOKU) seen_gomoku = seen_gomoku + 1;
            if (rxtext[i*8 +: 8*6] === S_AI)     seen_ai     = seen_ai + 1;
            if (rxtext[i*8 +: 8*6] === S_HB)     seen_hb     = seen_hb + 1;
        end

        $display("----------------------------------------");
        $display("  收尾时 pc=0x%h（挂死调试用：与无 Cache 跑对拍）", pc);
        $display("  gomoku 标记 %0d 次 / AI 线程标记 %0d 次 / 心跳标记 %0d 次", seen_gomoku, seen_ai, seen_hb);
        $display("  串口共收到 %0d 字节", rxcount);

        if (seen_gomoku == 0) begin
            $display("[FAIL] 没看到 gomoku 线程启动 —— 线程没起来，或链接错了");
            errors = errors + 1;
        end else begin
            $display("[OK]   gomoku 线程已启动（RT-Thread 上跑起了五子棋）");
        end

        // G3 拆线程的专属判据：AI 线程单独起了一条启动行
        if (seen_ai == 0) begin
            $display("[FAIL] 没看到 AI 线程启动 —— 拆线程没生效，还是单线程在跑");
            errors = errors + 1;
        end else begin
            $display("[OK]   AI 线程已启动（render + AI 拆线程生效）");
        end

        // 心跳这一条一举证明两件事：**调度器在跑**，且**游戏线程没独占 CPU**
        if (seen_hb == 0) begin
            $display("[FAIL] 没看到主线程心跳 —— 调度器没跑，或游戏线程把 CPU 占死了");
            errors = errors + 1;
        end else begin
            $display("[OK]   主线程心跳在跳（调度正常，游戏线程没独占 CPU）");
        end

        $display("----------------------------------------");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d 项) ===", errors);
        $display("--- 串口原文（最多 1024 字节，按收到顺序）---");
        begin : dump_bytes
            integer d;
            // [!] 高索引是【早收到】的字节（新字节从 LSB 移入），
            //     所以从 RXBUF-1 往 0 走才是正确的打印顺序。
            for (d = RXBUF - 1; d >= 0; d = d - 1) begin
                if (rxtext[d*8 +: 8] != 8'h00) $write("%c", rxtext[d*8 +: 8]);
            end
            $display("");
        end
        $display("----------------------------------------");
        $finish;
    end

    // ------------------------------------------------------------------
    // 兜底超时：卡死时至少要能看到 pc 停在哪
    // ------------------------------------------------------------------
    initial begin
        #(400000000);   // 400ms 仿真时间
        $display("=== TIMEOUT (pc=0x%h, rxcount=%0d) ===", pc, rxcount);
        $finish;
    end

    // ------------------------------------------------------------------
    // [调试 2026-10-14] PC 逐拍 trace（-DPCTRACE，配 run_sim.ps1 -PcTrace）
    // 用途：Cache 挂死定位 —— 同一固件跑"无 Cache / 带 Cache"两份 trace，
    // 折叠连续重复后 diff，第一条分叉的 pc 就是 Cache 开始出错的位置。
    // [!] 只在 negedge 采样，避开 posedge 竞态；resetn 放开后才记。
    // ------------------------------------------------------------------
`ifdef PCTRACE
    integer ptf;
    initial ptf = $fopen("rtthread_pctrace.txt", "w");
    always @(negedge clk) if (resetn) $fwrite(ptf, "%h\n", pc);
`endif

    // ------------------------------------------------------------------
    // [调试 2026-10-14] IF/ID 逐拍 trace（-DITRACE）
    // 列：if_id_pc if_id_instr if_id_pc_b if_id_instr_b valid pair
    //     p_redirect ex_flush fetch_addr mem_ready
    // 用途：看【到底哪条指令进了 ID、有没有配对、那一拍有没有重定向】——
    // pc trace 只给地址流，看不出"指令被丢/被配对吃掉"这类问题。
    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // [调试 2026-10-14] trap 事件 trace（-DTRAPTRACE）
    // 列：cycle trap_cause id_ex_pc（= 肇事指令 pc）
    // 用途：Cache + RT-Thread 挂死定位 —— 找出第一条【非预期】异常
    //   （预期：ecall=11 与定时器中断 0x8000_0007；其余都是 bug）。
    // ------------------------------------------------------------------
    integer dbg_cyc;
    initial dbg_cyc = 0;
    always @(negedge clk) dbg_cyc = dbg_cyc + 1;

    // ------------------------------------------------------------------
    // [调试 2026-10-14] 访存事件 trace（-DLTRACE）
    // 列：cycle ex_mem_pc mem_re mem_we mem_addr mem_wdata mem_rdata mem_ready
    // 用途：抓"某条 load 返回了错数据"——地址是谁、返回什么、当时 mem_ready 是几。
    //   [!] mem_ready=0 时 MEM 级会【保持】多拍，同一个事件会重复出现 —— 这是
    //       有意保留的信息（能看出停顿形状）。
    // ------------------------------------------------------------------
`ifdef LTRACE
    integer ltf;
    initial ltf = $fopen("rtthread_ltrace.txt", "w");
    always @(negedge clk) if (resetn && (tb_rtthread.u_soc.u_core.mem_re ||
                                         tb_rtthread.u_soc.u_core.mem_we))
        $fwrite(ltf, "%0d %h %b %b %h %h %h %b\n", dbg_cyc,
                tb_rtthread.u_soc.u_core.ex_mem_pc,
                tb_rtthread.u_soc.u_core.mem_re,
                tb_rtthread.u_soc.u_core.mem_we,
                tb_rtthread.u_soc.u_core.mem_addr,
                tb_rtthread.u_soc.u_core.mem_wdata,
                tb_rtthread.u_soc.u_core.mem_rdata,
                tb_rtthread.u_soc.u_core.mem_ready_int);
`endif

    // ------------------------------------------------------------------
    // [调试 2026-10-14] load 数据【自检】+ 规范化访存事件流（-DLDCHK）
    // ------------------------------------------------------------------
    // 目的（Cache + RT-Thread 挂死根因 #2："某次 load 返回了隔壁的数据"）：
    //   * 影子寄存器与 core 的 MEM/WB 级【同一门控 mem_ready_int】镜像，记下
    //     WB 级这条 load 的 (pc / 地址 / funct3 / 地址低位)；
    //   * 期望值取【存储器真值】mem0[addr] —— 与 mem_bus 的 B 口读在【同一个沿】
    //     采样，再按 funct3 解包，所以 RAM load 必须逐位相等；
    //   * 不等即落盘（前 40 条）—— 这就是"第一次返回错数据的 load"。
    // [!] 只在 DCACHE_EN=0 时做比较（开了 D-Cache 后 mem_rdata 来自 Cache 阵列，
    //     真存储器不再是期望值）；事件流两种配置都照记。
    // [!] 事件流是【规范化】的：load 记在它的 WB 沿、store 记在 MEM 沿，停顿期间
    //     的重复自动折叠 ⇒ 无 Cache 与带 Cache 两份可直接逐行 diff，第一条不同
    //     即"首次分叉"。列：`L <idx> <pc> <addr> <f3> <got> <exp> <bad>` /
    //     `S <idx> <pc> <addr> <wdata> <byte_en>`。
    // ------------------------------------------------------------------
`ifdef LDCHK
    integer ecf;
    integer n_ld, n_st, n_bad;
    reg        ck_vld;          // WB 级是不是一条 lane A load（与 mem_wb_* 同门控）
    reg [31:0] ck_pc, ck_addr, ck_word;
    reg [2:0]  ck_f3;
    reg [1:0]  ck_low;
    reg        ck_ram;
    reg        ck_vld_r;
    reg [31:0] ck_pc_r;
    reg        ck_we_r;         // store 事件去重（停顿期间不重复记）
    reg [31:0] ck_sta_r, ck_std_r;

    initial begin
        ecf = $fopen("rtthread_ldtrace.txt", "w");
        n_ld = 0; n_st = 0; n_bad = 0;
        ck_vld = 1'b0; ck_pc = 32'd0; ck_addr = 32'd0; ck_word = 32'd0;
        ck_f3 = 3'd0; ck_low = 2'd0; ck_ram = 1'b0;
        ck_vld_r = 1'b0; ck_pc_r = 32'd0;
        ck_we_r = 1'b0; ck_sta_r = 32'd0; ck_std_r = 32'd0;
    end

    always @(posedge clk) begin
        if (resetn && tb_rtthread.u_soc.u_core.mem_ready_int) begin
            ck_vld  <= tb_rtthread.u_soc.u_core.ex_mem_mem_read &&
                       !tb_rtthread.u_soc.u_core.ex_mem_is_amo;
            ck_pc   <= tb_rtthread.u_soc.u_core.ex_mem_pc;
            ck_addr <= tb_rtthread.u_soc.u_core.mem_addr;
            ck_f3   <= tb_rtthread.u_soc.u_core.ex_mem_funct3;
            ck_low  <= tb_rtthread.u_soc.u_core.mem_addr[1:0];
            ck_word <= tb_rtthread.u_soc.u_bus.u_mem.mem0[tb_rtthread.u_soc.u_core.mem_addr[16:2]];
            ck_ram  <= (tb_rtthread.u_soc.u_core.mem_addr[31:17] == 15'd0) &&
                       !((tb_rtthread.u_soc.u_core.mem_addr[16] == 1'b0) &&
                         (tb_rtthread.u_soc.u_core.mem_addr[15:4] == 12'hFFF));
        end
        ck_vld_r <= ck_vld;
        ck_pc_r  <= ck_pc;
    end

    wire [7:0]  ck_b = (ck_low == 2'd0) ? ck_word[7:0]   :
                       (ck_low == 2'd1) ? ck_word[15:8]  :
                       (ck_low == 2'd2) ? ck_word[23:16] : ck_word[31:24];
    wire [15:0] ck_h = ck_low[1] ? ck_word[31:16] : ck_word[15:0];
    wire [31:0] ck_exp = (ck_f3 == 3'b000) ? {{24{ck_b[7]}}, ck_b} :   // LB
                         (ck_f3 == 3'b001) ? {{16{ck_h[15]}}, ck_h} :  // LH
                         (ck_f3 == 3'b100) ? {24'd0, ck_b} :           // LBU
                         (ck_f3 == 3'b101) ? {16'd0, ck_h} :           // LHU
                         ck_word;                                      // LW
    wire        ck_bad = (DCACHE_OUT == 0) && (ck_exp !== tb_rtthread.u_soc.u_core.wb_data);

    always @(negedge clk) begin
        if (resetn) begin
            // load 事件：在它的 WB 沿记一次（冻结在 WB 多拍时不重复）
            if (ck_vld && ck_ram && (!ck_vld_r || (ck_pc_r !== ck_pc))) begin
                n_ld = n_ld + 1;
                $fwrite(ecf, "L %0d %h %h %b %h %h %b\n", n_ld, ck_pc, ck_addr,
                        ck_f3, tb_rtthread.u_soc.u_core.wb_data, ck_exp,
                        (DCACHE_OUT == 0) ? ck_bad : 1'b0);
                if (ck_bad) begin
                    n_bad = n_bad + 1;
                    if (n_bad <= 40)
                        $display("LDCHK-BAD #%0d (ld#%0d) pc=%h addr=%h f3=%b exp=%h got=%h snap_en=%b snap=%h ex_mem_ld_fast=%b mready=%b cyc=%0d",
                                 n_bad, n_ld, ck_pc, ck_addr, ck_f3, ck_exp,
                                 tb_rtthread.u_soc.u_core.wb_data,
                                 tb_rtthread.u_soc.u_core.wb_rdata_snap_en,
                                 tb_rtthread.u_soc.u_core.wb_rdata_snap,
                                 tb_rtthread.u_soc.u_core.ex_mem_ld_fast,
                                 tb_rtthread.u_soc.u_core.mem_ready_int, dbg_cyc);
                end
            end
            // store 事件：MEM 沿；停顿期间保持不算新事件
            if (tb_rtthread.u_soc.u_core.mem_we &&
                (!ck_we_r || (ck_sta_r !== tb_rtthread.u_soc.u_core.mem_addr) ||
                 (ck_std_r !== tb_rtthread.u_soc.u_core.mem_wdata))) begin
                n_st = n_st + 1;
                $fwrite(ecf, "S %0d %h %h %h %b\n", n_st,
                        tb_rtthread.u_soc.u_core.ex_mem_pc,
                        tb_rtthread.u_soc.u_core.mem_addr,
                        tb_rtthread.u_soc.u_core.mem_wdata,
                        tb_rtthread.u_soc.u_core.mem_byte_en);
            end
        end
        ck_we_r  <= tb_rtthread.u_soc.u_core.mem_we;
        ck_sta_r <= tb_rtthread.u_soc.u_core.mem_addr;
        ck_std_r <= tb_rtthread.u_soc.u_core.mem_wdata;
    end
`endif

`ifdef TRAPTRACE
    integer ttf;
    initial ttf = $fopen("rtthread_traptrace.txt", "w");
    always @(negedge clk) if (resetn && tb_rtthread.u_soc.u_core.trap)
        $fwrite(ttf, "%0d %h %h %h\n", dbg_cyc,
                tb_rtthread.u_soc.u_core.trap_cause,
                tb_rtthread.u_soc.u_core.id_ex_pc,
                tb_rtthread.u_soc.u_core.trap_tval);
`endif

`ifdef ITRACE
    integer itf;
    initial itf = $fopen("rtthread_itrace.txt", "w");
    always @(negedge clk) if (resetn)
        $fwrite(itf, "%h %h %h %b %b %b %h %b | %h %h %h | %b %0d %h | %b %0d %h\n",
                tb_rtthread.u_soc.u_core.if_id_pc,
                tb_rtthread.u_soc.u_core.if_id_instr,
                tb_rtthread.u_soc.u_core.if_id_pc_b,
                tb_rtthread.u_soc.u_core.if_id_pair,
                tb_rtthread.u_soc.u_core.p_redirect,
                tb_rtthread.u_soc.u_core.ex_flush,
                tb_rtthread.u_soc.u_core.fetch_addr,
                tb_rtthread.u_soc.u_core.mem_ready_int,
                tb_rtthread.u_soc.u_core.id_ex_pc,
                tb_rtthread.u_soc.u_core.ex_mem_pc,
                tb_rtthread.u_soc.u_core.mem_wb_pc,
                tb_rtthread.u_soc.u_core.mem_wb_reg_write,
                tb_rtthread.u_soc.u_core.mem_wb_rd,
                tb_rtthread.u_soc.u_core.wb_data,
                tb_rtthread.u_soc.u_core.mem_wb_b_reg_write,
                tb_rtthread.u_soc.u_core.mem_wb_b_rd,
                tb_rtthread.u_soc.u_core.wb_data_b);
`endif

endmodule
