`timescale 1ns/1ps
// ============================================================================
// uart_rx 定向单测
// ----------------------------------------------------------------------------
// 按真实波特率时序（115200 @ 100MHz 仿真时钟，位宽 2340ns）向 rx 打波形，验证：
//   A 单字节收发          B 连续多字节保序
//   C 停止位为低（帧错误）不推入 FIFO
//   D FIFO 深度 16：灌 20 个只保留前 16 个，且顺序正确
//   E FIFO 空时读不该乱动指针
// ============================================================================
module tb_uart_rx;
    reg         clk = 1'b0;
    reg         resetn;
    reg         rx;
    reg         ack;
    wire [31:0] rdata;

    always #5 clk = ~clk;          // 100MHz

    uart_rx u_rx (
        .clk(clk), .resetn(resetn), .ack(ack), .rdata(rdata), .rx(rx)
    );

    localparam BIT_NS = 2340;      // 234 个 10ns 时钟 = 115200 波特
    integer errors = 0;

    // ---- 发一个字节（8N1，LSB 先发）----
    task send_byte;
        input [7:0] b;
        input       bad_stop;      // 1 = 故意把停止位拉低，制造帧错误
        integer k;
        begin
            rx = 1'b0; #(BIT_NS);                       // 起始位
            for (k = 0; k < 8; k = k + 1) begin
                rx = b[k]; #(BIT_NS);                   // 数据位 LSB first
            end
            rx = bad_stop ? 1'b0 : 1'b1; #(BIT_NS);     // 停止位
            rx = 1'b1;
            #(BIT_NS);                                  // 让接收机回到空闲
        end
    endtask

    // ---- 读并弹出一个字节，比对期望值 ----
    // [重点] ack 必须在【negedge 之后】驱动。
    //   若写成 "ack=1; @(posedge clk); ack=0;"，任务在 posedge 恢复执行与
    //   uart_rx 里 always 块采样是同一时间步内的不确定顺序，ack 可能被提前
    //   清零而丢掉这次弹出（表现为 FIFO 头永远不动）。真实硬件里 ack 来自
    //   同步逻辑、天然对齐时钟，所以这是测试台自身的竞态。
    task check_pop;
        input [7:0]   exp;
        input [8*40-1:0] name;
        begin
            @(negedge clk);                     // 远离 posedge，组合读已稳定
            if (rdata[31] !== 1'b1 || rdata[7:0] !== exp) begin
                $display("FAIL  %0s: want valid=1 data=0x%02x, got rdata=0x%08x",
                         name, exp, rdata);
                errors = errors + 1;
            end else begin
                $display("ok    %0s: data=0x%02x valid=1", name, exp);
            end
            ack = 1'b1;                         // 下个 posedge 必定采到
            @(negedge clk);
            ack = 1'b0;
        end
    endtask

    task check_empty;
        input [8*40-1:0] name;
        begin
            @(negedge clk);
            if (rdata[31] !== 1'b0) begin
                $display("FAIL  %0s: want valid=0, got rdata=0x%08x", name, rdata);
                errors = errors + 1;
            end else begin
                $display("ok    %0s: valid=0 (FIFO empty)", name);
            end
        end
    endtask

    integer i;
    initial begin
        resetn = 1'b0; rx = 1'b1; ack = 1'b0;
        #100; resetn = 1'b1; #100;

        $display("---- A: single byte ----");
        send_byte(8'hA5, 1'b0);
        check_pop(8'hA5, "A: single byte 0xA5");
        check_empty("A: empty after pop");

        $display("---- B: back-to-back bytes, order preserved ----");
        send_byte(8'h00, 1'b0);
        send_byte(8'hFF, 1'b0);
        send_byte(8'h55, 1'b0);
        check_pop(8'h00, "B: 1st");
        check_pop(8'hFF, "B: 2nd");
        check_pop(8'h55, "B: 3rd");
        check_empty("B: empty after pops");

        $display("---- C: framing error (stop bit low) ----");
        send_byte(8'h3C, 1'b1);          // bad stop
        check_empty("C: framing error dropped");

        $display("---- D: FIFO depth (push 20, keep first 16) ----");
        for (i = 0; i < 20; i = i + 1) send_byte(i[7:0], 1'b0);
        for (i = 0; i < 16; i = i + 1) check_pop(i[7:0], "D: in-order");
        check_empty("D: 17th..20th dropped (depth 16)");

        $display("---- E: repeated reads on empty FIFO ----");
        for (i = 0; i < 3; i = i + 1) begin
            @(negedge clk); ack = 1'b1;
            @(negedge clk); ack = 1'b0;
        end
        check_empty("E: still empty after reads");
        send_byte(8'h7E, 1'b0);
        check_pop(8'h7E, "E: still receives after idle reads");

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d) ===", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("=== TIMEOUT ===");
        $finish;
    end
endmodule
