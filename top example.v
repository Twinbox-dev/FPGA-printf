//=============================================================================
// 顶层示例：演示 write 模块的自动写入用法
//
// 功能说明：
//   在复位后，依次改变 data_in 的值 模块自动检测变化并写入 FIFO，
//   由串口发送出去。无需外部写使能信号。
//
// 接线：
//   clk   -> 50MHz 系统时钟
//   rst_n -> 复位按钮（低有效）
//   tx    -> UART 发送引脚（1M baud, 8N1）
//=============================================================================

module top_example (
    input  wire       clk,
    input  wire       rst_n,
    output wire       uart_tx
);

//============= data_in 驱动 ===================
    reg [7:0] data_in;
    reg [3:0] idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx     <= 0;
            data_in <= 8'h00;
        end else if (idx < 4'd6) begin
            idx <= idx + 1;
            data_in <= 8'h41 + idx;     // 'A', 'B', 'C', 'D', 'E', 'F'
        end
    end
//==============================================

//============= 实例化 write ===================
    wire       full;
    wire       empty;

    write #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (1_000_000),
        .DATA_WIDTH(8),
        .FIFO_DEPTH(1024)
    ) u_write (
        .clk    (clk),
        .rst_n  (rst_n),
        .data_in(data_in),
        .full   (full),
        .empty  (empty),
        .tx     (uart_tx)
    );
//=============================================

endmodule
