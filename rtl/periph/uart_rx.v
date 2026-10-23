`timescale 1ns/1ps
// ============================================================================
// uart_rx —— UART 接收，8N1，115200 波特（与 uart_tx.v 同一分频，DIV 由上层传入）
// ----------------------------------------------------------------------------
// 采样策略：检测起始位下降沿后，等半个位时间到起始位中点复检一次
// （确认不是毛刺），之后每一个位时间在数据位中点采样，最后在停止位
// 中点校验为高电平。全程在中点采样，对发送端时钟偏差的容忍度最大。
//
// 映射（地址译码在 mem_bus）：
//   0x8000_000C  R  {valid[31], 23'b0, data[7:0]}
//      valid=1 表示 FIFO 非空、data 有效。
// [!] 读这个地址会弹出一个字节（与 UART 的 RBR 语义一致）。
//        所以轮询时务必只读一次：
//            v = UART_RX;  if (v >> 31) c = v & 0xFF;
//        不要写成 while(!(UART_RX>>31)); —— 那会在判断里就把字节吃掉。
//
// 带 16 深 FIFO：CPU 轮询间隔大时不会丢字符。
// ============================================================================
module uart_rx (
    input  wire        clk,
    input  wire        resetn,

    // ---- 总线侧 ----
    input  wire        ack,        // 读选通：弹出 FIFO 头部
    output wire [31:0] rdata,

    // ---- 引脚 ----
    input  wire        rx          // 空闲为高
);
    parameter  [9:0] DIV  = 10'd234;      // f_clk / 115200：27MHz→234，45MHz→390
    localparam [9:0] HALF = DIV / 2;      // 位正中对齐（参数化，别写死 117）

    // ------------------------------------------------------------------
    // 输入同步（2 级）
    // ------------------------------------------------------------------
    reg rx_s1, rx_s2;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin rx_s1 <= 1'b1; rx_s2 <= 1'b1; end
        else         begin rx_s1 <= rx;   rx_s2 <= rx_s1; end
    end
    // 起始位下降沿。rx_s1 比 rx_s2 新一拍，所以下降沿表现为
    // "rx_s1 已经变低、rx_s2 还没跟上" = !rx_s1 && rx_s2。
    // （写成 rx_s1 && !rx_s2 就成了上升沿检测器，会一个字节都收不到。）
    wire start_edge = !rx_s1 && rx_s2;

    // ------------------------------------------------------------------
    // 接收状态机
    //   idx = 0        起始位中点（复检）
    //   idx = 1..8     数据位中点，LSB 先收
    //   idx = 9        停止位中点（校验）
    // ------------------------------------------------------------------
    reg        busy;
    reg [9:0]  cnt;
    reg [3:0]  idx;
    reg [7:0]  sh;
    reg [7:0]  rx_byte;
    reg        rx_push;

    wire [9:0] period = (idx == 4'd0) ? (HALF - 10'd1) : (DIV - 10'd1);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            busy <= 1'b0; cnt <= 10'd0; idx <= 4'd0;
            sh <= 8'd0; rx_byte <= 8'd0; rx_push <= 1'b0;
        end else begin
            rx_push <= 1'b0;
            if (!busy) begin
                if (start_edge) begin
                    busy <= 1'b1;
                    cnt  <= 10'd0;
                    idx  <= 4'd0;
                end
            end else if (cnt == period) begin
                cnt <= 10'd0;
                case (idx)
                    4'd0: begin
                        // 起始位中点复检：仍为低才认为是真的起始位（滤毛刺）
                        if (rx_s2) busy <= 1'b0;
                        else       idx  <= 4'd1;
                    end
                    4'd1, 4'd2, 4'd3, 4'd4,
                    4'd5, 4'd6, 4'd7, 4'd8: begin
                        sh[idx - 4'd1] <= rx_s2;      // LSB first
                        idx <= idx + 4'd1;
                    end
                    4'd9: begin
                        busy <= 1'b0;
                        if (rx_s2) begin              // 停止位为高 => 帧合法
                            rx_byte <= sh;
                            rx_push <= 1'b1;
                        end
                        // 停止位不是高 => 帧错误，丢弃（不推入 FIFO）
                    end
                    default: busy <= 1'b0;
                endcase
            end else begin
                cnt <= cnt + 10'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 接收 FIFO（16 深），指针多 1 位用于区分空/满
    // ------------------------------------------------------------------
    reg [7:0]  fifo [0:15];
    reg [4:0]  wptr, rptr;
    wire       empty = (wptr == rptr);
    wire       full  = (wptr[4] != rptr[4]) && (wptr[3:0] == rptr[3:0]);

    always @(posedge clk or negedge resetn) begin
        if (!resetn)           wptr <= 5'd0;
        else if (rx_push && !full) begin
            fifo[wptr[3:0]] <= rx_byte;
            wptr <= wptr + 5'd1;
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn)          rptr <= 5'd0;
        else if (ack && !empty) rptr <= rptr + 5'd1;
    end

    // 组合读 FIFO 头。mem_bus 在 MEM→WB 沿同时采 rdata 与推进 rptr，
    // 两者读到的都是推进前的 rptr，所以弹出的就是这一拍呈现的字节。
    //
    // [!] 空时务必返回 0，不能直接返回 fifo[rptr] —— 那个槽位从未写过，值是 X。
    //   X 被 CPU 读走会污染分支比较（X 参与 `<` 的结果是 X，而 `if (X)` 按
    //   假处理），控制流走错分支；完整复盘见 doc/reports/。
    wire [7:0] dout = empty ? 8'd0 : fifo[rptr[3:0]];

    assign rdata = {!empty, 23'd0, dout};

endmodule
