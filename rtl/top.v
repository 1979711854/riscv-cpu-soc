module top (
    input  wire clk,      // 开发板时钟
    input  wire rst_n,    // 复位信号（低有效）
    output wire led       // LED输出
);

reg [23:0] counter;
reg led_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        counter <= 24'd0;
        led_reg <= 1'b0;
    end else begin
        counter <= counter + 1'b1;
        // 约 0.1 秒翻转一次（具体取决于时钟频率）
        if (counter == 24'd10_000_000) begin
            counter <= 24'd0;
            led_reg <= ~led_reg;
        end
    end
end

assign led = led_reg;

endmodule