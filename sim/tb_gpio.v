`timescale 1ns/1ps
// ============================================================================
// gpio 定向单测
//   A 复位后 LED 全灭、按键回读为全 1（松开）
//   B 写 LED 生效，且能被读回
//   C 按键输入经 2 级同步后出现在 rdata[15:8]，且是【原始电平】（低有效）
//   D 写回读一致性（写什么读回什么）
// ============================================================================
module tb_gpio;
    reg         clk = 1'b0;
    reg         resetn;
    reg         we;
    reg  [31:0] wdata;
    reg  [7:0]  key;
    wire [31:0] rdata;
    wire [7:0]  led;

    always #5 clk = ~clk;          // 100MHz

    gpio u_gpio (
        .clk(clk), .resetn(resetn), .we(we), .wdata(wdata),
        .rdata(rdata), .led(led), .key(key)
    );

    integer errors = 0;

    // 同步驱动：在 negedge 之后给出，避免与 posedge 采样打架
    task write_led;
        input [7:0] v;
        begin
            @(negedge clk); we = 1'b1; wdata = {24'd0, v};
            @(negedge clk); we = 1'b0;
        end
    endtask

    task check;
        input [8*40-1:0] name;
        input            cond;
        begin
            if (cond) $display("ok    %0s", name);
            else begin
                $display("FAIL  %0s: led=0x%02x key=0x%02x rdata=0x%08x",
                         name, led, key, rdata);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        resetn = 1'b0; we = 1'b0; wdata = 32'd0; key = 8'hFF;
        #100; resetn = 1'b1;

        $display("---- A: reset state ----");
        @(negedge clk);
        check("A: led all off after reset", led === 8'h00);
        check("A: keys read as 0xFF (all released)", rdata[15:8] === 8'hFF);

        $display("---- B: write LED ----");
        write_led(8'hA5);
        @(negedge clk);
        check("B: led pin follows written value", led === 8'hA5);
        check("B: led readable back", rdata[7:0] === 8'hA5);

        $display("---- C: key input (active low) ----");
        key = 8'h0F;                     // 高 4 位按下
        repeat (3) @(negedge clk);       // 等两级同步器跟上
        check("C: keys sampled raw into [15:8]", rdata[15:8] === 8'h0F);
        check("C: LED unaffected by key change", led === 8'hA5);

        key = 8'hFF;
        repeat (3) @(negedge clk);
        check("C: release reflected too", rdata[15:8] === 8'hFF);

        $display("---- D: write/read consistency ----");
        write_led(8'h3C);
        @(negedge clk);
        check("D: 0x3C written and read back", led === 8'h3C && rdata[7:0] === 8'h3C);
        write_led(8'h00);
        @(negedge clk);
        check("D: back to 0x00", led === 8'h00 && rdata[7:0] === 8'h00);

        // we=0 期间 wdata 变化不应影响 LED
        wdata = 32'hFF;
        repeat (3) @(negedge clk);
        check("D: wdata ignored while we=0", led === 8'h00);

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d) ===", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("=== TIMEOUT ===");
        $finish;
    end
endmodule
