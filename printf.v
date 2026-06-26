//=============================================================================
// Module Name : printf
// Description : 完整调试打印模块（顶层模块）
//               封装了 FIFO 缓存、字节拆包、数据搬运、UART 串行发送全链路。
//               自动检测 data_in 变化，将数据经过 FIFO 缓存后通过 UART 发送。
//
//               特性：
//                 - 自动检测 data_in 变化并写入对应 FIFO
//                 - 支持优先级通道（priority FIFO），确保关键数据优先发送
//                 - 支持 cache 清空（clear）功能
//                 - 支持多种数据位宽（8[默认] -- 64 bit）
//                 - 状态机: 含字节拆包、数据搬运（cache → custom）、UART 发送调度
//
// 子模块实例化清单：
//   1. sync_fifo   cache_fifo         — cache 数据缓存 FIFO
//   2. sync_fifo   custom_fifo        — 自定义深度 FIFO（转存拆包后的字节）
//   3. sync_fifo   priority_fifo      — 优先级数据 FIFO（高优先级，保证输出）
//   4. unpacker    cache_unpacker     — cache 通道字节拆包与控制位解码
//   5. unpacker    priority_unpacker  — priority 通道字节拆包（只使用字节逆序）
//   6. tx          u_tx               — UART 串行发送器（物理层）
//
// 状态机清单：
//   1. carry_state  — 数据搬运状态机
//      状态: CARRY_IDLE → READ_CACHE → WRITE_CUSTOM
//      功能: 从 cache FIFO 读出数据，经 unpacker 拆包后逐字节写入
//            custom FIFO，实现宽数据到字节流的转换。
//
//   2. tx_state     — UART 发送调度状态机
//      状态: TX_IDLE → TX_PRIO_READ → TX_PRIO_SEND / TX_CUSTOM_READ_SEND
//      功能: priority FIFO 非空时优先发送优先级数据；
//            否则从 custom FIFO 读取一个字节直接发送。
//
// data_in[71:64] — ctrl 控制位（详见 unpacker.v 头注释 Ctrl Bit Field）
// data_in[63:0]  — 数据（大端：有效字节放在高位）
//
// Parameters:
//   CLK_FREQ    : 系统时钟频率（Hz），默认 50MHz
//   BAUD_RATE   : UART 波特率（bps），默认 1,000,000
//   MSG_WIDTH   : 数据总线宽度（localparam），固定 72bit（8 ctrl + 64 data）
//   FIFO_DEPTH  : cache FIFO 深度（parameter），默认 256
//
// Interface:
//   clk           : 系统时钟
//   rst_n         : 异步复位，低有效
//   tx            : UART 串行输出
//   data_in[71:0] : 输入数据总线（ctrl[7:0] + data[63:0]）
//
// Author     : [Boxchan]
// Date       : [2026-06-26]
// Version    : V3.0
//=============================================================================

module printf #(
    parameter CLK_FREQ    = 50_000_000,
    parameter BAUD_RATE   = 1_000_000,
    localparam MSG_WIDTH  = 72,
    parameter FIFO_DEPTH  = 256
)(
    // 必须进行引脚绑定的接口
    input  wire clk,
    input  wire rst_n,
    output wire tx,

    // 用户接口 - 输入数据（变化时自动写入 FIFO）
    input  [MSG_WIDTH-1:0] data_in
);

wire [7:0]  ctrl;
wire [63:0] data;
assign ctrl = data_in[71:64];
assign data = data_in[63:0];


//=============================================================================
// FIFO 实例化
//=============================================================================

    reg [MSG_WIDTH-1:0] wr_data;
    reg cache_clear_pulse;

    //--- Cache FIFO ---
    wire [MSG_WIDTH-1:0] cache_read_data;
    wire cache_empty, cache_full;
    reg cache_write_en, cache_read_en;
    sync_fifo #(
        .DATA_WIDTH(MSG_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) cache_fifo (
        .clk    (clk),
        .rst_n  (cache_res_n),
        .wr_en  (cache_write_en),
        .wr_data(wr_data),
        .rd_en  (cache_read_en),
        .rd_data(cache_read_data),
        .full   (cache_full),
        .empty  (cache_empty)
    );
    assign cache_res_n = rst_n & ~cache_clear_pulse;

    //--- Custom FIFO ---
    localparam custom_data_width = 8;
    localparam custom_fifo_depth = 512;
    wire [custom_data_width-1:0] custom_read_data;
    reg  [custom_data_width-1:0] custom_write_data;
    reg custom_write_en, custom_read_en;
    wire custom_empty, custom_full;
    sync_fifo #(
        .DATA_WIDTH(custom_data_width),
        .FIFO_DEPTH(custom_fifo_depth)
    ) custom_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (custom_write_en),
        .wr_data(custom_write_data),
        .rd_en  (custom_read_en),
        .rd_data(custom_read_data),
        .full   (custom_full),
        .empty  (custom_empty)
    );

    //--- Priority FIFO ---
    localparam priority_data_width = 64;
    localparam priority_fifo_depth = 64;
    wire [priority_data_width-1:0] priority_read_data;
    wire [priority_data_width-1:0] priority_write_data;
    reg  priority_write_en;
    wire priority_empty;
    reg  priority_read_en;
    sync_fifo #(
        .DATA_WIDTH(priority_data_width),
        .FIFO_DEPTH(priority_fifo_depth)
    ) priority_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (priority_write_en),
        .wr_data(priority_write_data),
        .rd_en  (priority_read_en),
        .rd_data(priority_read_data),
        .full   (),
        .empty  (priority_empty)
    );
    assign priority_write_data = wr_data[priority_data_width-1:0];

//=============================================================================
// 自动检测 data_in 变化并写入对应 FIFO
//=============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache_write_en    <= 0;
            priority_write_en <= 0;
            wr_data           <= 0;
            cache_clear_pulse <= 0;
        end else begin
            cache_write_en    <= 0;
            priority_write_en <= 0;
            cache_clear_pulse <= 0;
            wr_data <= data_in;
            if (wr_data != data_in && !cache_full) begin
                if (ctrl[7]) begin
                    priority_write_en <= 1;
                end else if (!cache_full) begin
                    cache_write_en <= 1;
                    wr_data <= data_in;
                end
                if (ctrl[6]) begin
                    cache_clear_pulse <= 1;
                end
            end
        end
    end


//=============================================================================
// unpacker 实例化
//=============================================================================

    //--- cache 通道解包器 ---
    wire [7:0] byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7;
    wire [2:0] unpack_byte_cnt;
    unpacker #(
        .DATA_WIDTH(64)
    ) cache_unpacker (
        .ctrl             (ctrl),
        .data_in          (cache_read_data),

        .priority_or_not  (),
        .clear_cache_FIFO (clear_cache_FIFO),
        .cnt              (unpack_byte_cnt),
        .byte0            (byte0),
        .byte1            (byte1),
        .byte2            (byte2),
        .byte3            (byte3),
        .byte4            (byte4),
        .byte5            (byte5),
        .byte6            (byte6),
        .byte7            (byte7)
    );

    //--- priority 通道解包器（不包含任何控制位，只用内部的字节逆序）---
    wire [7:0] pbyte0, pbyte1, pbyte2, pbyte3, pbyte4, pbyte5, pbyte6, pbyte7;
    unpacker #(
    ) priority_unpacker (
        .data_in(priority_read_data),

        .byte0(pbyte0),
        .byte1(pbyte1),
        .byte2(pbyte2),
        .byte3(pbyte3),
        .byte4(pbyte4),
        .byte5(pbyte5),
        .byte6(pbyte6),
        .byte7(pbyte7)
    );


//=============================================================================
// 状态机 1：数据搬运（cache FIFO → custom FIFO）
//=============================================================================
// 将数据从缓存搬入 custom FIFO（不影响其他端口，故可新开一个 always 块
// 持续进行数据搬运）。
//
// 状态转移：
//   CARRY_IDLE → READ_CACHE → [等待 1 周期] → WRITE_CUSTOM → CARRY_IDLE
//
// todo: 清空 cache 信号还没处理
//! 没有明确定义当 clear 有效时该状态机的状态
//=============================================================================

    reg [1:0] carry_state;
    localparam CARRY_IDLE    = 2'd0;
    localparam READ_CACHE    = 2'd1;
    localparam WRITE_CUSTOM  = 2'd2;

    reg [7:0] custom_write_data_temp [0:7]; // 反着接正向字节
    reg [2:0] byte_index;
    reg [2:0] byte_cnt;
    reg carry_wait_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            carry_state     <= CARRY_IDLE;
            custom_write_en <= 0;
            cache_read_en   <= 0;
            carry_wait_cnt  <= 0;
            byte_index      <= 0;
        end else begin
            // 首先将 FIFO 的读写使能置零，确保使能信号只会拉高一拍！
            cache_read_en    <= 0;
            custom_write_en  <= 0;

            case (carry_state)
                CARRY_IDLE: begin
                    if (~custom_full && ~cache_empty) begin
                        cache_read_en <= 1;
                        carry_state   <= READ_CACHE;
                    end
                end

                READ_CACHE: begin
                    if (carry_wait_cnt < 1) begin
                        carry_wait_cnt <= carry_wait_cnt + 1;
                    end else begin
                        custom_write_data_temp[0] <= byte0;
                        custom_write_data_temp[1] <= byte1;
                        custom_write_data_temp[2] <= byte2;
                        custom_write_data_temp[3] <= byte3;
                        custom_write_data_temp[4] <= byte4;
                        custom_write_data_temp[5] <= byte5;
                        custom_write_data_temp[6] <= byte6;
                        custom_write_data_temp[7] <= byte7;
                        byte_index      <= 0;
                        byte_cnt        <= unpack_byte_cnt;
                        carry_wait_cnt  <= 0;
                        carry_state     <= WRITE_CUSTOM;
                    end
                end

                WRITE_CUSTOM: begin
                    custom_write_en   <= 1'b1;
                    byte_cnt          <= byte_cnt - 1;
                    byte_index        <= byte_index + 1;
                    custom_write_data <= custom_write_data_temp[byte_index];
                    if (byte_cnt == 0) begin
                        carry_state   <= CARRY_IDLE;
                    end
                end
            endcase
        end
    end


//=============================================================================
// UART TX 实例化
//=============================================================================

    reg [7:0] uart_write_data;
    wire uart_busy;
    reg uart_trigger;
    tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_tx (
        // 必须进行引脚绑定的接口
        .clk  (clk),
        .rst_n(rst_n),
        .tx   (tx),

        // 用户接口
        .trigger(uart_trigger),
        .data   (uart_write_data),
        .busy   (uart_busy)
    );


//=============================================================================
// 状态机 2：UART 发送调度
//=============================================================================
// priority FIFO 非空则发送优先级数据；否则轮询 custom FIFO。
//
// 状态转移（priority 通道）：
//   TX_IDLE → TX_PRIO_READ → [等待 1 周期] → TX_PRIO_SEND → [逐字节发送] → TX_IDLE
//
// 状态转移（custom 通道）：
//   TX_IDLE → TX_CUSTOM_READ_SEND → [等待 1 周期] → TX_IDLE
//=============================================================================

    reg [2:0]   tx_state;
    localparam TX_IDLE             = 3'd0;
    localparam TX_PRIO_READ        = 3'd1;
    localparam TX_PRIO_SEND        = 3'd2;
    localparam TX_CUSTOM_READ      = 3'd4;
    localparam TX_CUSTOM_SEND      = 3'd5;


    reg [2:0] byte_idx;
    reg [7:0] uart_byte;
    reg tx_wait_cnt;
    reg [7:0] priority_data_temp [0:7]; // 反着接正向字节
    reg [7:0] custom_data_temp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state          <= TX_IDLE;
            priority_read_en  <= 0;
            custom_read_en    <= 0;
            uart_trigger      <= 0;
            uart_byte         <= 8'h00;
            tx_wait_cnt       <= 0;
        end else begin
            priority_read_en  <= 0;
            custom_read_en    <= 0;
            uart_trigger      <= 0;

            case (tx_state)
                TX_IDLE: begin
                    tx_wait_cnt <= 0;
                    if (!priority_empty) begin
                        priority_read_en <= 1;
                        tx_state <= TX_PRIO_READ;
                    end else if (!custom_empty) begin
                        custom_read_en <= 1;
                        tx_state <= TX_CUSTOM_READ;
                    end
                end

                TX_PRIO_READ: begin
                    if (tx_wait_cnt < 1) begin
                        tx_wait_cnt <= tx_wait_cnt + 1;
                    end else begin
                        priority_data_temp[0] <= pbyte0;
                        priority_data_temp[1] <= pbyte1;
                        priority_data_temp[2] <= pbyte2;
                        priority_data_temp[3] <= pbyte3;
                        priority_data_temp[4] <= pbyte4;
                        priority_data_temp[5] <= pbyte5;
                        priority_data_temp[6] <= pbyte6;
                        priority_data_temp[7] <= pbyte7;
                        byte_idx <= 0;
                        tx_state <= TX_PRIO_SEND;
                    end
                end

                TX_PRIO_SEND: begin
                    if (!uart_busy) begin
                        if (byte_idx < 8) begin
                            uart_trigger    <= 1;
                            uart_write_data <= priority_data_temp[byte_idx];
                            byte_idx        <= byte_idx + 1;
                        end else begin
                            tx_state <= TX_IDLE;
                        end
                    end
                end

                TX_CUSTOM_READ: begin
                    if (tx_wait_cnt < 1) begin
                        tx_wait_cnt <= tx_wait_cnt + 1;
                    end else begin
                        custom_data_temp <= custom_read_data;
                        tx_state <= TX_CUSTOM_SEND;
                    end
                end

                TX_CUSTOM_SEND: begin
                    if (!uart_busy) begin
                        uart_trigger     <= 1;
                        uart_write_data  <= custom_data_temp;
                        tx_state         <= TX_IDLE;
                    end
                end

            endcase
        end
    end

endmodule
