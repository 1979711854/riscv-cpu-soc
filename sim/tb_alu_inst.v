`timescale 1ns/1ps
module alu_inst_test;
    reg [31:0] a, b;
    reg [4:0] op;
    wire [31:0] result;
    alu u_alu (.a(a), .b(b), .alu_op(op), .result(result));
    initial begin
        a = 32'hFFFFFFEC; b = 32'd6; op = 5'd14;  // DIV -20/6
        #1 $display("DIV  -20/6   = %0d (0x%h)", $signed(result), result);
        a = 32'hFFFFFFEC; b = 32'd6; op = 5'd16;  // REM -20%6
        #1 $display("REM  -20%%6   = %0d (0x%h)", $signed(result), result);
        a = 32'd20; b = 32'hFFFFFFFA; op = 5'd14; // DIV 20/-6
        #1 $display("DIV  20/-6   = %0d (0x%h)", $signed(result), result);
        a = 32'hFFFFFFEC; b = 32'hFFFFFFFA; op = 5'd14; // DIV -20/-6
        #1 $display("DIV  -20/-6  = %0d (0x%h)", $signed(result), result);
        a = 32'h80000000; b = 32'hFFFFFFFF; op = 5'd14; // DIV overflow
        #1 $display("DIV  ovf      = 0x%h", result);
        a = 32'hFFFFFFFF; b = 32'd0; op = 5'd14; // DIV by zero
        #1 $display("DIV  /0       = 0x%h", result);
        $finish;
    end
endmodule
