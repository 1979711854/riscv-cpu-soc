`timescale 1ns/1ps
// ============================================================================
// tb_rvc.v —— rvc_expand 的验证测试台
// ----------------------------------------------------------------------------
// [!] 本测试台的期望值**不是手写的**，而是取自 GNU 汇编器
//   （riscv-none-elf-as -march=rv32imc + objdump）实测的真实 16 位编码，
//   与它等价的标准 32 位指令逐位比对。
//   "什么是对的"由工具链定义，不靠我推测位域。
//
//   objdump 实测基准：
//     0001 nop          12f5 addi t0,t0,-3   6349 lui t1,0x12
//     0292 slli t0,t0,48211 srli s0,s0,4     8411 srai s0,s0,4
//     929a add t0,t0,t18c05 sub s0,s0,s1     8c25 xor s0,s0,s1
//     8c45 or  s0,s0,s1 8c65 and s0,s0,s1    40c0 lw  s0,4(s1)
//     c0c0 sw  s0,4(s1) 829a mv  t0,t1       8282 jr  t0
//     9282 jalr t0      4292 lw  t0,4(sp)    c41a sw  t1,8(sp)
//     0800 addi s0,sp,166105 addi sp,sp,32   9002 ebreak
//
// 用例名字放在数组里（iverilog 的 task 端口不接受字符串字面量）。
// ============================================================================
module tb_rvc;

    reg  [15:0] c_instr;
    wire [31:0] r32;
    wire        illegal, is_jump;

    rvc_expand u_dut (
        .c_instr(c_instr), .r32(r32), .illegal(illegal), .is_jump(is_jump)
    );

    integer errors = 0;
    integer checks = 0;

    // ---- 编码助手（拼出期望的 32 位指令）----
    function [31:0] I_type(input [6:0] op, input [4:0] rd, input [2:0] f3,
                           input [4:0] rs1, input [11:0] imm);
        begin I_type = {imm, rs1, f3, rd, op}; end
    endfunction
    function [31:0] S_type(input [6:0] op, input [2:0] f3, input [4:0] rs1,
                           input [11:0] imm, input [4:0] rs2);
        begin S_type = {imm[11:5], rs2, rs1, f3, imm[4:0], op}; end
    endfunction
    function [31:0] R_type(input [6:0] op, input [6:0] f7, input [4:0] rs2,
                           input [4:0] rs1, input [2:0] f3, input [4:0] rd);
        begin R_type = {f7, rs2, rs1, f3, rd, op}; end
    endfunction
    function [31:0] U_type(input [6:0] op, input [4:0] rd, input [19:0] imm20);
        begin U_type = {imm20, rd, op}; end
    endfunction
    function [31:0] B_type(input [4:0] rs2, input [4:0] rs1, input [2:0] f3,
                           input [12:0] imm);
        begin B_type = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011}; end
    endfunction
    function [31:0] J_type(input [4:0] rd, input [20:0] imm);
        begin J_type = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111}; end
    endfunction
    function [31:0] JALR_type(input [4:0] rd, input [4:0] rs1);
        begin JALR_type = {12'd0, rs1, 3'b000, rd, 7'b1100111}; end
    endfunction

    // ---- 用例名字表 ----
    reg [8*26:1] case_name;
    integer cur_id;

    //用宏而非 task：iverilog 对 task 的 input 端口声明有严格限制
    //（混合有类型/无类型即报syntax error），宏没有这个问题。
    `define CHK(ci, expect, exp_ill, exp_jump)                 \
        begin                                               \
            c_instr = ci; #1;                               \
            checks = checks + 1;                            \
            if (r32 !== (expect)) begin                \
                errors = errors + 1;                           \
                $display("  FAIL [%0d] %0s", cur_id, case_name); \
                $display("        16 位入 = %h", ci);              \
                $display("        展开    = %h", r32);            \
                $display("        应为    = %h", (expect));       \
            end                                               \
            if (illegal !== (exp_ill)) begin               \
                errors = errors + 1;                           \
                $display("  FAIL [%0d] %0s : illegal=%0b 应为 %0b", \
                         cur_id, case_name, illegal, (exp_ill));      \
            end                                               \
            if (is_jump !== (exp_jump)) begin               \
                errors = errors + 1;                           \
                $display("  FAIL [%0d] %0s : is_jump=%0b 应为 %0b", \
                         cur_id, case_name, is_jump, (exp_jump));     \
            end                                               \
        end

    integer k;

    initial begin
        $display("========================================");
        $display("  rvc_expand 验证（期望值来自 GNU as 实测）");
        $display("========================================");

        // ---------- 算术/逻辑 ----------
        cur_id=0;  case_name="c.nop";
        `CHK(16'h0001, 32'h00000013, 1'b0,1'b0);
        cur_id=1;  case_name="c.addi t0,-3";
        `CHK(16'h12f5, I_type(7'b0010011,5'd5,3'b000,5'd5,12'hffd), 1'b0,1'b0);
        cur_id=2;  case_name="c.lui t1,0x12";
        `CHK(16'h6349, U_type(7'b0110111,5'd6,20'h00012), 1'b0,1'b0);
        cur_id=3;  case_name="c.slli t0,4";
        `CHK(16'h0292, I_type(7'b0010011,5'd5,3'b001,5'd5,12'h004), 1'b0,1'b0);
        cur_id=4;  case_name="c.srli s0,4";
        `CHK(16'h8011, I_type(7'b0010011,5'd8,3'b101,5'd8,12'h004), 1'b0,1'b0);
        cur_id=5;  case_name="c.srai s0,4";
        `CHK(16'h8411, I_type(7'b0010011,5'd8,3'b101,5'd8,12'h404), 1'b0,1'b0);
        cur_id=6;  case_name="c.add t0,t1";
        `CHK(16'h929a, R_type(7'b0110011,7'b0000000,5'd6,5'd5,3'b000,5'd5), 1'b0,1'b0);
        cur_id=7;  case_name="c.sub s0,s1";
        `CHK(16'h8c05, R_type(7'b0110011,7'b0100000,5'd9,5'd8,3'b000,5'd8), 1'b0,1'b0);
        cur_id=8;  case_name="c.xor s0,s1";
        `CHK(16'h8c25, R_type(7'b0110011,7'b0000000,5'd9,5'd8,3'b100,5'd8), 1'b0,1'b0);
        cur_id=9;  case_name="c.or  s0,s1";
        `CHK(16'h8c45, R_type(7'b0110011,7'b0000000,5'd9,5'd8,3'b110,5'd8), 1'b0,1'b0);
        cur_id=10; case_name="c.and s0,s1";
        `CHK(16'h8c65, R_type(7'b0110011,7'b0000000,5'd9,5'd8,3'b111,5'd8), 1'b0,1'b0);

        // ---------- 访存 ----------
        cur_id=11; case_name="c.lw s0,4(s1)";
        `CHK(16'h40c0, I_type(7'b0000011,5'd8,3'b010,5'd9,12'd4), 1'b0,1'b0);
        cur_id=12; case_name="c.sw s0,4(s1)";
        `CHK(16'hc0c0, S_type(7'b0100011,3'b010,5'd9,12'd4,5'd8), 1'b0,1'b0);
        cur_id=16; case_name="c.lwsp t0,4(sp)";
        `CHK(16'h4292, I_type(7'b0000011,5'd5,3'b010,5'd2,12'd4), 1'b0,1'b0);
        cur_id=17; case_name="c.swsp t1,8(sp)";
        `CHK(16'hc41a, S_type(7'b0100011,3'b010,5'd2,12'd8,5'd6), 1'b0,1'b0);

        // ---------- 跳转/复制 ----------
        cur_id=13; case_name="c.mv t0,t1";
        `CHK(16'h829a, R_type(7'b0110011,7'b0000000,5'd6,5'd0,3'b000,5'd5), 1'b0,1'b0);
        cur_id=14; case_name="c.jr t0";
        `CHK(16'h8282, JALR_type(5'd0,5'd5), 1'b0,1'b1);
        cur_id=15; case_name="c.jalr t0";
        `CHK(16'h9282, JALR_type(5'd1,5'd5), 1'b0,1'b1);
        cur_id=20; case_name="c.ebreak";
        `CHK(16'h9002, 32'h00100073, 1'b0,1'b0);

        // ---------- sp 相对 ----------
        cur_id=18; case_name="c.addi4spn s0,16";
        `CHK(16'h0800, I_type(7'b0010011,5'd8,3'b000,5'd2,12'd16), 1'b0,1'b0);
        cur_id=19; case_name="c.addi16sp sp,32";
        `CHK(16'h6105, I_type(7'b0010011,5'd2,3'b000,5'd2,12'd32), 1'b0,1'b0);

        // ---------- 相对跳转/分支（结构验证）----------
        cur_id=21; case_name="c.j +8";
        `CHK(16'ha009, J_type(5'd0, 21'h8), 1'b0,1'b1);
        cur_id=22; case_name="c.jal +8";
        `CHK(16'h2001, J_type(5'd1, 21'h8), 1'b0,1'b1);
        cur_id=23; case_name="c.beqz s0,+6";
        `CHK(16'hc501, B_type(5'd0,5'd8,3'b000,13'h6), 1'b0,1'b1);
        cur_id=24; case_name="c.bnez s0,+6";
        `CHK(16'he501, B_type(5'd0,5'd8,3'b001,13'h6), 1'b0,1'b1);

        // ---------- 保留编码必须判非法 ----------
        cur_id=25; case_name="RSV c.addi4spn imm=0";
        `CHK(16'h0000, 32'h00000013, 1'b1,1'b0);
        cur_id=26; case_name="RSV c.li rd=0";
        `CHK(16'h4001, 32'h00000013, 1'b1,1'b0);
        cur_id=27; case_name="RSV c.addi16sp imm=0";
        `CHK(16'h6101, 32'h00000013, 1'b1,1'b0);
        cur_id=28; case_name="RSV c.slli rd=0";
        `CHK(16'h0002, 32'h00000013, 1'b1,1'b0);
        cur_id=29; case_name="RSV c.lwsp rd=0";
        `CHK(16'h4002, 32'h00000013, 1'b1,1'b0);
        cur_id=30; case_name="RSV c.jr rs1=0";
        `CHK(16'h8082, 32'h00000013, 1'b1,1'b0);

        // ---------- 穷举：所有 65536 个码不得产生 X ----------
        for (k = 0; k < 65536; k = k + 1) begin
            c_instr = k[15:0];
            #1;
            if (^r32 === 1'bx) begin
                errors = errors + 1;
                $display("  FAIL: 穷举在 %h 产生 X", c_instr);
            end
        end
        checks = checks + 1;
        cur_id=31; case_name="穷举 65536 码无 X";

        $display("");
        $display("========================================");
        $display("  checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display("  === PASS ===");
        else             $display("  === FAIL ===");
        $display("========================================");
        $finish;
    end
endmodule