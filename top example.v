// 演示: printf 极简调用
// 业务只管 write <= value; 底层单周期推入 FIFO, 下一周期 write 即可复用

// todo:  `define printf(idx)\ write <= idx; 
// todo: 用宏/function封装操作,只暴露最简单的`printf(param)给用户

module top (
    input  clk,
    input  rst_n,
    output uart_tx
);

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 例化一次 (4 个信号)
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    reg [71:0] write;

    printf #(
        .MSG_WIDTH(72),
        .FIFO_DEPTH(1024)
    ) u_printf (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(write),
        .tx(uart_tx)
    );

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 业务: 每计数到 100_000 打印一次
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= 0;
            write <= 0;
        end else begin
            cnt <= cnt + 1;
            if (cnt == 100_000) begin
                write <= {1'b0, 1'b1, 2'b10, 2'b00, cnt};  // ht=1, width=32
                cnt   <= 0;
            end
        end
    end

endmodule
