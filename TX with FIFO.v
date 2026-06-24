//=============================================================================
// Module Name : write
// Description : UART 发送模块（含 FIFO 缓冲），自动检测 data_in 变化并写入 FIFO，
//               通过串口异步发送。解耦上层数据产生与串口发送时序。
//               串口数据帧格式：1位起始位 + 8位数据位（LSB First）+ 1位停止位。
//
// Parameters:
//   CLK_FREQ  : 系统时钟频率（Hz），默认 50MHz
//   BAUD_RATE : 目标波特率（bps），默认 1,000,000
//   DATA_WIDTH: 数据宽度，默认 8
//   FIFO_DEPTH: FIFO 深度，单位为字节，默认 1024
//
// External Usage Example:
//   // 顶层信号
//   reg        clk;
//   reg        rst_n;
//   reg  [7:0] data_in;
//   wire       tx;
//   wire       full;
//   wire       empty;
//
//   // 实例化 write
//   write #(
//       .CLK_FREQ(50_000_000),
//       .BAUD_RATE(1_000_000),
//       .DATA_WIDTH(8),
//       .FIFO_DEPTH(1024)
//   ) u_write (
//       .clk(clk),
//       .rst_n(rst_n),
//       .data_in(data_in),
//       .full(full),
//       .empty(empty),
//       .tx(tx)
//   );
//
//   // 写入示例：改变 data_in 即可自动触发写入
//   always @(posedge clk or negedge rst_n) begin
//       if (!rst_n) begin
//           data_in <= 8'h41; // 复位后第一个非 0xFF 的值即触发写入
//       end else begin
//           data_in <= 8'h42;
//       end
//   end
//
// Notes:
//   - 模块自动检测 data_in 变化并写入 FIFO，无需外部 wr_en。
//   - 当 FIFO 满时数据不会写入，等待 FIFO 空闲后自动写入最新值。
//   - tx 输出 UART 串行数据流。
//
// TODO(v2.0+):
//   1. 实现带控制位的 write 模块：通过控制位动态调整写入数据位宽
//   2. 底层多 FIFO 协调：
//      - Priority FIFO（优先队列）：向业务保证写入的数据绝对发出
//      - Normal  FIFO（普通队列）：即当前实现，fifo 静默满，不保证数据发出
//
// Author     : [Boxchan]
// Date       : [2026-06-22_22-41-39]
// Version    : V2.0
//=============================================================================






module write #(
    parameter CLK_FREQ   = 50_000_000,
    parameter BAUD_RATE  = 1_000_000,
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 1024
)(
    // 必须进行引脚绑定的接口
    input  wire clk,
    input  wire rst_n,
    output reg  tx,

    // 用户接口 - 写数据
    input  [DATA_WIDTH-1:0] data_in,    // 输入数据（变化时自动写入 FIFO）
    output full,                        // FIFO满标志
    output empty                        // FIFO空标志
);

//============= 实例化FIFO ================
    wire [DATA_WIDTH-1:0] fifo_rd_data;
    wire fifo_empty;
    wire fifo_full;
    sync_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .full(fifo_full),
        .rd_en(rd_en_int),   // 内部读使能
        .rd_data(fifo_rd_data),
        .empty(fifo_empty)
    );
    assign full  = fifo_full;
    assign empty = fifo_empty;
//========================================

//============= 定义状态机 ================
    reg [2:0] state;
    localparam IDLE       = 3'd0;
    localparam WAIT_READ  = 3'd1;   // 等待一拍，让 rd_data 刷新
    localparam START_READ = 3'd2;   // 锁存 FIFO 字节
    localparam BYTE_BEGIN = 3'd3;   // 发送起始位
    localparam BYTE       = 3'd4;   // 发送8个数据位
    localparam BYTE_END   = 3'd5;   // 发送停止位
// =======================================

    localparam BAUD_DIV  = CLK_FREQ / BAUD_RATE;
    reg [31:0] baud_cnt;
    reg [ 2:0] bit_in_byte;
    reg [ 7:0] current_byte;
    reg        rd_en_int;
    reg                    fifo_wr_en;
    reg  [DATA_WIDTH-1:0]  fifo_wr_data;

    // 自动检测 data_in 变化并写入 FIFO：
    // fifo_wr_data 复位为全 1，确保首个 data_in 不论为何值都触发写入；
    // 同时 fifo_wr_data 追踪上次写入值，避免重复写入相同数据。
    // fifo_wr_en 在下一周期生效时，FIFO 写的是已锁存的 fifo_wr_data，不受 data_in 变化影响。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_en   <= 0;
            fifo_wr_data <= {DATA_WIDTH{1'b1}};
        end else begin
            fifo_wr_en <= 0;
            if (fifo_wr_data != data_in && !fifo_full) begin
                fifo_wr_en   <= 1;
                fifo_wr_data <= data_in;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_in_byte <= 0;
            baud_cnt <= 0;
            current_byte <= 8'hFF;
            rd_en_int <= 0;
            tx <= 1;
            state <= IDLE;
        end else begin
            case (state) 
                IDLE: begin
                    baud_cnt <= 0;
                    bit_in_byte <= 0;
                    rd_en_int <= 0;
                    tx <= 1;
                    if (!fifo_empty) begin
                        rd_en_int <= 1;
                        state <= WAIT_READ;
                    end
                end

                WAIT_READ: begin
                    rd_en_int <= 0;
                    state <= START_READ;
                end

                START_READ: begin
                    rd_en_int <= 0;
                    current_byte <= fifo_rd_data;
                    state <= BYTE_BEGIN;
                end
                
                BYTE_BEGIN: begin
                    tx <= 0;
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                    end else begin
                        baud_cnt <= 0;
                        bit_in_byte <= 0;
                        state <= BYTE;
                    end
                end

                BYTE: begin
                    // 从当前字节的最低位开始发送。UART协议要求发送数据时，LSB优先(即逆序发送)。
                    tx <= current_byte[bit_in_byte];
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                    end else begin
                        baud_cnt <= 0;
                        if (bit_in_byte == 7) begin
                            state <= BYTE_END;
                        end else begin
                            bit_in_byte <= bit_in_byte + 1;
                        end
                    end
                end

                BYTE_END: begin
                    tx <= 1;
                    if (baud_cnt < BAUD_DIV - 1) begin
                        baud_cnt <= baud_cnt + 1;
                    end else begin
                        baud_cnt <= 0;
                        if (!fifo_empty) begin
                            rd_en_int <= 1;
                            state <= WAIT_READ;
                        end else begin
                            state <= IDLE;
                        end
                    end
                end

            endcase
        end
    end
endmodule
