`timescale 1ns/1ps
// ============================================================================
// 演示程序端到端测试台 —— 基础任务③「外设系统集成」的验收
// ----------------------------------------------------------------------------
// 跑整个 SoC（core + mem_bus + gpio + uart_tx + uart_rx），按 scripts/demo/demo.c
// 约定的交互序列逐一比对：
//   1 上电 banner + 初始按键状态，LED 全灭
//   2 按下 KEY1  -> 打印 KEY=0x01 LED=0x01，LED 点亮
//   3 松开       -> 打印 KEY=0x00 LED=0x00
//   4 按下 KEY4  -> 打印 KEY=0x08 LED=0x08
//   5 串口收到 'A' -> 回显 RX=A
//   6 串口收到 '1' -> 回显 RX=1
//   7 done 未被拉起（程序在死循环里，没执行 EBREAK）
//
// 串口 TX 由测试台按 115200 8N1 解码成字节流；串口 RX 由 send_uart_byte 按
// 真实波特率波形驱动。
//
// [重点] 换行一律用 CRLF 常量拼，不要在字符串字面量里写 \r ——
//   Verilog 的转义只有 \n \t \\ \" 和 \ddd，没有 \r；iverilog 会把 \r 当成
//   字面字符 'r'，期望串就永远对不上。这个坑本工程踩过。
// ============================================================================

// 统一存储器行为模型（指令+数据共用一块）
`include "mem_model.vh"

module tb_demo;
    reg         clk = 1'b0;
    reg         resetn;
    reg  [7:0]  key;
    reg         uart_rx;
    wire [7:0]  led;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;

    always #5 clk = ~clk;          // 100MHz 仿真时钟

    cpu_top u_soc (
        .clk     (clk),
        .resetn  (resetn),
        .pc      (pc),
        .uart_tx (uart_tx),
        .uart_rx (uart_rx),
        .led     (led),
        .key     (key),
        .done    (done)
    );

    localparam BIT_NS = 2340;      // 115200 @ 100MHz 仿真时钟
    localparam [15:0] CRLF = 16'h0D0A;

    // ------------------------------------------------------------------
    // UART TX 解码：下降沿=起始位 -> 等 1.5 位到 bit0 中点 -> 每 1 位采一个
    // 收到的字节从【低位】压入 rxtext，于是"最近 N 字节" = rxtext[8*N-1:0]，
    // 且顺序与字符串字面量一致，可以直接用 === 比较。
    // ------------------------------------------------------------------
    reg [8*512-1:0] rxtext  = 0;
    integer         rxcount = 0;
    reg  [7:0]      rxb;
    integer         bi;

    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS / 2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rxb[bi] = uart_tx;
                #(BIT_NS);
            end
            rxtext  = {rxtext[8*512-9:0], rxb};
            rxcount = rxcount + 1;
        end
    end

    // ------------------------------------------------------------------
    // 激励与比对
    // ------------------------------------------------------------------
    integer errors = 0;

    task wait_rx;
        input integer n;
        integer target;
        begin
            target = rxcount + n;
            while (rxcount < target) @(negedge clk);
        end
    endtask

    task send_uart_byte;
        input [7:0] v;
        integer j;
        begin
            uart_rx = 1'b0; #(BIT_NS);                 // 起始位
            for (j = 0; j < 8; j = j + 1) begin
                uart_rx = v[j]; #(BIT_NS);             // 数据位 LSB first
            end
            uart_rx = 1'b1; #(BIT_NS);                 // 停止位
        end
    endtask

    // 所有按键行都是 19 字节："KEY=0xNN LED=0xNN" + CRLF
    task check_line19;
        input [8*40-1:0] name;
        input [8*19-1:0] exp;
        begin
            if (rxtext[8*19-1:0] === exp)
                $display("ok    %0s", name);
            else begin
                $display("FAIL  %0s", name);
                $display("      got (hex, last 24B): %048x", rxtext[8*24-1:0]);
                $display("      want(hex):           %038x", exp);
                errors = errors + 1;
            end
        end
    endtask

    task check_led;
        input [8*40-1:0] name;
        input [7:0]      exp;
        begin
            if (led === exp)
                $display("ok    %0s: LED=0x%02x", name, led);
            else begin
                $display("FAIL  %0s: LED=0x%02x，期望 0x%02x", name, led, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        resetn  = 1'b0;
        key     = 8'hFF;          // 全部松开
        uart_rx = 1'b1;
        #100;
        resetn = 1'b1;

        $display("---- 1. 上电 ----");
        // banner(22) + 初始按键状态(19)
        wait_rx(41);
        if (rxtext[8*41-1:0] === {"RV32I SoC demo ready", CRLF, "KEY=0x00 LED=0x00", CRLF})
            $display("ok    1: banner + 初始状态");
        else begin
            $display("FAIL  1: banner/初始状态");
            $display("      got (hex, last 48B): %096x", rxtext[8*48-1:0]);
            errors = errors + 1;
        end
        check_led("1: 上电应全灭", 8'h00);

        $display("---- 2. 按下 KEY1 ----");
        key = 8'hFE;                                  // key[0] = 0 -> 按下
        wait_rx(19);
        check_line19("2: 按下 KEY1", {"KEY=0x01 LED=0x01", CRLF});
        check_led("2: LED 跟随按键", 8'h01);

        $display("---- 3. 松开 ----");
        key = 8'hFF;
        wait_rx(19);
        check_line19("3: 松开", {"KEY=0x00 LED=0x00", CRLF});
        check_led("3: LED 熄灭", 8'h00);

        $display("---- 4. 按下 KEY4 ----");
        key = 8'hF7;                                  // key[3] = 0 -> 按下
        wait_rx(19);
        check_line19("4: 按下 KEY4", {"KEY=0x08 LED=0x08", CRLF});
        check_led("4: LED 跟随按键", 8'h08);

        $display("---- 5. 串口发 'A' ----");
        send_uart_byte(8'h41);
        wait_rx(6);
        if (rxtext[8*6-1:0] === {"RX=A", CRLF})
            $display("ok    5: 串口回显 RX=A");
        else begin
            $display("FAIL  5: 串口回显，got (hex) %012x", rxtext[8*6-1:0]);
            errors = errors + 1;
        end

        $display("---- 6. 串口发 '1' ----");
        send_uart_byte(8'h31);
        wait_rx(6);
        if (rxtext[8*6-1:0] === {"RX=1", CRLF})
            $display("ok    6: 串口回显 RX=1");
        else begin
            $display("FAIL  6: 串口回显，got (hex) %012x", rxtext[8*6-1:0]);
            errors = errors + 1;
        end

        $display("---- 7. 结束标志 ----");
        if (done === 1'b0)
            $display("ok    7: done 未被拉起（程序仍在主循环）");
        else begin
            $display("FAIL  7: done 意外拉高");
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL (%0d 处) ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #500000000;
        $display("=== TIMEOUT (pc=0x%h, rxcount=%0d) ===", pc, rxcount);
        $finish;
    end
endmodule
