`timescale 1ns/1ps
// ============================================================================
// 逐拍调试台 —— 排查"访存等待（mem_ready）"引入的问题
// ----------------------------------------------------------------------------
// 只做一件事：把 pc / mem_addr / mem_we / mem_re / mem_ready 逐拍打出来，
// 用来对比 +MEMWAIT=0 与 +MEMWAIT=n 时程序从哪一拍开始走岔。
//
// 用法（放在 sim/tools/ 下，避免被 run_sim 的通配捞走）：
//   cd sim
//   iverilog -g2012 -o /tmp/dbg.vvp -I ../rtl/core -I ../rtl/periph -I ../rtl/bus -I . \
//            -s tb_memdbg tools/tb_memdbg.v ../rtl/core/*.v ../rtl/bus/mem_bus.v \
//            ../rtl/periph/*.v ../rtl/top/cpu_top.v
//   vvp /tmp/dbg.vvp "+IMEM=../scripts/rtthread/build/imem.hex" \
//                     "+DMEM=../scripts/rtthread/build/dmem.hex" "+MEMWAIT=2" "+N=200"
// ============================================================================

`include "mem_model.vh"

module tb_memdbg;
    reg  clk = 1'b0;
    reg  resetn;
    reg  [7:0] key;
    reg  uart_rx;
    wire [7:0] led;
    wire uart_tx, done;
    wire [31:0] pc;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re, mem_ready;
    wire [14:0] imem_addr;     // 与 core / mem_bus 的端口同宽（128KB = 32768 word），别改窄
    wire [31:0] imem_rd;

    integer n_cycles = 120;
    integer cyc = 0;

    always #5 clk = ~clk;

    cpu_top u_soc (
        .clk(clk), .resetn(resetn), .pc(pc),
        .uart_tx(uart_tx), .uart_rx(uart_rx), .led(led), .key(key), .done(done)
    );

    // 从内部层次里把总线信号掏出来看（只为调试，不综合）
    assign imem_addr = u_soc.imem_addr;
    assign imem_rd   = u_soc.imem_rd;
    assign mem_addr  = u_soc.mem_addr;
    assign mem_we    = u_soc.mem_we;
    assign mem_re    = u_soc.mem_re;
    assign mem_ready = u_soc.mem_ready;

    // 分支相关（用来判断"分支到底有没有在 EX 级解析"）
    wire        ex_flush    = u_soc.u_core.ex_flush;
    wire        p_redirect  = u_soc.u_core.p_redirect;
    wire        id_ex_br    = u_soc.u_core.id_ex_branch;
    wire        br_taken    = u_soc.u_core.branch_taken;
    wire        idex_pred   = u_soc.u_core.id_ex_pred_taken;
    wire [4:0]  idex_rs1    = u_soc.u_core.id_ex_rs1;
    wire [31:0] alu_a       = u_soc.u_core.alu_a;
    wire [31:0] alu_b       = u_soc.u_core.alu_b;
    // 分支比较用的是这两个（不是 alu_a/alu_b —— 那对是 ALU 输入，分支时不一定取 rs2）
    wire [31:0] rs1_val     = u_soc.u_core.rs1_val;
    wire [31:0] rs2_val     = u_soc.u_core.rs2_val;
    wire [2:0]  idex_f3     = u_soc.u_core.id_ex_funct3;
    wire        fwd_a_ex    = u_soc.u_core.fwd_a_ex;
    wire        fwd_b_ex    = u_soc.u_core.fwd_b_ex;
    wire        fwd_a_wb    = u_soc.u_core.fwd_a_wb;
    wire        fwd_b_wb    = u_soc.u_core.fwd_b_wb;

    initial begin
        void'($value$plusargs("N=%d", n_cycles));
        resetn = 1'b0; key = 8'hFF; uart_rx = 1'b1;
        repeat (20) @(negedge clk);
        resetn = 1'b1;
        $display("cyc  pc       we rdy | exfl prdr idexbr brtk pred f3 | rs1_val    rs2_val    | fAe fBe fAw fBw");
        for (cyc = 0; cyc < n_cycles; cyc = cyc + 1) begin
            @(negedge clk);
            $display("%4d %08x  %b  %b  | %b    %b    %b      %b    %b    %b  | %08x   %08x   | %b   %b   %b   %b",
                     cyc, pc, mem_we, mem_ready,
                     ex_flush, p_redirect, id_ex_br, br_taken, idex_pred, idex_f3,
                     rs1_val, rs2_val,
                     fwd_a_ex, fwd_b_ex, fwd_a_wb, fwd_b_wb);
        end
        $finish;
    end
endmodule
