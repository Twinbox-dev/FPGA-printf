// 极简测试: 仅发送 1 字节 (0xAB) 走 cache→custom→UART 通路
// data_in[71:64] = ctrl: [7]=prio(0) [6]=clear(0) [2:0]=byte_cnt-1(0=1byte)
// data_in[63:0]  = data: byte0=0xAB

module top (
    input  clk,
    input  rst_n,
    output uart_tx
);

    reg [71:0] data_in;
    reg [31:0] cnt;

    printf #(
        .FIFO_DEPTH(256)
    ) u_printf (
        .clk(clk),
        .rst_n(rst_n),
        .tx(uart_tx),
        .data_in(data_in)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 0;
            data_in <= 0;
        end else begin
            cnt <= cnt + 1;
            // cnt=100 时触发一次写入, 发 1 字节 0xAB
            if (cnt == 100)
                data_in <= {8'h00, 64'h00000000000000AB};
        end
    end

endmodule
