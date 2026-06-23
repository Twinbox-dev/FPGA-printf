// 演示: 单实例 dbg_printf, 多个业务逻辑共享
// 业务只管给值 + trigger, 模块自动格式化推入 FIFO 并串行发出
module top (
    input  clk,
    input  rst_n,
    output uart_tx
);

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 例化一次 (单 TX 引脚)
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    wire        dbg_busy;
    reg         dbg_trig;
    reg  [31:0] dbg_val;

    dbg_printf #(
        .FMT_STR ("cnt=%x\r\n"),
        .FMT_LEN (8)
    ) u_dbg (
        .clk(clk),
        .rst_n(rst_n),
        .tx(uart_tx),

        .fmt_trig(dbg_trig),
        .fmt_val (dbg_val),
        .fmt_busy(dbg_busy),

        .push_en (1'b0),
        .push_data(8'h00),
        .push_full()
    );

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 业务逻辑: 只管提供要打印的值
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 0;
            dbg_trig <= 0;
            dbg_val <= 0;
        end else begin
            cnt <= cnt + 1;
            dbg_trig <= 0;

            if (cnt == 100_000 && !dbg_busy) begin
                dbg_val  <= cnt;
                dbg_trig <= 1;
                cnt      <= 0;
            end
        end
    end

endmodule
