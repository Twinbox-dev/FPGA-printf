//=============================================================================
// printf - 完整调试打印模块
//
// 解耦: 内部自包含 FIFO + UART TX, 对外只暴露 write + tx
//
// 例化:
//   printf #(.PRIO_DEPTH(8), .FIFO_DEPTH(1024))
//   u_printf (.clk, .rst_n, .write(write), .tx(uart_tx));
//
// write[69:0] 布局:
//   [69]   = priority (1=走优先级 FIFO, 保证输出)
//   [68]   = head_tail (1=自动包装 0xFF 帧头帧尾)
//   [67:66]= width (00=8bit, 01=16bit, 10=32bit[默认], 11=64bit)
//   [65:64]= reserved
//   [63:0] = DATA
//
// 契约:
//   Cycle N:  write <= value → 组合解码 → 当周期推入对应 FIFO
//   Cycle N+1:write 即可再次赋值
//   数据未输出只有两个原因: FIFO 满 / 用户同周期写了两次 write
//
// Parameters:
//   CLK_FREQ    : 时钟频率
//   BAUD_RATE   : 波特率
//   PRIO_DEPTH  : 优先级 FIFO 深度 (默认 8)
//   FIFO_DEPTH  : 主 FIFO 深度 (默认 1024)
//=============================================================================

module printf #(
    parameter CLK_FREQ    = 50_000_000,
    parameter BAUD_RATE   = 1_000_000,
    localparam MSG_WIDTH = 72,
    localparam FIFO_DEPTH = 1024
    )(
    // 必须进行引脚绑定的接口
    input  wire clk,
    input  wire rst_n,
    output reg  tx,

    // 用户接口 - 输入数据（变化时自动写入 FIFO）
    input  [MSG_WIDTH-1:0] data_in
); 

// 目前决定最高位[7]表示是否写入priority FIFO + [1:0] 表示数据位宽8/16/32/64从高到低供选择 + [6]表示瞬间清空cache FIFO(很危险但个人觉得有必要) + 其他位置暂时保留
wire [7:0]  ctrl; 
wire [63:0] data;
assign ctrl = data_in[71:64];
assign data = data_in[63:0];




//============= 实例化FIFO ================

// 缓存FIFO
    wire [MSG_WIDTH-1:0] fifo_rd_data;
    wire fifo_empty;
    wire fifo_full;
    wire cache_write_en;

    sync_fifo #(
        .DATA_WIDTH(MSG_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) cache_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(cache_write_en),
        .wr_data(wr_data),
        .rd_en(rd_en_int),
        .rd_data(fifo_rd_data),
        .full(),
        .empty()
    );
    assign cache_write_en = wr_en[0];
    assign full  = fifo_full;
    assign empty = fifo_empty;

// 普通数据FIFO
    `define custom_data_width 8
    `define custom_fifo_depth 512
    wire [custom_data_width-1:0] custom_read_data;
    wire [custom_data_width-1:0] custom_write_data;
    wire custom_write_en;
    wire cutsom_fifo_empty,custom_fifo_full;

    sync_fifo #(
        .DATA_WIDTH(custom_data_width),
        .FIFO_DEPTH(custom_fifo_depth)
    ) custom_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(custom_write_en),
        .wr_data(custom_write_data),
        .rd_en(rd_en_int),
        .rd_data(custom_read_data),
        .full(custom_fifo_full),
        .empty(custom_fifo_empty)
    );


// 优先级FIFO
    `define priority_data_width 64
    `define priority_fifo_depth 64
    wire [priority_data_width-1:0] priotiry_read_data;
    wire [priority_data_width-1:0] priority_write_data;
    wire priority_write_en;
    sync_fifo #(
        .DATA_WIDTH(priority_data_width),
        .FIFO_DEPTH(priority_fifo_depth)
    ) priority_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(priority_write_en),
        .wr_data(priority_write_data),
        .rd_en(rd_en_int),
        .rd_data(priority_read_data),
        .full(),
        .empty()
    );
    assign priority_write_en    = wr_en[1];
    assign priority_write_data  = wr_data[priority_data_width-1:0];
//========================================


    reg [ 1:0] wr_en;
    reg [DATA_WIDTH-1:0] wr_data;

    // 自动检测 data_in 变化并写入 FIFO：
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en   <= 0;
            wr_data <= 0;
        end else begin
            wr_en <= 0'b00;
            wr_data <= data_in;
            if (wr_data != data_in && !fifo_full) begin
                wr_en   <= (data_in[DATA_WIDTH] ? 2'b10 : 2'b01);
                wr_data <= data_in;
            end
        end
    end

    wire [DATA_WIDTH-1:0] cache;
    assign cache = wr_data;


always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= WAIT_READ;
        rd_en_int <= 0;
    end else begin
        case (state)
            WAIT_READ: begin
                rd_en_int <= 0;
                state <= START_READ;
            end

            START_READ: begin
                rd_en_int <= 0;
                current_byte <= fifo_rd_data;
                state <= BYTE_BEGIN;
            end


//============= 实例化write ===============
    wire [7:0] uart_write_data;
    reg uart_busy,uart_trigger;
    tx #(
    parameter CLK_FREQ   =  CLK_FREQ,
    parameter BAUD_RATE  = BAUD_RATE,
    ) u_tx (
    // 必须进行引脚绑定的接口
    .clk(clk),
    .rst_n(rst_n),
    .tx(uart_tx),

    // 用户接口
    .trigger(uart_trigger),
    .data(uart_write_data),
    .busy(uart_busy)
    );
//=========================================








//============================================================================
// TX 引擎: 优先级 FIFO → 主 FIFO → 空闲
//============================================================================
    reg [2:0]   tx_state;
    reg [66:0]  tx_entry;      // 当前发送的 entry
    reg [3:0]   tx_byte_cnt;   // 数据字节总数 (1/2/4/8)
    reg [3:0]   tx_byte_idx;   // 当前数据字节索引

    localparam TX_IDLE = 3'd0;
    localparam TX_WAIT = 3'd1;
    localparam TX_LOAD = 3'd2;
    localparam TX_HEAD = 3'd3;
    localparam TX_DATA = 3'd4;
    localparam TX_TAIL = 3'd5;

    


    wire [66:0] fifo_rd_data = prio_rd_data | main_rd_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            prio_rd_en   <= 0;
            main_rd_en   <= 0;
            uart_send_en <= 0;
            uart_byte    <= 0;
            tx_entry     <= 0;
            tx_byte_cnt  <= 0;
            tx_byte_idx  <= 0;
        end else begin
            prio_rd_en   <= 0;
            main_rd_en   <= 0;
            uart_send_en <= 0;

            case (tx_state)
                TX_IDLE: begin
                    if (!prio_empty) begin
                        prio_rd_en <= 1;
                        tx_state   <= TX_WAIT;
                    end else if (!main_empty) begin
                        main_rd_en <= 1;
                        tx_state   <= TX_WAIT;
                    end
                end

                TX_WAIT: begin
                    tx_state <= TX_LOAD;
                end

                TX_LOAD: begin
                    // rd_data 在这一拍有效 (rd_en 在上拍拉高)
                    tx_entry    <= fifo_rd_data;
                    tx_byte_cnt <= 1 << fifo_rd_data[64+:2];
                    tx_byte_idx <= 0;
                    // 有 head_tail 则先发头, 否则直接发数据
                    if (fifo_rd_data[66])
                        tx_state <= TX_HEAD;
                    else
                        tx_state <= TX_DATA;
                end

                TX_HEAD: begin
                    if (!uart_busy) begin
                        uart_send_en <= 1;
                        uart_byte    <= 8'hFF;
                        tx_state     <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    if (!uart_busy) begin
                        uart_send_en <= 1;
                        uart_byte    <= tx_entry[tx_byte_idx*8 +: 8];
                        if (tx_byte_idx + 1 >= tx_byte_cnt) begin
                            if (tx_entry[66])
                                tx_state <= TX_TAIL;
                            else
                                tx_state <= TX_IDLE;
                        end
                        tx_byte_idx <= tx_byte_idx + 1;
                    end
                end

                TX_TAIL: begin
                    if (!uart_busy) begin
                        uart_send_en <= 1;
                        uart_byte    <= 8'hFF;
                        tx_state     <= TX_IDLE;
                    end
                end
            endcase
        end
    end

endmodule





endmodule