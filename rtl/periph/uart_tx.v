`timescale 1ns/1ps
// UART TX：8N1，115200 波特。DIV = f_clk/115200，由上层传入
// （27MHz→234，误差 0.16%；45MHz→390）：见 rtl/top/cpu_top.v 的 UART_DIV。
// 带 1024 字节发送 FIFO：tx_start 把字符写入 FIFO，发送机空闲时自动取下一个。
// 深度覆盖 CoreMark 连续 report 输出（约 440 字节），避免 busy 丢字符 / FIFO 溢出。
// 标准 2^N FIFO：指针 11 位（2^10 深 + 1 位区分空满），索引取低 10 位，无越界。
module uart_tx (
    input  wire        clk,
    input  wire        resetn,
    input  wire [7:0]  tx_data,
    input  wire        tx_start,   // 1 拍脉冲：写一个字符进 FIFO
    output reg         tx,
    output reg         busy        // FIFO 满
);
    parameter [9:0] DIV = 10'd234;    // f_clk / 115200：27MHz→234，45MHz→390

    // ---- 发送 FIFO：1024 深 × 8 bit ----
    reg [7:0] fifo [0:1023];
    reg [10:0] wr_ptr, rd_ptr;                       // 11 位指针，回绕
    wire [9:0]  wr_idx = wr_ptr[9:0];
    wire [9:0]  rd_idx = rd_ptr[9:0];
    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = (wr_ptr[10] != rd_ptr[10]) && (wr_ptr[9:0] == rd_ptr[9:0]);

    // ---- 发送状态机 ----
    reg [9:0] div_cnt;
    reg [3:0] bit_cnt;
    reg [9:0] shift;                    // [9]=stop [8:1]=data[7:0] [0]=start
    reg       sending;

    // 写 FIFO
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            wr_ptr <= 11'd0;
        end else if (tx_start && !fifo_full) begin
            fifo[wr_idx] <= tx_data;
            wr_ptr <= wr_ptr + 11'd1;
        end
    end

    // 发送状态机（含读 FIFO）
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            tx      <= 1'b1;
            sending <= 1'b0;
            div_cnt <= 10'd0;
            bit_cnt <= 4'd0;
            shift   <= 10'd0;
            rd_ptr  <= 11'd0;
        end else begin
            if (!sending) begin
                if (!fifo_empty) begin
                    // 取一个字节，发起始位
                    shift   <= {1'b1, fifo[rd_idx], 1'b0};
                    rd_ptr  <= rd_ptr + 11'd1;
                    bit_cnt <= 4'd0;
                    div_cnt <= 10'd0;
                    sending <= 1'b1;
                    tx      <= 1'b0;
                end else begin
                    tx <= 1'b1;         // 空闲高电平
                end
            end else begin
                if (div_cnt == DIV - 1) begin
                    div_cnt <= 10'd0;
                    if (bit_cnt == 4'd9) begin
                        // 10 位发完，回到空闲
                        sending <= 1'b0;
                        tx      <= 1'b1;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                        tx      <= shift[bit_cnt + 1'b1];
                    end
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end

    always @(*) busy = fifo_full;
endmodule
