`timescale 1ns/1ps
module control (
    input  wire [31:0] instr,
    output reg         reg_write,
    output reg         alu_a_sel,   // 0 = rs1, 1 = pc
    output reg         alu_b_sel,   // 0 = rs2, 1 = imm
    output reg  [4:0]  alu_op,
    output reg         mem_read,
    output reg         mem_write,
    output reg         branch,
    output reg         jump,
    output reg         jump_reg,
    output reg  [1:0]  wb_sel,      // 0 = alu, 1 = mem, 2 = pc+4, 3 = imm(lui)
    output reg         sys_ebreak,  // EBREAK：置 1（既作停机钩子，也产生 mcause=3）
    // ---- CSR 指令（Zicsr）----
    output reg         is_csr,      // 本拍是 CSR 指令
    output reg  [11:0] csr_addr,    // CSR 编号
    output reg  [1:0]  csr_cmd,     // 01=读写(RW) 10=置位(RS) 11=清位(RC)
    output reg         csr_imm,     // 1 = 立即数形式（源在 instr[19:15]，零扩展）
    // ---- A 扩展原子指令----
    output reg         is_amo,      // 本拍是 AMO / LR / SC
    output reg  [4:0]  amo_funct5,  // AMO 操作码 / LR=00010 / SC=00011
    // ---- 系统指令 ----
    output reg         sys_ecall,   // ECALL  → mcause=11
    output reg         sys_mret,    // MRET   → 跳 mepc，恢复 mstatus.MIE
    // ---- 非法指令 ----
    output reg         illegal      // 未定义 opcode，或 SYSTEM 下的未定义子编码
);
    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];

    always @(*) begin
        reg_write = 1'b0;
        alu_a_sel = 1'b0;
        alu_b_sel = 1'b0;
        alu_op    = 5'd0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        branch    = 1'b0;
        jump      = 1'b0;
        jump_reg   = 1'b0;
        wb_sel     = 2'b00;
        sys_ebreak = 1'b0;
        is_csr     = 1'b0;
        csr_addr   = 12'd0;
        csr_cmd    = 2'b00;
        csr_imm    = 1'b0;
        is_amo     = 1'b0;
        amo_funct5 = 5'd0;
        sys_ecall  = 1'b0;
        sys_mret   = 1'b0;
        illegal    = 1'b0;

        case (opcode)
            7'b0110011: begin  // OP_REG
                reg_write = 1'b1;
                if (funct7 == 7'b0000001) begin  // M 扩展
                    case (funct3)
                        3'b000: alu_op = 5'd10;  // MUL
                        3'b001: alu_op = 5'd11;  // MULH
                        3'b010: alu_op = 5'd12;  // MULHSU
                        3'b011: alu_op = 5'd13;  // MULHU
                        3'b100: alu_op = 5'd14;  // DIV
                        3'b101: alu_op = 5'd15;  // DIVU
                        3'b110: alu_op = 5'd16;  // REM
                        3'b111: alu_op = 5'd17;  // REMU
                        default: alu_op = 5'd0;
                    endcase
                end else begin
                    case (funct3)
                        3'b000: alu_op = funct7[5] ? 5'd1 : 5'd0;  // ADD / SUB
                        3'b001: alu_op = 5'd2;                     // SLL
                        3'b010: alu_op = 5'd3;                     // SLT
                        3'b011: alu_op = 5'd4;                     // SLTU
                        3'b100: alu_op = 5'd5;                     // XOR
                        3'b101: alu_op = funct7[5] ? 5'd7 : 5'd6;  // SRA / SRL
                        3'b110: alu_op = 5'd8;                     // OR
                        3'b111: alu_op = 5'd9;                     // AND
                        default: alu_op = 5'd0;
                    endcase
                end
            end

            7'b0010011: begin  // OP_IMM
                reg_write = 1'b1;
                alu_b_sel = 1'b1;
                case (funct3)
                    3'b000: alu_op = 5'd0;                     // ADDI
                    3'b001: alu_op = 5'd2;                     // SLLI
                    3'b010: alu_op = 5'd3;                     // SLTI
                    3'b011: alu_op = 5'd4;                     // SLTIU
                    3'b100: alu_op = 5'd5;                     // XORI
                    3'b101: alu_op = funct7[5] ? 5'd7 : 5'd6;  // SRAI / SRLI
                    3'b110: alu_op = 5'd8;                     // ORI
                    3'b111: alu_op = 5'd9;                     // ANDI
                    default: alu_op = 5'd0;
                endcase
            end

            7'b0000011: begin  // OP_LOAD
                reg_write = 1'b1;
                alu_b_sel = 1'b1;
                mem_read  = 1'b1;
                wb_sel    = 2'b01;
            end

            7'b0100011: begin  // OP_STORE
                alu_b_sel = 1'b1;
                mem_write = 1'b1;
            end

            // ------------------------------------------------------------------
            //7'b0101111: AMO —— A 扩展原子内存操作（RV32A）
            //   funct3 必为010（32位）；011（64位）本设计判非法（RV32 无双字）。
            //   地址来自 rs1（不是 rs1+imm），操作数 2 是 rs2 —— 与 load/store 不同，
            //   所以 alu_b_sel 不置位（addr 直接在 core.v 里取 rs1）。
            //   wb_sel 留 alu(00)：真正的写回值由 amo_unit 的 wb_data 提供，
            //   core.v 里有独立的 mux 选择它。
            // ------------------------------------------------------------------
            7'b0101111: begin  // AMO
                is_amo     = 1'b1;
                amo_funct5 = instr[31:27];
                reg_write  = 1'b1;   // AMO/LR/SC 都写 rd
                if (funct3 == 2'b11) illegal = 1'b1;   // 不支持 64 位
            end

            7'b1100011: begin  // OP_BRANCH
                branch = 1'b1;
            end

            7'b1101111: begin  // OP_JAL
                reg_write = 1'b1;
                jump      = 1'b1;
                wb_sel    = 2'b10;
            end

            7'b1100111: begin  // OP_JALR
                reg_write = 1'b1;
                jump_reg  = 1'b1;
                alu_b_sel = 1'b1;
                wb_sel    = 2'b10;
            end

            7'b0110111: begin  // OP_LUI
                reg_write = 1'b1;
                wb_sel    = 2'b11;
            end

            7'b0010111: begin  // OP_AUIPC
                reg_write = 1'b1;
                alu_a_sel = 1'b1;
                alu_b_sel = 1'b1;
                alu_op    = 5'd0;
            end

            7'b0001111: begin  // MISC-MEM: FENCE (funct3=000) / FENCE.I (funct3=001)
                // 两者都实现为 NOP，此处等价处理：
                //   * 本设计没有 I/D Cache，也就没有需要"刷"的写缓冲或 Cache 行；
                //   * 存储器已统一（rtl/mem/unified_mem.v），store 对后续取指天然可见，
                //     FENCE.I 的语义已经由硬件结构本身保证。
                // RISC-V 规范允许无 Cache 的实现把 FENCE/FENCE.I 当作 NOP。
                // 所有控制信号保持初值 0 -> 该指令流过流水线但不提交任何状态。
            end

            7'b1110011: begin  // SYSTEM
                // ------------------------------------------------------------------
                // funct3 = 000 → 特权指令，由 imm[11:0] 区分
                //   ECALL(0x000) / EBREAK(0x001) / MRET(0x302)；其余为非法
                // funct3 = 001/010/011 → CSRRW / CSRRS / CSRRC      （寄存器形式）
                // funct3 = 101/110/111 → CSRW I / CSRRSI / CSRRCI   （立即数形式）
                // funct3 = 100         → 保留，非法
                // ------------------------------------------------------------------
                if (funct3 == 3'b000) begin
                    case (instr[31:20])
                        12'h000: sys_ecall  = 1'b1;   // → mcause = 11（M 模式 ECALL）
                        12'h001: sys_ebreak = 1'b1;   // → mcause = 3
                        12'h302: sys_mret   = 1'b1;   // → 跳 mepc
                        default: illegal    = 1'b1;
                    endcase
                end else if (funct3 == 3'b100) begin
                    illegal = 1'b1;
                end else begin
                    // CSR 指令：rd 拿旧值走正常写回，所以 reg_write = 1
                    // （rd = x0 时寄存器堆本身不写，无需在此特判）
                    is_csr    = 1'b1;
                    reg_write = 1'b1;
                    csr_addr  = instr[31:20];
                    csr_cmd   = funct3[1:0];   // 01=RW, 10=RS, 11=RC
                    csr_imm   = funct3[2];     // 1 = 立即数（zimm 在 instr[19:15]）
                end
            end

            default: begin
                // 未定义的 opcode → 非法指令。
                //
                // [!] 例外：全零字按气泡处理，不报非法。
                //   原因：取指是同步读、1 拍延迟，
                //   复位后第一拍发出的地址，数据要下一拍才回来，所以那一拍
                //   IF/ID 锁存到的是存储器的复位值 0x00000000。若把 0 判为非法
                //   指令，上电第一拍就会 trap（pc 被拉到 mtvec），程序直接跑飞。
                //   现象极具迷惑性：riscv-tests 的 add/beq/jal 全部 TIMEOUT 且
                //   pc 停在启动早期，看起来像流水线坏了。
                //
                //   规范上 0x00000000 确实不是合法指令，但本设计的流水线填充期
                //   会自然产生它（旧设计 default 是 no-op，所以从没暴露）。
                //   改动取指时序风险更高（项目约定文档 明言那段承重），故用这条最小
                //   偏离换取稳定：真正的非法 opcode（非 0）仍然照常报 illegal。
                if (instr != 32'd0) illegal = 1'b1;
            end
        endcase
    end
endmodule
