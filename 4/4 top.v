// 演示: 极简调用, 例化只需 4 个信号
// 业务逻辑只管 write <= 值; 底层自动格式化 + 串行发出
module top (
    input  clk,
    input  rst_n,
    output uart_tx
);

    reg [31:0] write;
    reg [31:0] cnt;

    dbg_printf #(
        .FMT_STR ("cnt=%x\r\n"),
        .FMT_LEN (8),
        .VAL_WIDTH(32)
    ) u_dbg (
        .clk(clk),
        .rst_n(rst_n),
        .write(write),
        .tx(uart_tx)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= 0;
            write <= 0;
        end else begin
            cnt <= cnt + 1;
            if (cnt == 100_000) begin
                write <= cnt;       // 只管赋值, 不管底层
                cnt   <= 0;
            end
        end
    end

endmodule
