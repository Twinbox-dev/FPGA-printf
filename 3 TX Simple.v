//=============================================================================
// Module Name : printf
// Description : UART 发送模块，用于通过串口打印指定字符串。
//               支持可配置波特率，数据帧格式：1位起始位 + 8位数据位（LSB First）+ 1位停止位。
//
// Parameters:
//   CLK_FREQ  : 系统时钟频率（Hz），默认 50MHz
//   BAUD_RATE : 目标波特率（bps），默认 1,000,000
//   MSG       : 待发送的字符串（作为位向量参数传入，最高字节对应字符串首字符）
//   MSG_LEN   : 字符串长度（字节数），默认 12（"Hello World!"）
//
// Ports:
//   clk    : 系统时钟输入
//   rst_n  : 异步复位，低有效
//   tx     : UART 发送引脚
//
// 工作流程：
//   1. 复位后进入 IDLE 状态，立即跳转到 BYTE_BEGIN 开始发送第一个字节。
//   2. 每个字节的发送顺序：
//      - 起始位：拉低 tx 并持续 BAUD_DIV 个时钟周期（完整波特周期）。
//      - 数据位：依次发送 8 个数据位，从 LSB（bit 0）到 MSB（bit 7）。
//      - 停止位：拉高 tx 并持续 BAUD_DIV 个时钟周期。
//   3. 发送完最后一个字节的停止位后进入 FINISH 状态，tx 保持高电平。
//
// 与 2.0 版本的差异及修正说明：
//   【问题1】起始位长度错误
//     最初版本：起始位仅持续 BAUD_HALF（半个波特周期），导致接收端采样点偏移。
//     修正：改为持续 BAUD_DIV（完整波特周期），符合 UART 协议。 
//              -- UART 协议中: TX端拉低表示开始,RX端会自动等待半波特率周期后采样第一个数据位,如果此时采集到的仍然是0。
//                             则数据正常,RX端后续等待一个完整波特周期后采样第二个数据位,以此类推。所以TX端不需要考虑半周期问题！
//
//   【问题2】数据位发送顺序错误
//     最初版本：使用 `MSG[MSG_LEN*8-1 - bit_cnt]`，从 MSB 开始发送，且 bit_cnt 全局递增，
//              导致字节内位序颠倒（应为 LSB first），同时字节间顺序也错乱。
//     修正：采用 byte_index 和 bit_in_byte 分别控制字节序号和字节内位序号，
//           `tx <= MSG[(MSG_LEN - (byte_index + 1)) * 8 + bit_in_byte]`
//           确保先发送字符串首字符（最高字节）的 LSB，再依次发送其余位和后续字符。
//           -- 因为在verilog中，字符串常量会自动转换成位向量，因此MSG[MSG_LEN*8-1:MSG*8-8]为0x48-H，MSG[7:0]为0x21-!
//              所以发送时需要从最高字节开始发送。而字节内bit的发送顺序则是从LSB到MSB,因此需要逆序发送 - 这是TX端需要保证的。
//              RX端会在接收10bit结束后,自动将接收到的8bit的byte数据逆序。 
//
//   【其他改进】
//      - 移除未使用的 BAUD_HALF 和 bit_cnt 寄存器，简化逻辑。
//      - 使用 byte_index 替代 bit_cnt 进行字节计数，使代码更清晰。
//
// 存在的问题:
//      1. 打印的调试信息是异步的,当信息打印出来后业务逻辑早就跑飞了上千个时钟周期。
//      2. 现有的MSG只能打印常量,不能打印reg wire类型的运行时变量。
//
// Author     : [Boxchan]
// Date       : [2026-06-22_16-47-39]
// Version    : 3.0 (修正版)
//=============================================================================

module printf #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 1_000_000,
)(
    input clk,
    input rst_n,
    output reg tx
);
    localparam BAUD_DIV  = CLK_FREQ / BAUD_RATE;

    reg [31:0] baud_cnt;
    reg [ 7:0] bit_in_byte;
    reg [ 7:0] byte_index;

    //reg [7:0]  data_buf;
    // assert property (BAUD_RATA < CLK_FREQ/16) else $error("BAUD_RATE must be less than CLK_FREQ/16 for reliable transmission");

//============= 定义状态机 ================
    reg [2:0] state;
    localparam IDLE       = 3'd0;
    localparam BYTE_BEGIN = 3'd1;   // 发送起始位
    localparam BYTE       = 3'd2;   // 发送8个数据位
    localparam BYTE_END   = 3'd3;   // 发送停止位
    localparam FINISH     = 3'd4;   // 全部发送完成
// =======================================
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
                byte_index <= 0;
                bit_in_byte <= 0;
                baud_cnt <= 0;
                tx <= 1;
                state <= IDLE;
        end else begin
            case (state) 
                IDLE: begin
                    byte_index <= 0;
                    bit_in_byte <= 0;
                    baud_cnt <= 0;
                    state <= BYTE_BEGIN;
                end
                
                BYTE_BEGIN: begin
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                        tx <= 0;
                    end else begin
                        baud_cnt <= 0;
                        bit_in_byte <= 0;
                        state <= BYTE;
                    end
                end
                
                BYTE: begin
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                        // 计算当前是哪个字节的第几位
                        // 从最高位(MSB)发送: MSG[(MSG_LEN - (byte_index + 1)) * 8 + bit_in_byte]
                        tx <= MSG[(MSG_LEN - (byte_index + 1)) * 8 + bit_in_byte];
                    end else begin
                        baud_cnt <= 0;
                        bit_in_byte <= bit_in_byte + 1;
                        // 判断是否发完了这个字节的8个数据位
                        if (bit_in_byte == 7) begin
                            state <= BYTE_END;
                        end
                    end
                end
                
                BYTE_END: begin
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                        tx <= 1;                    // 发送停止位
                    end else begin
                        baud_cnt <= 0;
                        byte_index <= byte_index + 1;                   
                        // 检查是否所有字节都发完了
                        if (byte_index + 1 == MSG_LEN) begin
                            state <= FINISH;
                        end else begin
                            state <= BYTE_BEGIN;    // 继续发下一个字节
                        end
                    end
                end

                FINISH: begin
                    tx <= 1;
                end
                
            endcase
        end
    end
endmodule
