`timescale 1ns/1ps
module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);
    always @(*) begin
        case (instr[6:0])
            7'b0010011, 7'b0000011, 7'b1100111:  // I-type: OP_IMM, OP_LOAD, OP_JALR
                imm = {{20{instr[31]}}, instr[31:20]};
            7'b0100011:                          // S-type: OP_STORE
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            7'b1100011:                          // B-type: OP_BRANCH
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            7'b0110111, 7'b0010111:              // U-type: OP_LUI, OP_AUIPC
                imm = {instr[31:12], 12'b0};
            7'b1101111:                          // J-type: OP_JAL
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm = 32'd0;
        endcase
    end
endmodule
