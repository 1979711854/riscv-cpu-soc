`timescale 1ns/1ps
// ============================================================================
// tb_amo.v —— amo_unit 的独立单元测试（不需要整颗 CPU）
// ----------------------------------------------------------------------------
// 为什么单独写这个测试台：
//   amo_unit 的正确性不依赖流水线。把AMO 接进 core.v 之前，先在这里用
//   【内存模型 + 手工驱拍】把 11 个操作和 LR/SC 的成败路径逐条钉死。
//   这是本设计加功能的既有纪律（见 项目约定文档「改完必须跑回归」）。
//
// 判据：每条都打印 PASS/FAIL，最后给总计。
// ============================================================================
module tb_amo;

    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    // ---- AMO 指令编码（RV32A）----
    //AMO:  funct5[31:27] | aq[26] rl[25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]=0101111
    function [31:0] amo_enc(input [4:0] f5, input [4:0] rs2, input [4:0] rs1,
                            input [2:0] f3, input [4:0] rd);
        begin
            amo_enc = {f5, 2'b00, rs2, rs1, f3, rd, 7'b0101111};
        end
    endfunction

    localparam [4:0] F5_LR      = 5'b00010;
    localparam [4:0] F5_SC      = 5'b00011;
    localparam [4:0] F5_AMOSWAP = 5'b00001;
    localparam [4:0] F5_AMOADD  = 5'b00000;
    localparam [4:0] F5_AMOXOR  = 5'b00100;
    localparam [4:0] F5_AMOAND  = 5'b01100;
    localparam [4:0] F5_AMOOR   = 5'b01000;
    localparam [4:0] F5_AMOMIN  = 5'b10000;
    localparam [4:0] F5_AMOMAX  = 5'b10100;
    localparam [4:0] F5_AMOMINU = 5'b11000;
    localparam [4:0] F5_AMOMAXU = 5'b11100;

    // ---- DUT 连线 ----
    reg        start      = 1'b0;
    reg  [31:0] addr       = 32'd0;
    reg  [31:0] rs2_val    = 32'd0;
    reg  [4:0]  funct5     = 5'd0;
    reg  [1:0]  funct3     = 2'b10;
    reg  [31:0] mem_rdata  = 32'd0;
    reg        store_commit= 1'b0;

    wire       amo_mem_re, amo_mem_we, amo_stall, illegal;
    wire [3:0] amo_byte_en;
    wire [31:0] amo_wdata, wb_data;

    // ---- 4KB内存模型（1 拍读延迟，与 core.v 的 unified_mem 契约一致）----
    // AMO 的地址来自 rs1，由 amo_unit 自己锁存并在两拍里复用。
    // 所以内存模型要用【DUT 锁存的地址】，而不是外部的 addr 输入线。
    wire [31:0] amo_addr_for_mem;

    reg [31:0] mem [0:1023];
    reg [31:0] mem_q;              // 读延迟 1 拍
    reg [31:0] mem_q_addr;         // 锁存读地址
    reg        pending_read;

    // 层次引用：取DUT 内部锁存的地址（仅测试台需要，RTL 内部不可见）
    assign amo_addr_for_mem = u_dut.amo_addr_r;

    always @(posedge clk) begin
        // 读：第 T 拍给地址，第 T+1 拍出数据
        if (pending_read) begin
            mem_rdata <= mem[mem_q_addr];
            pending_read <= 1'b0;
        end
        if (amo_mem_re) begin
            mem_q_addr   <= amo_addr_for_mem;
            pending_read <= 1'b1;
        end
        // 写
        if (amo_mem_we) begin
            mem[amo_addr_for_mem] <= amo_wdata;
        end
    end

    amo_unit u_dut (
        .clk(clk), .resetn(resetn),
        .start(start), .addr(addr), .rs2_val(rs2_val),
        .funct5(funct5), .funct3(funct3), .mem_rdata(mem_rdata),
        .amo_mem_re(amo_mem_re), .amo_mem_we(amo_mem_we),
        .amo_byte_en(amo_byte_en), .amo_wdata(amo_wdata),
        .amo_stall(amo_stall), .wb_data(wb_data),
        .illegal(illegal), .store_commit(store_commit)
    );

    integer errors = 0;
    integer checks = 0;
    reg [31:0] got;

    // ---- 跑一条 AMO：给初值、驱动两拍、取结果 ----
    task run_amo(input [4:0] f5, input [31:0] init_mem, input [31:0] operand,
                 input [31:0] expect_old, input [31:0] expect_new,
                 input [8*40:1] name);
        begin
            mem[0] = init_mem;
            @(negedge clk);
            start= 1'b1;
            addr      = 32'd0;      // 指向 mem[0]
            rs2_val   = operand;
            funct5    = f5;
            funct3    = 2'b10;
            @(negedge clk);
            start   = 1'b0;
            // 4 拍状态机：READ -> HOLD -> LATCH -> WRITE -> IDLE
            // 等 st 真正回到 IDLE（结束拍），此时 wb_data 才是本条的结果
            begin : wait_idle
                integer guard;
                guard = 0;
                while (u_dut.st != 2'd0 && guard < 12) begin
                    @(negedge clk);
                    guard = guard + 1;
                end
            end
            got = wb_data;
            checks = checks + 1;
            if (got !== expect_old) begin
                errors = errors + 1;
                $display("  FAIL %0s :写回值 = %h，应为 %h", name, got, expect_old);
            end
            if (mem[0] !== expect_new) begin
                errors = errors + 1;
                $display("  FAIL %0s : 内存 = %h，应为 %h", name, mem[0], expect_new);
            end
            // 回到IDLE 等一拍
            @(negedge clk);
        end
    endtask

    // ---- LR / SC ----
    task do_lr(input [31:0] a, input [31:0] init_mem, input [31:0] expect_old,
               input [8*40:1] name);
        begin
            mem[0] = init_mem;
            @(negedge clk);
            start = 1'b1; addr = a; rs2_val = 32'd0; funct5 = F5_LR; funct3 = 2'b10;
            @(negedge clk);
            start = 1'b0;
            begin : wait_idle_lr
                integer guard;
                guard = 0;
                while (u_dut.st != 2'd0 && guard < 12) begin
                    @(negedge clk);
                    guard = guard + 1;
                end
            end
            got = wb_data;
            checks = checks + 1;
            if (got !== expect_old) begin
                errors = errors + 1;
                $display("  FAIL %0s : LR 写回 = %h，应为 %h", name, got, expect_old);
            end
            if (mem[0] !== init_mem) begin
                errors = errors + 1;
                $display("  FAIL %0s : LR 不该改内存", name);
            end
            @(negedge clk);
        end
    endtask

    task do_sc(input [31:0] a, input [31:0] operand, input [31:0] expect_flag,
               input [31:0] expect_mem, input [8*40:1] name);
        begin
            @(negedge clk);
            start = 1'b1; addr = a; rs2_val = operand; funct5 = F5_SC; funct3 = 2'b10;
            @(negedge clk);
            start = 1'b0;
            begin : wait_idle_sc
                integer guard;
                guard = 0;
                while (u_dut.st != 2'd0 && guard < 12) begin
                    @(negedge clk);
                    guard = guard + 1;
                end
            end
            got = wb_data;
            checks = checks + 1;
            if (got !== expect_flag) begin
                errors = errors + 1;
                $display("  FAIL %0s : SC 写回 = %h，应为 %h（0=失败 1=成功）",
                         name, got, expect_flag);
            end
            if (mem[0] !== expect_mem) begin
                errors = errors + 1;
                $display("  FAIL %0s : SC 后内存 = %h，应为 %h", name, mem[0], expect_mem);
            end
            @(negedge clk);
        end
    endtask

    integer i;
    initial begin
        $display("========================================");
        $display("  amo_unit 单元测试（11 个操作 + LR/SC）");
        $display("========================================");

        resetn = 0;
        repeat (3) @(negedge clk);
        resetn = 1;
        @(negedge clk);

        for (i = 0; i < 1024; i = i + 1) mem[i] = 32'd0;

        $display("-- AMO 基本运算（初值 0x0000000F，operand 0x00000003）--");
        run_amo(F5_AMOADD,  32'h0000000F, 32'h00000003, 32'h0000000F, 32'h00000012, "amoadd");
        run_amo(F5_AMOSWAP, 32'h0000000F, 32'h00000003, 32'h0000000F, 32'h00000003, "amoswap");
        run_amo(F5_AMOXOR,  32'h0000000F, 32'h00000003, 32'h0000000F, 32'h0000000C, "amoxor");
        run_amo(F5_AMOAND,  32'h000000FF, 32'h0000000F, 32'h000000FF, 32'h0000000F, "amoand");
        run_amo(F5_AMOOR,   32'h000000F0, 32'h0000000F, 32'h000000F0, 32'h000000FF, "amoor");

        $display("-- 有符号 / 无符号比较（初值 0xFFFFFFFF = -1）--");
        // amin: -1 < +1  ⇒  取 rd= -1，不变
        run_amo(F5_AMOMIN,  32'hFFFFFFFF, 32'h00000001, 32'hFFFFFFFF, 32'hFFFFFFFF, "amomin");
        // amax: -1 > +1 ? 否⇒ 取 rs2 = +1
        run_amo(F5_AMOMAX,  32'hFFFFFFFF, 32'h00000001, 32'hFFFFFFFF, 32'h00000001, "amomax");
        // minu: 0xFFFFFFFF (大) < 1 ? 否 ⇒ 取 1
        run_amo(F5_AMOMINU, 32'hFFFFFFFF, 32'h00000001, 32'hFFFFFFFF, 32'h00000001, "amominu");
        // maxu: 0xFFFFFFFF > 1 ? 是 ⇒ 不变
        run_amo(F5_AMOMAXU, 32'hFFFFFFFF, 32'h00000001, 32'hFFFFFFFF, 32'hFFFFFFFF, "amomaxu");
        // 有符号 vs 无符号的关键分歧：0x80000000 = -2^31
        //   amomaxu: 0x80000000 > 1 ? 是 ⇒ 不变（按无符号它是很大的数）
        run_amo(F5_AMOMAXU, 32'h80000000, 32'h00000001, 32'h80000000, 32'h80000000, "amomaxu(负数)");
        //   amomax : -2^31 > 1 ? 否 ⇒ 取 1（按有符号它是负数）
        run_amo(F5_AMOMAX,  32'h80000000, 32'h00000001, 32'h80000000, 32'h00000001, "amomax(负数)");

        $display("-- LR / SC 配对 --");
        mem[0] = 32'h000000AA;
        do_lr(32'd0, 32'h000000AA, 32'h000000AA, "LR 读出旧值");
        do_sc(32'd0, 32'h00000055, 32'd1, 32'h00000055, "SC 成功（预约匹配）");

        $display("-- SC 失败路径 --");
        // 重新 LR 一次，再拿别的地址去 SC ⇒ 应失败且不写
        mem[0] = 32'h000000AA;
        do_lr(32'd0, 32'h000000AA, 32'h000000AA, "LR 建立预约");
        do_sc(32'd4, 32'h00000055, 32'd0, 32'h000000AA, "SC 地址不匹配⇒失败");

        $display("-- LR 后被别的 store 打断 ⇒ 预约失效，SC 必须失败 --");
        mem[0] = 32'h000000AA;
        do_lr(32'd0, 32'h000000AA, 32'h000000AA, "LR 建立预约(2)");
        mem[0] = 32'h000000BB;         // 模拟一次普通 store 到别的地址
        @(negedge clk); store_commit = 1'b1; @(negedge clk); store_commit = 1'b0;
        do_sc(32'd0, 32'h00000055, 32'd0, 32'h000000BB, "SC 预约已被 store 打断⇒失败");

        $display("");
        $display("========================================");
        $display("  checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display("  === PASS ===");
        else             $display("  === FAIL ===");
        $display("========================================");
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end
endmodule