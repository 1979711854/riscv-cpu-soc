`timescale 1ns/1ps
// ============================================================================
// 一次性调试台：把 core 的 trap / 重定向 / 停顿信号逐拍打出来
// ----------------------------------------------------------------------------
// 用途：定位"加了 CSR/异常之后基线测试卡住"这类问题。
// 它不是回归的一部分，查清问题后可以删。
//
// 用法： iverilog ... -o tb_debug_trap.vvp sim/tb_debug_trap.v rtl/...
//        vvp tb_debug_trap.vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
//        "+MAXCYC=200"
// ============================================================================
`include "mem_model.vh"

module tb_debug_trap;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    wire [14:0] imem_addr;     // 与 core / mem_bus 的端口同宽（128KB = 32768 word），别改窄
    wire [31:0] imem_rd;
    wire [14:0] imem_addr2;    // 与 core / mem_bus 的端口同宽（128KB），别改窄
    wire [31:0] imem_rd2;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_ready;   // 访存就绪：mem_bus 出，core 入（访存等待机制）
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;
    // [任务 C] 提前 load 读口（C 口）
    wire [14:0] ld_addr;
    wire [31:0] ld_rdata;

    // 接真实的定时器中断（来自 mem_bus 的 CLINT）—— 测中断必须接。
    // （早前为做新旧版本逐拍 diff 曾故意省略这两个端口，那个需求已完成。）
    wire        irq_timer;
    core u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .ebreak(),
        .irq_timer(irq_timer), .irq_ext(1'b0)
    );

    mem_bus u_bus (
        .clk(clk), .resetn(resetn),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .gpio_we(), .uart_tx_we(), .uart_rx_ack(),
        .periph_wdata(), .gpio_rdata(32'd0), .uart_rx_rdata(32'd0),
        .done(),
        .irq_timer(irq_timer)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer maxcyc, cyc;
    initial begin
        maxcyc = 200;
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 200;
        cyc = 0;
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    // 打印对靶子地址（0x7F00 附近）的每一次写入 —— 用于验证"异常指令没产生副作用"
    always @(posedge clk) begin
        if (resetn && mem_we && (mem_addr[31:16] == 16'd0) && (mem_addr[15:8] == 8'h7F))
            $display("  >>> WRITE cyc=%0d addr=%h data=%h be=%b",
                     cyc, mem_addr, mem_wdata, mem_byte_en);
    end

    // 一旦 pc 跑出 RAM 范围就报出前后若干拍并停下 —— 用于定位"跑飞"
    reg pc_bad;
    initial pc_bad = 1'b0;      // 不初始化会是 X，让下面的条件恒假
    always @(posedge clk) begin
        if (resetn && !pc_bad && (pc > 32'h8000)) begin
            pc_bad <= 1'b1;
            $display("\n*** pc 越界 at cyc=%0d pc=%h ***", cyc, pc);
        end
    end

    always @(posedge clk) begin
        if (resetn) begin
            cyc = cyc + 1;
            // 紧凑格式：逐拍 pc + 四级 pc + 重定向来源 + 关键控制位，便于两版本 diff
            // dv/mu 分开打：mc_stall 是二者的并，但调试时要知道【停在哪一个】。
            $display("%0d pc=%h ifid=%h idex=%h exmem=%h memwb=%h st=%b dv=%b mu=%b fl=%b mp=%b rd=%b | trap=%b mc=%b aexp=%h aext=%h acs=%h",
                cyc, pc,
                u_core.if_id_pc, u_core.id_ex_pc, u_core.ex_mem_pc, u_core.mem_wb_pc,
                u_core.stall, u_core.div_stall, u_core.mul_stall,
                u_core.ex_flush, u_core.ex_mispred, u_core.p_redirect,
                u_core.trap, u_core.id_ex_mret,
                u_core.alu_result, u_core.ex_target, u_core.csr_rdata);
            $display("      exp=%b ill=%b ec=%b eb=%b misL=%b misS=%b | irq=%b mtip=%b mieMTIE=%b mstatusMIE=%b int=%b | mtimecmp=%h mtime=%h",
                u_core.ex_exception, u_core.id_ex_illegal,
                u_core.id_ex_sys_ecall, u_core.id_ex_sys_ebreak,
                u_core.load_misaligned, u_core.store_misaligned,
                irq_timer, u_bus.mtip_r, u_core.csr_mie_mtie, u_core.csr_mstatus_mie,
                u_core.int_take, u_bus.mtimecmp, u_bus.cyc);
            if (cyc >= maxcyc) $finish;
        end
    end
endmodule
