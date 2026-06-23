//=============================================================================
// Module Name : printf
// Description : UART 发送模块，支持运行时字节写入并通过串口异步发送。
//               使用 FIFO 缓冲写入数据，解耦上层数据产生与串口发送时序。
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
//   reg        wr_en;
//   reg  [7:0] data_in;
//   wire       fifo_full;
//   wire       fifo_empty;
//   wire       tx;
//
//   // 实例化 printf
//   printf #(
//       .CLK_FREQ(50_000_000),
//       .BAUD_RATE(1_000_000),
//       .DATA_WIDTH(8),
//       .FIFO_DEPTH(1024)
//   ) u_printf (
//       .clk(clk),
//       .rst_n(rst_n),
//       .wr_en(wr_en),
//       .data_in(data_in),
//       .full(fifo_full),
//       .empty(fifo_empty),
//       .tx(tx)
//   );
//
//   // 外部写入示例：只在 FIFO 未满时写入一个字节
//   always @(posedge clk or negedge rst_n) begin
//       if (!rst_n) begin
//           wr_en <= 1'b0;
//           data_in <= 8'h00;
//       end else if (!fifo_full) begin
//           wr_en <= 1'b1;
//           data_in <= 8'h41; // 发送 'A'
//       end else begin
//           wr_en <= 1'b0;
//       end
//   end
//
// Notes:
//   - 外部写使能 wr_en 只在 data_in 有效时置 1 一个时钟周期。
//   - tx 输出 UART 串行数据流。
//
// Author     : [Boxchan]
// Date       : [2026-06-22_22-41-39]
// Version    : 4.0
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
    input  [DATA_WIDTH-1:0] data_in,    // 输入数据
    input  wr_en,                       // 写使能信号
    output full,                        // FIFO满标志
    output empty                        // FIFO空标志
);

//============= 实例化FIFO ================
    wire [7:0] fifo_rd_data;
    wire fifo_empty;
    wire fifo_full;
    sync_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_data(data_in),
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
