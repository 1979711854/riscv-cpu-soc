`timescale 1ns/1ps
// ============================================================================
// rvc_expand.v —— RISC-V C 扩展解码器：16 位压缩指令 → 32 位等价指令
// ----------------------------------------------------------------------------
// 为什么要"展开"而不是直接改译码器：
//   C 扩展约 40 条指令、3 个象限、多种立即数位域交织。塞进现有的 32 位译码器
//   等于在控制通路里再加一层多路选择 —— 那是最长也最乱的路径。
//   而"展开成等价的 32 位指令"让下游一个字都不用改：control.v / alu /
//   寄存器堆 / 分支逻辑看到的都还是标准 32 位编码。
//
// 输入：16 位压缩指令（c_instr[15:0] 有效）
// 输出：32 位等价指令 + 非法标志 + 跳转类标志
//
// ============================================================================
// [!] 字段速查（全部取自 GNU as -march=rv32imc 实测，见 sim/tb_rvc.v）
//
//   inst[1:0]   quadrant
//   inst[15:13] op —— 主分派字段，不是 inst[12:10]
//   inst[12]    多数格式里是 imm[5]
//   inst[11:7]  rd（quadrant2 op=100 时 bit11:10 是二级分派）
//   inst[6:2]   rs2 / 立即数低 5 位
//
//   quadrant0: 000=c.addi4spn 010=c.lw  110=c.sw
//   quadrant1: 000=c.nop/c.addi 001=c.jal 010=c.li 011=c.addi16sp/c.lui
//              100=c.srli/srai/andi/sub/xor/or/and 101=c.j 110=c.beqz 111=c.bnez
//   quadrant2: 000=c.slli 010=c.lwsp  100=c.jr/mv/ebreak/jalr/add  110=c.swsp
//
//   quadrant1 op=100 二级分派用 inst[11:10]：
//              00=c.srli 01=c.srai 10=c.andi 11=ALU（inst[6:5] 再分 sub/xor/or/and）
//   quadrant2 op=100 二级分派用 inst[11:10]：
//              00=c.jr/c.mv（inst[6:2]==0 是 jr）01=c.jalr 10=c.add 11=保留
//              c.ebreak：inst[12]=1 && inst[11:7]=0&& inst[6:2]=00010
//
// [踩过的坑]
//   1) 早期按 inst[12:10] 分派 → c.lw/c.sw/c.add 全展开成垃圾。
//   2) CI 立即数是 6 位有符号，塞进 12 位字段要符号扩展：{{6{imm[5]}},imm}。
//      写成 {imm,6'b0} 会让 -3 变成 61<<6。
//   3) 访存偏移是 7~8 位无符号，要零扩展；S 型还要拆 imm[11:5]/imm[4:0]。
// ============================================================================
module rvc_expand (
    input  wire [15:0] c_instr,
    output reg  [31:0] r32,
    output reg         illegal,
    output reg         is_jump
);

    wire [1:0] quad = c_instr[1:0];
    wire [2:0] op   = c_instr[15:13];
    wire [4:0] rd   = c_instr[11:7];
    wire [4:0] rs2  = c_instr[6:2];

    // 3 位压缩寄存器 -> x8..x15
    wire [4:0] drd  = {2'b01, c_instr[4:2]};
    wire [4:0] drs1 = {2'b01, c_instr[9:7]};
    wire [4:0] drs2 = {2'b01, c_instr[4:2]};
    wire [4:0] drd1 = {2'b01, c_instr[9:7]};   // quadrant1 CA 格式：rd'=rs1'=inst[9:7]

    // CIW nzuimm[5:4|9:6|2|3]
    wire [9:0] nzimm4spn = {c_instr[10:7], c_instr[12:11], c_instr[5], c_instr[6], 2'b00};
    // CL/CS uimm[5:3|2|6]
    wire [6:0] lsimm  = {c_instr[12:10], c_instr[6], c_instr[5], 1'b0};
    // CI imm[5|4:0]（6 位有符号）
    wire [5:0] ciimm  = {c_instr[12], c_instr[6:2]};
    // CJ imm[11|4|9:8|10|6|7|3:1|5]
    // CJ（C.J/C.JAL）：imm[11|4|9:8|10|6|7|3:1|5] = inst[12|11|10:9|8|7|6|5:3|2]
    wire [11:0] cjimm = {c_instr[12], c_instr[11], c_instr[10:9], c_instr[8],
                         c_instr[7], c_instr[6], c_instr[5:3], c_instr[2], 1'b0};
    // CB imm[8|4:3|7:6|2:1|5]
    // CB（C.BEQZ/C.BNEZ）：imm[8|4:3] = inst[12:10]，imm[7:6|2:1|5] = inst[6:2]
    //   拼成 9 位有符号：imm[8], imm[7:6], imm[5], imm[4:3], imm[2:1]
    wire [8:0] cbimm  = {c_instr[12], c_instr[6:5], c_instr[2],
                         c_instr[11:10], c_instr[4:3], 1'b0};
    // c.lwsp uimm[5|4:2|7:6]
    wire [7:0] lwspimm = {c_instr[3:2], c_instr[12], c_instr[6:4], 2'b00};
    // c.swsp uimm[5:2|7:6]
    wire [7:0] swspimm = {c_instr[8:7], c_instr[12:9], 2'b00};

    // 立即数扩展（见文件头坑 2、3）
    wire [11:0] ciimm12 = {{6{ciimm[5]}}, ciimm};
    wire [19:0] ciimm20 = {{14{ciimm[5]}}, ciimm};
    // C.ADDI16SP 的立即数：nzimm[9]=inst[12]，nzimm[8:4]=inst[6:2]
    //   规范写作 nzimm[9|4|6|8:7|5]，即非顺序排布，最容易写错。
    //   权威实测：6105 (c.addi16sp sp,32) => nzimm=0x20。
    wire [11:0] nzimm16sp = {c_instr[12], c_instr[4:3], c_instr[5], c_instr[2],
                             c_instr[6], 6'b0};

    // CJ 立即数符号扩展到 21 位（J 型立即数字段 imm[20|10:1|11|19:12]）
    //   [!] 不扩展就直接引用 cjimm[19]/cjimm[18:11] 会越界 => X。
    wire [20:0] cjimm21 = {{9{cjimm[11]}}, cjimm};

    // J 型 32 位编码器：{imm[20|10:1|11|19:12](20), rd(5), opcode(7)}
    function [31:0] j_type(input [4:0] rd, input [20:0] imm21);
        begin
            j_type = {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, 7'b1101111};
        end
    endfunction

    // CB 立即数符号扩展到 13 位（B 型立即数字段共 13 位）
    wire [12:0] cbimm13 = {{4{cbimm[8]}}, cbimm};

    // B 型 32 位编码器：{imm[12|10:5](11), rs2(5), rs1(5), funct3(3), imm[4:1|11](5), opcode(7)}
    function [31:0] b_type(input [4:0] r2, input [4:0] r1,
                           input [2:0] f3, input [12:0] imm13);
        begin
            b_type = {imm13[12], imm13[10:5], r2, r1, f3,
                      imm13[4:1], imm13[11], 7'b1100011};
        end
    endfunction

    wire [11:0] lsimm12 = {5'b0, lsimm};
    wire [11:0] lwsp12  = {4'b0, lwspimm};
    wire [11:0] swsp12  = {4'b0, swspimm};

    localparam [6:0] OP_IMM    = 7'b0010011;
    localparam [6:0] OP_LOAD   = 7'b0000011;
    localparam [6:0] OP_STORE  = 7'b0100011;
    localparam [6:0] OP_REG    = 7'b0110011;
    localparam [6:0] OP_BRANCH = 7'b1100011;
    localparam [6:0] OP_JAL    = 7'b1101111;
    localparam [6:0] OP_JALR   = 7'b1100111;
    localparam [6:0] OP_LUI    = 7'b0110111;

    localparam [2:0] F_ADD = 3'b000;
    localparam [2:0] F_SLL = 3'b001;
    localparam [2:0] F_SRL = 3'b101;
    localparam [2:0] F_AND = 3'b111;
    localparam [2:0] F_XOR = 3'b100;
    localparam [2:0] F_OR  = 3'b110;
    localparam [2:0] F_SUB = 3'b000;
    localparam [2:0] F_LW  = 3'b010;
    localparam [2:0] F_BEQ = 3'b000;
    localparam [2:0] F_BNE = 3'b001;

    always @(*) begin
        r32     = 32'h00000013;
        illegal = 1'b0;
        is_jump = 1'b0;

        case (quad)
        // ================= quadrant 0 =================
        2'b00: begin
            case (op)
                3'b000: if (nzimm4spn == 10'd0) illegal = 1'b1;
                        else r32 = {2'b00, nzimm4spn, 5'd2, F_ADD, drd, OP_IMM};
                3'b010: r32 = {lsimm12, drs1, F_LW, drd, OP_LOAD};
                3'b110: r32 = {lsimm12[11:5], drs2, drs1, F_LW, lsimm12[4:0], OP_STORE};
                default: illegal = 1'b1;
            endcase
        end

        // ================= quadrant 1 =================
        2'b01: begin
            case (op)
                3'b000: if (rd == 5'd0) r32 = 32'h00000013;
                        else r32 = {ciimm12, rd, F_ADD, rd, OP_IMM};
                3'b001: begin r32     = j_type(5'd1, cjimm21);
                             is_jump = 1'b1; end
                3'b010: if (rd == 5'd0) illegal = 1'b1;
                        else r32 = {ciimm12, rd, F_ADD, 5'd0, OP_IMM};
                3'b011: begin
                    if (rd == 5'd2) begin
                        if (c_instr[12:2] == 11'b0) illegal = 1'b1;
                        else r32 = {nzimm16sp, 5'd2, F_ADD, 5'd2, OP_IMM};
                    end else if (rd == 5'd0) illegal = 1'b1;
                    else begin
                        if (ciimm == 6'd0) illegal = 1'b1;
                        else r32 = {ciimm20, rd, OP_LUI};
                    end
                end
                3'b100: begin
                    case (c_instr[11:10])
                        2'b00: r32 = {7'b0000000, c_instr[6:2], drd1, F_SRL, drd1, OP_IMM};
                        2'b01: r32 = {7'b0100000, c_instr[6:2], drd1, F_SRL, drd1, OP_IMM};
                        2'b10: r32 = {ciimm12, drd1, F_AND, drd1, OP_IMM};
                        2'b11: case (c_instr[6:5])
                                   2'b00: r32 = {7'b0100000, drs2, drd1, F_SUB, drd1, OP_REG};
                                   2'b01: r32 = {7'b0000000, drs2, drd1, F_XOR, drd1, OP_REG};
                                   2'b10: r32 = {7'b0000000, drs2, drd1, F_OR,  drd1, OP_REG};
                                   2'b11: r32 = {7'b0000000, drs2, drd1, F_AND, drd1, OP_REG};
                               endcase
                    endcase
                end
                3'b101: begin r32     = j_type(5'd0, cjimm21);
                             is_jump = 1'b1; end
                3'b110: begin r32     = b_type(drs2, drs1, F_BEQ, cbimm13);
                             is_jump = 1'b1; end
                3'b111: begin r32     = b_type(drs2, drs1, F_BNE, cbimm13);
                             is_jump = 1'b1; end
            endcase
        end

        // ================= quadrant 2 =================
        2'b10: begin
            case (op)
                3'b000: if (rd == 5'd0) illegal = 1'b1;
                        else r32 = {7'b0000000, c_instr[6:2], rd, F_SLL, rd, OP_IMM};
                3'b010: if (rd == 5'd0) illegal = 1'b1;
                        else r32 = {lwsp12, 5'd2, F_LW, rd, OP_LOAD};
                3'b100: begin
                    // [!] 实测（GNU as）这五条只靠 bit12 + rs2 + rd 区分，
                    //     不是靠 inst[11:10]：
                    //       mv t0,t1  = 829a -> b12=0, rs2=00110
                    //       add t0,t1 = 929a -> b12=1, rs2=00110   ← 与 mv 只差 bit12！
                    //       jr  t0    = 8282 -> b12=0, rs2=00000
                    //       jalr t0   = 9282 -> b12=1, rs2=00000
                    //       ebreak    = 9002 -> b12=1, rs2=00000, rd=00000
                    //     我先前按 inst[11:10] 分派，把 c.add 判成了 c.mv。
                    // 实测全表（GNU as）：
                    //   mv t0,t1=829a b12=0 rs2=00110   jr t0   =8282 b12=0 rs2=00000
                    //   add t0,t1=929a b12=1 rs2=00110  jalr t0=9282 b12=1 rs2=00000
                    //   ebreak  =9002 b12=1 rs2=00000 rd=00000
                    //   add a0,a1=952e b12=1 rs2=01011（inst[11:10]=01，仍是 ADD）
                    // => b12 是第一判别位；rs2==0 时按 rd 区分 JR/JALR/EBREAK。
                    if (c_instr[12] == 1'b0) begin
                        if (rs2 == 5'd0) begin                     // c.jr
                            if (rd == 5'd0) illegal = 1'b1;
                            else begin
                                r32     = {12'd0, rd, 3'b000, 5'd0, OP_JALR};
                                is_jump = 1'b1;
                            end
                        end else r32 = {7'b0000000, rs2, 5'd0, F_ADD, rd, OP_REG};  // c.mv
                    end else begin
                        if (rs2 != 5'd0) begin                     // c.add
                            r32 = {7'b0000000, rs2, rd, F_ADD, rd, OP_REG};
                        end else if (rd == 5'd0) r32 = 32'h00100073;   // c.ebreak
                        else begin                                  // c.jalr
                            r32     = {12'd0, rd, 3'b000, 5'd1, OP_JALR};
                            is_jump = 1'b1;
                        end
                    end
                end
                3'b110: r32 = {swsp12[11:5], rs2, 5'd2, F_LW, swsp12[4:0], OP_STORE};
                default: illegal = 1'b1;
            endcase
        end

        default: illegal = 1'b1;
        endcase
    end
endmodule