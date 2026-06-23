//====================================================================
// uart_tx_simple
// 功能：简易UART发送器
// 特性：
//   - 每间隔1秒自动发送 "Hello\r\n" + 参数MSG的最低一位
//   - 波特率可配置，默认1Mbps
//   - 数据帧格式：1起始位 + 8数据位(LSB先发) + 1停止位
// 参数：
//   CLK_FREQ  - 时钟频率
//   BAUD_RATE - 波特率
//   MSG       - 附加发送字符串
// 端口：
//   clk, rst_n, tx
//====================================================================




module uart_tx_simple #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 1_000_000,
    parameter MSG = "He"
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg        tx
);

    reg [31:0] cnt;
    reg [15:0] baud_cnt;
    reg [3:0]  bit_cnt;
    reg [7:0]  data_buf;
    reg        sending;

    // 要发送的数据："Hello\r\n" 
    // reg [7:0] msg [0:6];
    reg [7:0] msg [0:7]; 
    initial begin
        msg[0] = "H";
        msg[1] = "e";
        msg[2] = "l";
        msg[3] = "l";
        msg[4] = "o";
        msg[5] = 8'h0D;  // \r
        msg[6] = 8'h0A;  // \n
        msg[7] = MSG[7:0];
    end

    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx       <= 1;
            cnt      <= 0;
            baud_cnt <= 0;
            bit_cnt  <= 0;
            sending  <= 0;
        end else begin
            if (!sending) begin
                // 每过1秒启动一次发送
                if (cnt >= CLK_FREQ - 1) begin
                    cnt      <= 0;
                    sending  <= 1;
                    bit_cnt  <= 0;
                    baud_cnt <= 0;
                    data_buf <= msg[0];  // 先取第一个字符
                end else begin
                    cnt <= cnt + 1;
                end
            end else begin
                if (baud_cnt < BAUD_DIV - 1) begin
                    baud_cnt <= baud_cnt + 1;
                end else begin
                    baud_cnt <= 0;
                    
                    if (bit_cnt == 0) begin
                        // 发送起始位
                        tx <= 0;
                        bit_cnt <= 1;
                    end else if (bit_cnt >= 1 && bit_cnt <= 8) begin
                        // 发送8个数据位（低位在前）
                        tx <= data_buf[bit_cnt - 1];
                        bit_cnt <= bit_cnt + 1;
                    end else if (bit_cnt == 9) begin
                        // 发送停止位
                        tx <= 1;
                        bit_cnt <= 10;
                    end else begin
                        // 一个字符发送完毕，准备下一个
                        bit_cnt <= 0;
                        if (cnt == 7) begin
                            // 所有字符发完，回到空闲
                            sending <= 0;
                            cnt <= 0;
                        end else begin
                            cnt <= cnt + 1;
                            data_buf <= msg[cnt + 1];
                        end
                    end
                end
            end
        end
    end

endmodule