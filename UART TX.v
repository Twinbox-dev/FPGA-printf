//=============================================================================
// Module Name : tx
// Description : 纯单字节 UART 串行器
//               按 UART 协议（1 起始位 + 8 数据位 LSB 优先 + 1 停止位）
//               将单字节 data 串行化为 tx 波形。
//               与上层解耦：无 FIFO、无变化检测，纯物理层发送。
//
// Parameters:
//   CLK_FREQ  : 系统时钟频率（Hz），默认 50MHz
//   BAUD_RATE : 目标波特率（bps），默认 1,000,000
//
// Interface:
//   trigger   : 上升沿有效，启动一次发送
//   data[7:0] : 待发送字节（在 trigger 前准备好）
//   busy      : 高电平表示正在发送，发送期间忽略 trigger
//   tx        : UART 串行输出
//
// Usage:
//   1. 等待 busy=0
//   2. 设置 data[7:0]
//   3. 拉高 trigger 至少一个周期
//   4. tx 自动完成 10 位 UART 帧发送
//   5. 等待 busy=0 即可发送下一帧
//
// Author     : [Boxchan]
// Date       : [2026-06-24]
// Version    : V3.0
//=============================================================================

module tx #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 1_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg        tx,

    input  wire       trigger,    // verilog中输入参数必须用wire
    input  [7:0]      data,
    output reg        busy
);

//=============================================================================
// 状态定义
//=============================================================================
    reg [2:0] state;
    localparam IDLE       = 2'd0;
    localparam BYTE_BEGIN = 2'd1;
    localparam BYTE_SEND  = 2'd2;
    localparam BYTE_END   = 2'd3;

//=============================================================================
// 波特率计数器
//=============================================================================
    localparam BAUD_DIV  = CLK_FREQ / BAUD_RATE;
    reg  [31:0]          baud_cnt;
    reg  [ 2:0]          bit_index;

//=============================================================================
// 主状态机
//=============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_index <= 0;
            baud_cnt  <= 0;
            busy      <= 0;
            tx        <= 1;
            state     <= IDLE;
        end else begin
            case (state)

//--- IDLE : 等待触发 ---
                IDLE: begin
                    tx       <= 1;
                    busy     <= 0;
                    baud_cnt <= 0;
                    if (trigger) begin
                        busy  <= 1;
                        state <= BYTE_BEGIN;
                    end
                end

//--- BYTE_BEGIN : 发送起始位 ---
                BYTE_BEGIN: begin
                    tx <= 0;
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                    end else begin
                        baud_cnt  <= 0;
                        bit_index <= 0;
                        state     <= BYTE_SEND;
                    end
                end

//--- BYTE_SEND : 发送 8 位数据（LSB 优先,即字节内逆序发送） ---
                BYTE_SEND: begin
                    tx <= data[bit_index];
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                    end else begin
                        baud_cnt <= 0;
                        if (bit_index == 7) begin
                            state <= BYTE_END;
                        end else begin
                            bit_index <= bit_index + 1;
                        end
                    end
                end

//--- BYTE_END : 发送停止位 ---
                BYTE_END: begin
                    tx <= 1;
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                    end else begin
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule
