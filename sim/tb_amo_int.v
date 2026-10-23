`timescale 1ns/1ps
// ============================================================================
// tb_amo_int.v —— T0：单条 amoadd.w 的 CPU 级逐拍 trace（不判分，只观测）
// ----------------------------------------------------------------------------
// 为什么要有它（见 doc/reports/2026-10-08_taskbook_A_rv32a.md §T0）：
//   tb_amo.v 的 17/17 只证明 amo_unit 模块对。AMO 接进流水线后写回的是 xxxxxxxx，
//   而 riscv-tests / CoreMark 里【一条 AMO 都没有】，抓不到。
//   所以这里跑【恰好一条】amoadd.w，把集成层逐拍摊开看。
//
// 与 tb_riscv.v 的关系：结构相同（core + mem_bus + mem_model.vh 行为存储器），
// 区别只是 (a) 打印逐拍 trace，(b) 用 UART 字节 + done 判结束，不用 tohost。
//
// 跑法（必须在 sim 目录下）：
//   vvp tb_amo_int.vvp +IMEM=programs/imem.hex +DMEM=programs/dmem.hex
// 程序镜像由 sim/tests/amo_int.S 汇编后经 scripts/elf2mem.py 生成。
// ============================================================================

`include "mem_model.vh"

module tb_amo_int;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    wire [14:0] imem_addr;     // 与 core / mem_bus 的端口同宽（128KB = 32768 word），别改窄
    wire [31:0] imem_rd;
    wire [14:0] imem_addr2;    // 与 core / mem_bus 的端口同宽（128KB），别改窄
    wire [31:0] imem_rd2;
    // [任务 C] 提前 load 读口（C 口）：必须接上，悬空会让 core 输入变 Z（约定 13）
    wire [14:0] ld_addr;
    wire [31:0] ld_rdata;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_ready;
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;
    wire        irq_timer;
    wire        done;

    // 与板上比特流一致：默认双发射（编译时加 -DDUAL）。AMO 集成在两条配置下都要看。
`ifdef DUAL
    localparam DUAL_OUT = 1;
`else
    localparam DUAL_OUT = 0;
`endif
    // D-Cache 开关：编译时加 -DDCACHE 即用 DCACHE_EN=1（高阶任务①）。
    // 与 DUAL 同理：脚本必须【显式】传，默认关 —— 跑分一律用关的配置。
`ifdef DCACHE
    localparam DCACHE_OUT = 1;
`else
    localparam DCACHE_OUT = 0;
`endif

    // I-Cache 开关：编译时加 -DICACHE 即用 ICACHE_EN=1（高阶任务①）。默认关。
`ifdef ICACHE
    localparam ICACHE_OUT = 1;
`else
    localparam ICACHE_OUT = 0;
`endif

    // [任务 C] load 地址提前：编译时加 -DEARLYLD 即用 EARLY_LD=1。默认关。
    // [!] core 与 mem_bus 必须收同一个值（一个算地址、一个例化那份阵列）。
`ifdef EARLYLD
    localparam EARLYLD_OUT = 1;
`else
    localparam EARLYLD_OUT = 0;
`endif

    // 自证配置：t=0 打印本测试台编译进去的配置，每份日志首行自带口径。
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d DCACHE_EN=%0d ICACHE_EN=%0d EARLY_LD=%0d",
                     DUAL_OUT, DCACHE_OUT, ICACHE_OUT, EARLYLD_OUT);

    // [!] A_EXT 必须显式传 1 —— 本测试台就是 A 扩展的整核测试，而 core 的默认值
    //     是 0（生产档砍掉 A 扩展省面积，见 core.v 文件头 parameter A_EXT 处）。
    core #(.DUAL_ISSUE(DUAL_OUT), .EARLY_LD(EARLYLD_OUT), .A_EXT(1)) u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .ebreak(),
        .irq_timer(irq_timer),
        .irq_ext  (1'b0)
    );

    mem_bus #(.DCACHE_EN(DCACHE_OUT), .ICACHE_EN(ICACHE_OUT),
              .EARLY_LD(EARLYLD_OUT)) u_bus (
        .clk(clk), .resetn(resetn),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .gpio_we(), .uart_tx_we(), .uart_rx_ack(),
        .periph_wdata(), .gpio_rdata(32'd0), .uart_rx_rdata(32'd0),
        .vid_we(), .vid_vsel(), .vid_waddr(), .vid_be(), .vid_wdata(),
        .vid_vsel_d(), .vid_waddr_d(),
        .vid_rdata(32'd0),
        .done(done),
        .irq_timer(irq_timer),
        .agu_probe_in(32'd0)   // [TASK-C 探针] 仿真恒 0（悬空会变 Z，约定 13）
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100MHz

    initial begin
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    // ======================================================================
    // 逐拍 trace
    // ======================================================================
    integer cyc = 0;
    integer win = 0;          // trace 窗口：AMO 靠近/驻留/写回期间打印
    integer latch_hits = 0;
    integer latch_bad  = 0;   // ST_LATCH 拍 mem_rdata 含 X 的次数

    // AMO 的 st 编码（amo_unit.v）：0=IDLE 1=READ 2=HOLD 3=LATCH 4=WRITE
    // [!] 路径里的 `g_amo` 是 core.v 里包住 amo_unit 的 generate 块名（A_EXT 门控新增）。
    //     本测试台传 A_EXT=1 ⇒ 走的是 if 分支，命名块就是 g_amo。
    wire [2:0] ast = u_core.g_amo.u_amo.st;

    wire [31:0] scr = u_bus.u_mem.mem0[13'd2048];     // RAM[0x2000]（0x2000>>2）

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (!resetn) begin
            win <= 0;
        end else begin
            // 后沿触发窗口：AMO 进 MEM（ex_mem_is_amo）或状态机在跑
            if (u_core.ex_mem_is_amo || (ast != 3'd0)) win <= 12;
            else if (win > 0)                          win <= win - 1;

            if (win > 0) begin
                $display("[cyc=%0d] pc=%h st=%0d amo_stall=%0d ex_mem_is_amo=%0d ex_mem_pc=%h id_ex_pc=%h amo_addr_r=%h mem_addr=%h mem_re=%0d mem_we=%0d mem_rdata=%h amo_wdata=%h RAM_2000=%h",
                         cyc, pc, ast, u_core.amo_stall, u_core.ex_mem_is_amo,
                         u_core.ex_mem_pc, u_core.id_ex_pc,
                         u_core.g_amo.u_amo.amo_addr_r, mem_addr, mem_re, mem_we,
                         mem_rdata, u_core.amo_wdata, scr);
            end

            if (ast == 3'd3) begin          // ST_LATCH：这一刻 mem_rdata 必须有效
                latch_hits <= latch_hits + 1;
                if (^mem_rdata === 1'bx) latch_bad <= latch_bad + 1;
                $display("        *** ST_LATCH: mem_rdata=%h (%s) ***",
                         mem_rdata, (^mem_rdata === 1'bx) ? "含 X —— 读回值无效" : "有效");
            end
        end
    end

    // ======================================================================
    // 结束判据：UART 逐字节 + done
    // ======================================================================
    reg [7:0] uart [0:15];
    integer   uart_n = 0;
    integer   k;

    always @(posedge clk) begin
        if (resetn && u_core.mem_we && (mem_addr == 32'h0000_FFFC) && mem_byte_en[0]) begin
            uart[uart_n[3:0]] <= mem_wdata[7:0];
            uart_n <= uart_n + 1;
        end
    end

    integer watchdog = 0;
    initial begin
        wait(resetn);
        forever begin
            @(posedge clk);
            watchdog = watchdog + 1;
            if (done || watchdog > 20000) begin
                #1;
                $display("");
                $display("========================================");
                $display("  T0 单条 amoadd.w 结果");
                $display("  RAM[0x2000] (字 2048) = %h   期望 00000012", scr);
                $display("  ST_LATCH 拍数 = %0d, 其中 mem_rdata 含 X = %0d",
                         latch_hits, latch_bad);
                $display("  UART 字节数 = %0d", uart_n);
                for (k = 0; k < uart_n; k = k + 1)
                    $display("    UART[%0d]=%h", k, uart[k[3:0]]);
                if (!done) $display("  !!! 未收到 done（%0d 拍）—— pc=%h", watchdog, pc);
                $display("  === %0s ===",
                         (done && scr == 32'h00000012) ? "T0 PASS" : "T0 FAIL");
                $display("========================================");
                $finish;
            end
        end
    end
endmodule
