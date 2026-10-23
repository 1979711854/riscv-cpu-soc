`timescale 1ns/1ps
// ============================================================================
// control.v 定向单测
// ----------------------------------------------------------------------------
// 覆盖：
//   FENCE / FENCE.I       -> 全部控制信号为 0（NOP，规范允许无 Cache 实现这么做）
//   ECALL                 -> sys_ecall = 1，其余全 0
//   EBREAK                -> sys_ebreak = 1，其余全 0
//   MRET                  -> sys_mret = 1，其余全 0
//   CSR 指令（6 种）       -> is_csr=1, reg_write=1, csr_* 字段正确，其余全 0
//   未定义 opcode / 非法   -> illegal = 1
//   SYSTEM 保留编码        -> illegal = 1
//   以及一条已知正常的指令，确认译码器没被改坏。
//
// 历史：本测试台最初断言"ECALL / 非法指令 → NOP"。那是加异常机制之前的
// 行为，现已作废 —— 这正说明单测要跟着语义一起改，否则它会一直是红的。
// ============================================================================
module tb_control;
    reg  [31:0] instr;
    wire        reg_write, alu_a_sel, alu_b_sel, mem_read, mem_write;
    wire        branch, jump, jump_reg, sys_ebreak;
    wire        is_csr, csr_imm, sys_ecall, sys_mret, illegal;
    wire [11:0] csr_addr;
    wire [1:0]  csr_cmd;
    wire [4:0]  alu_op;
    wire [1:0]  wb_sel;

    control u_ctrl (
        .instr      (instr),
        .reg_write  (reg_write),
        .alu_a_sel  (alu_a_sel),
        .alu_b_sel  (alu_b_sel),
        .alu_op     (alu_op),
        .mem_read   (mem_read),
        .mem_write  (mem_write),
        .branch     (branch),
        .jump       (jump),
        .jump_reg   (jump_reg),
        .wb_sel     (wb_sel),
        .sys_ebreak (sys_ebreak),
        .is_csr     (is_csr),
        .csr_addr   (csr_addr),
        .csr_cmd    (csr_cmd),
        .csr_imm    (csr_imm),
        .sys_ecall  (sys_ecall),
        .sys_mret   (sys_mret),
        .illegal    (illegal)
    );

    integer errors = 0;

    // "除三个系统指令标志之外的"控制信号是否全 0。
    // 注意【不能】把 sys_ecall/sys_ebreak/sys_mret 算进来 —— 它们正是下面
    // expect_sys 要断言的量，算进来会自相矛盾（ECALL 永远"不全零"）。
    wire all_other_zero = !(reg_write | alu_a_sel | alu_b_sel | mem_read | mem_write |
                            branch | jump | jump_reg | is_csr | illegal |
                            (alu_op != 5'd0) | (wb_sel != 2'b00));
    // 真正的"什么都没干"= 上面全 0 且三个系统标志也都为 0
    wire all_zero = all_other_zero && !sys_ecall && !sys_ebreak && !sys_mret;

    // 断言：所有控制信号必须全 0（= 该指令不产生任何副作用 = NOP）
    task expect_nop;
        input [31:0]     ins;
        input [8*48-1:0] name;
        begin
            instr = ins; #1;
            if (!all_zero) begin
                $display("FAIL  %0s (0x%08x): 期望全 0，实际 rw=%b is_csr=%b ill=%b ec=%b eb=%b op=%0d",
                         name, ins, reg_write, is_csr, illegal, sys_ecall,
                         sys_ebreak, alu_op);
                errors = errors + 1;
            end else begin
                $display("ok    %0s (0x%08x) -> NOP", name, ins);
            end
        end
    endtask

    // 断言：单条系统指令的专属标志为 1、且其余控制信号全 0
    task expect_sys;
        input [31:0]     ins;
        input [8*48-1:0] name;
        input            want_ecall;
        input            want_ebreak;
        input            want_mret;
        begin
            instr = ins; #1;
            if (sys_ecall === want_ecall && sys_ebreak === want_ebreak &&
                sys_mret === want_mret && all_other_zero) begin
                $display("ok    %0s (0x%08x)", name, ins);
            end else begin
                $display("FAIL  %0s (0x%08x): ec=%b eb=%b mr=%b (期望 %b/%b/%b) 其余全零=%b",
                         name, ins, sys_ecall, sys_ebreak, sys_mret,
                         want_ecall, want_ebreak, want_mret, all_zero);
                errors = errors + 1;
            end
        end
    endtask

    // 断言：整条指令被判定为非法
    task expect_illegal;
        input [31:0]     ins;
        input [8*48-1:0] name;
        begin
            instr = ins; #1;
            if (illegal === 1'b1 && !reg_write && !mem_read && !mem_write &&
                !is_csr && !sys_ecall && !sys_ebreak && !sys_mret) begin
                $display("ok    %0s (0x%08x) -> illegal=1", name, ins);
            end else begin
                $display("FAIL  %0s (0x%08x): 期望 illegal=1 且无副作用，实际 ill=%b rw=%b is_csr=%b",
                         name, ins, illegal, reg_write, is_csr);
                errors = errors + 1;
            end
        end
    endtask

    // 断言：一条 CSR 指令的字段
    task expect_csr;
        input [31:0]     ins;
        input [8*48-1:0] name;
        input [11:0]     want_addr;
        input [1:0]      want_cmd;
        input            want_imm;
        begin
            instr = ins; #1;
            if (is_csr === 1'b1 && reg_write === 1'b1 &&
                csr_addr === want_addr && csr_cmd === want_cmd &&
                csr_imm === want_imm &&
                !mem_read && !mem_write && !branch && !jump && !jump_reg &&
                !sys_ecall && !sys_ebreak && !sys_mret && !illegal &&
                alu_op === 5'd0 && wb_sel === 2'b00) begin
                $display("ok    %0s (0x%08x) -> csr addr=%h cmd=%b imm=%b",
                         name, ins, csr_addr, csr_cmd, csr_imm);
            end else begin
                $display("FAIL  %0s (0x%08x): is_csr=%b rw=%b addr=%h cmd=%b imm=%b",
                         name, ins, is_csr, reg_write, csr_addr, csr_cmd, csr_imm);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("---- FENCE / FENCE.I（无 Cache 实现按规范可作 NOP）----");
        expect_nop(32'h0FF0000F, "FENCE  fence iorw,iorw");
        expect_nop(32'h0000000F, "FENCE  fence(all-zero imm)");
        expect_nop(32'h0000100F, "FENCE.I");

        $display("---- 特权指令 ----");
        expect_sys(32'h00000073, "ECALL", 1'b1, 1'b0, 1'b0);
        expect_sys(32'h00100073, "EBREAK", 1'b0, 1'b1, 1'b0);
        expect_sys(32'h30200073, "MRET", 1'b0, 1'b0, 1'b1);

        $display("---- CSR 指令（寄存器形式）----");
        // csrrw a0, mstatus, a1 : funct3=001, rd=a0(10), rs1=a1(11), csr=0x300
        expect_csr(32'h30059573, "CSRRW  a0, mstatus, a1", 12'h300, 2'b01, 1'b0);
        // csrrs a0, mtvec, a1   : funct3=010
        expect_csr(32'h3055a573, "CSRRS  a0, mtvec, a1",   12'h305, 2'b10, 1'b0);
        // csrrc a0, mepc, a1    : funct3=011
        expect_csr(32'h3415b573, "CSRRC  a0, mepc, a1",    12'h341, 2'b11, 1'b0);

        $display("---- CSR 指令（立即数形式，源在 instr[19:15]）----");
        // csrrwi a0, mcause, 31 : funct3=101, zimm=11111
        expect_csr(32'h342fd573, "CSRRWI a0, mcause, 31",  12'h342, 2'b01, 1'b1);
        // csrrsi a0, mtval, 10  : funct3=110
        expect_csr(32'h34356573, "CSRRSI a0, mtval, 10",   12'h343, 2'b10, 1'b1);
        // csrrci a0, mscratch, 3: funct3=111
        expect_csr(32'h3401f573, "CSRRCI a0, mscratch, 3", 12'h340, 2'b11, 1'b1);

        $display("---- 全零字必须是气泡，不能报非法 ----");
        // 回归锁：取指同步读有 1 拍延迟，复位后第一拍 IF/ID 会锁存到
        // 存储器的复位值 0x00000000。若把它判为非法指令，**上电第一拍就 trap**，
        // 表现为所有测试在启动早期 TIMEOUT（2026-09-23 实踩）。
        expect_nop(32'h00000000, "全零字（流水线填充期）按气泡处理");

        $display("---- 未定义 / 保留编码 -> illegal ----");
        expect_illegal(32'h0000007F, "未定义 opcode=1111111");
        // SYSTEM 里只有 funct3=100 是保留的；001/010/011/101/110/111 都是 CSR 指令
        expect_illegal(32'h00004073, "SYSTEM funct3=100（保留）");
        // funct3=000 时 imm 必须是 0x000/0x001/0x302 之一，其余非法
        expect_illegal(32'h10500073, "SYSTEM funct3=000 但 imm=0x105（非法）");
        // 换个角度确认：funct3=000 且 imm 合法的那三条【不是】非法的
        expect_sys(32'h00000073, "ECALL  不是非法指令", 1'b1, 1'b0, 1'b0);
        // unimp：RVTEST_CODE_END 用它收尾，编码是 csrrw x0, cycle, x0
        // 它本身是合法的 CSR 指令（会被 csr_file 判为"写只读 CSR" → 非法指令）
        expect_csr(32'hC0001073, "unimp(=csrrw x0, cycle, x0)", 12'hC00, 2'b01, 1'b0);

        $display("---- 抽样回归：常见指令仍然正常 ----");
        // add a0, a1, x5  ->  opcode 0110011, rd=01010, funct3=000
        instr = 32'h00B50533; #1;
        if (reg_write === 1'b1 && alu_op === 5'd0 && wb_sel === 2'b00 &&
            !mem_read && !mem_write && !sys_ebreak && !is_csr && !illegal)
            $display("ok    ADD     (0x00B50533) -> reg_write=1 alu_op=ADD");
        else begin
            $display("FAIL  ADD: 译码异常 rw=%b op=%0d wbs=%b", reg_write, alu_op, wb_sel);
            errors = errors + 1;
        end

        // lw a0, 0(a1)  -> opcode 0000011, funct3=010
        instr = 32'h0005A503; #1;
        if (reg_write === 1'b1 && mem_read === 1'b1 && wb_sel === 2'b01 &&
            !mem_write && !is_csr && !illegal)
            $display("ok    LW      (0x0005A503) -> mem_read=1 wb_sel=MEM");
        else begin
            $display("FAIL  LW: 译码异常 rw=%b mr=%b wbs=%b", reg_write, mem_read, wb_sel);
            errors = errors + 1;
        end

        // 跳转类没被 CSR 逻辑误伤
        instr = 32'h000000EF; #1;   // jal ra, 0
        if (jump === 1'b1 && reg_write === 1'b1 && !is_csr && !illegal)
            $display("ok    JAL     (0x000000EF) -> jump=1");
        else begin
            $display("FAIL  JAL: 译码异常 j=%b rw=%b is_csr=%b", jump, reg_write, is_csr);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d 处) ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #10000;
        $display("=== TIMEOUT ===");
        $finish;
    end
endmodule
