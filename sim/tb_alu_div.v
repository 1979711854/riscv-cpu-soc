`timescale 1ns/1ps
module alu_div_test;
    reg [31:0] a, b;
    wire [31:0] r_signed, r_signed2, r_rem;
    assign r_signed  = $signed(a) / $signed(b);
    assign r_signed2 = a / b;
    assign r_rem     = $signed(a) % $signed(b);
    integer i;
    initial begin
        a = 32'hFFFFFFEC; b = 32'd6;   // -20 / 6
        #1 $display("signed   -20/6  = %0d (0x%h)", $signed(r_signed), r_signed);
        $display("unsigned -20/6  = %0d (0x%h)", $signed(r_signed2), r_signed2);
        $display("rem      -20%%6  = %0d (0x%h)", $signed(r_rem), r_rem);
        a = 32'd20; b = 32'hFFFFFFFA;   // 20 / -6
        #1 $display("signed   20/-6  = %0d (0x%h)", $signed(r_signed), r_signed);
        $finish;
    end
endmodule
