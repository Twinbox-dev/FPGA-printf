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
    localparam MSG_WIDTH  = 72,
    localparam FIFO_DEPTH = 256
    )(
    // 必须进行引脚绑定的接口
    input  wire clk,
    input  wire rst_n,
    output reg  tx,

    // 用户接口 - 输入数据（变化时自动写入 FIFO）
    input  [MSG_WIDTH-1:0] data_in
); 

wire [7:0]  ctrl; 
wire [63:0] data;
assign ctrl = data_in[71:64];
assign data = data_in[63:0];





//============= 实例化FIFO ================
reg [MSG_WIDTH-1:0] wr_data;
    
    // Cache FIFO
    wire [MSG_WIDTH-1:0] cache_read_data;
    wire cache_empty, cache_full;
    wire cache_write_en, cache_read_en;
    sync_fifo #(
        .DATA_WIDTH(MSG_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) cache_fifo (
        .clk(clk),
        .rst_n(cache_res_n),
        .wr_en(cache_write_en),
        .wr_data(wr_data),
        .rd_en(cache_read_en),
        .rd_data(cache_read_data),
        .full(cache_full),
        .empty(cache_empty)
    );
    assign cache_res_n = rst_n & ~cache_clear_pulse;
    assign cache_write_en = wr_en[0] && (~cache_full);


    // Custom FIFO
    `define custom_data_width 8
    `define custom_fifo_depth 512
    wire [custom_data_width-1:0] custom_read_data;
    wire [custom_data_width-1:0] custom_write_data;
    reg custom_write_en, custom_fifo_empty, custom_fifo_full;
    sync_fifo #(
        .DATA_WIDTH(custom_data_width),
        .FIFO_DEPTH(custom_fifo_depth)
    ) custom_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(custom_write_en),
        .wr_data(custom_write_data),
        .rd_en(custom_read_en),
        .rd_data(custom_read_data),
        .full(custom_fifo_full),
        .empty(custom_fifo_empty)
    );

    // Priority FIFO
    `define priority_data_width 64
    `define priority_fifo_depth 64
    wire [priority_data_width-1:0] priotiry_read_data;
    wire [priority_data_width-1:0] priority_write_data;
    wire prority_write_en, priority_empty, priority_read_en;
    sync_fifo #(
        .DATA_WIDTH(priority_data_width),
        .FIFO_DEPTH(priority_fifo_depth)
    ) priority_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(priority_write_en),
        .wr_data(priority_write_data),
        .rd_en(priority_read_en),
        .rd_data(priority_read_data),
        .full(),
        .empty(priority_empty)
    );
    assign priority_write_en    = wr_en[1];
    assign priority_write_data  = wr_data[priority_data_width-1:0];
//========================================

    // 自动检测 data_in 变化并写入 FIFO：
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache_write_en   <= 0;
            prority_write_en <= 0;
            wr_data <= 0;
            cache_clear_pulse <= 0;
        end else begin
            cache_write_en <= 0;
            prority_write_en <= 0;
            cache_clear_pulse <= 0;
            wr_data <= data_in;
            if (wr_data != data_in && !fifo_full) begin
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



//============= 实例化unpacker ================
    // cache FIFO 的解包器
    wire [7:0] byte0,byte1,byte2,byte3,byte4,byte5,byte6,byte7,byte_cnt;
    unpacker #(
        .DATA_WIDTH(64)
    ) cache_unpacker (
        .ctrl(ctrl),
        .data_in(cache_read_data),

        .priority_or_not(),
        .clear_cache_FIFO(clear_cache_FIFO),
        .cnt(byte_cnt),
        .byte0(byte0),
        .byte1(byte1),
        .byte2(byte2),
        .byte3(byte3),
        .byte4(byte4),
        .byte5(byte5),
        .byte6(byte6),
        .byte7(byte7)
    );

    // priority FIFO 的解包器(不包含任何控制位,只用内部的字节逆序)
    wire [7:0] pbyte0,pbyte1,pbyte2,pbyte3,pbyte4,pbyte5,pbyte6,pbyte7;
    unpacker #(
    ) cache_unpacker (
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
//=============================================


//============================================================================
// 将数据从缓存搬入custom FIFO(不影响其他端口,故可以新开一个always块持续进行数据搬运)
//============================================================================

// todo: 清空cache信号还没处理
//! 没有明确定义当clear有效时该状态机的状态

    reg [1:0] carry_state;
    localparam  CARRY_IDLE = 2'd0;
    localparam   READ_CACHE = 2'd1;
    localparam WRITE_CUSTOM = 2'd2;
    
    reg [7:0] custom_write_data_temp [0:7]; // 反着接正向字节
    reg [2:0] byte_index;
    reg carry_wait_cnt;


    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n) begin
            carry_state <= CARRY_IDLE;
            custom_write_en <= 0;
            cache_read_en <= 0;
            carry_wait_cnt <= 0;
            byte_index <= 0;
        end else begin
            // 首先将FIFO的读写使能置零。确保使能信号只会拉高一拍！
            cache_read_en  <= 0;
            custom_write_en <= 0;

            case (carry_state) 
                CARRY_IDLE: begin
                    if (~custom_full && ~cache_empty) begin:
                        cache_read_en <= 1;
                        carry_state <= READ_CACHE;
                    end
                end

                READ_CACHE: begin
                    if (carry_wait_cnt < 1) begin
                        carry_wait_cnt <= carry_wait_cnt + 1;
                    end else begin
                        custom_write_data_temp <= {byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7};
                        byte_index <= 0;
                        carry_wait_cnt <= 0;
                        carry_state <= WRITE_CUSTOM;
                    end
                end

                WRITE_CUSTOM: begin
                    custom_write_en <= 1'b1;
                    byte_cnt <= byte_cnt - 1;
                    byte_index <= byte_index + 1;
                    custom_write_data <= custom_write_data_temp[byte_index];
                    if(byte_cnt == 0) begin
                        custom_write_en <= 0;
                        carry_state <= CARRY_IDLE;
                    end
                end
            endcase
        end
    end


endmodule


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
// TX 状态机: prio FIFO 非空则发送prio数据;否则轮询custom FIFO
//============================================================================
    reg [2:0]   tx_state;
    reg [66:0]  tx_entry;      // 当前发送的 entry
    reg [3:0]   tx_byte_cnt;   
    reg [2:0]   tx_byte_idx;   // 当前数据字节索引

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
