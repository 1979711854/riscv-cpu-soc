`timescale 1ns/1ps
// 验证 uart_tx FIFO：连续写 600 字符（间隔远小于发送时间，总量 > 旧版 128 深），
// 应全部发出、内容按顺序正确（模拟 CoreMark report 连续输出不丢、不越界）。
module tb_uart_fifo;
    reg clk = 0, resetn = 0;
    reg [7:0] tx_data;
    reg tx_start;
    wire tx, busy;

    uart_tx uut(
        .clk(clk), .resetn(resetn),
        .tx_data(tx_data), .tx_start(tx_start),
        .tx(tx), .busy(busy)
    );

    always #18.5185 clk = ~clk;   // 27MHz，周期 37.037ns

    // ---- 接收解码（27MHz 采样，234 分频，采样在 bit 中间）----
    reg        prev_tx;
    reg        sampling;
    reg [11:0] sample_cnt;
    reg [2:0]  rx_index;
    reg [7:0]  rx_byte;
    integer    rx_count = 0;
    integer    content_err = 0;

    always @(posedge clk) begin
        if (!resetn) begin
            sampling = 0; rx_index = 0; sample_cnt = 0; rx_byte = 0; prev_tx = 1;
        end else begin
            if (!sampling) begin
                if (prev_tx && !tx) begin
                    sampling   = 1;
                    sample_cnt = 12'd351;   // 起始位后 1.5 bit → data[0] 中间
                    rx_index   = 0;
                end
            end else begin
                if (sample_cnt == 0) begin
                    rx_byte[rx_index] = tx;   // 阻塞赋值，立即生效，检查时 rx_byte 完整
                    if (rx_index == 3'd7) begin
                        sampling = 0;
                        if (rx_byte != rx_count[7:0]) begin
                            content_err = content_err + 1;
                            $display("ERR[%0d]: 期望 0x%02x, 实际 0x%02x",
                                     rx_count, rx_count[7:0], rx_byte);
                        end
                        rx_count = rx_count + 1;
                    end else begin
                        rx_index   = rx_index + 1;
                        sample_cnt = 12'd234;
                    end
                end else begin
                    sample_cnt = sample_cnt - 1;
                end
            end
            prev_tx = tx;
        end
    end

    integer i;
    initial begin
        #100 resetn = 1;
        #200;
        // 连续写 600 字符（低 8 位 0..255 循环），间隔 5 拍
        for (i = 0; i < 600; i = i + 1) begin
            @(posedge clk);
            tx_data  = i[7:0];
            tx_start = 1'b1;
            @(posedge clk);
            tx_start = 1'b0;
            repeat (5) @(posedge clk);
        end
        // 等待发完：600 × 2340 拍 = 1404000 拍 + 余量
        repeat (1500000) @(posedge clk);
        $display("----------------------------------------");
        $display("发送 600 字符, 收到 %0d 字符, 内容错误 %0d 个", rx_count, content_err);
        if (rx_count == 600 && content_err == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
