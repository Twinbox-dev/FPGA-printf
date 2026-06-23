//====================================================================
// printf
// 相较于上一版，该模块更适用于Tx module。
// 不过缺少复位逻辑，模块起始状态不确定。是有Bug的一版。
//====================================================================


module printf #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD_RATE = 1_000_000,
    parameter MSG = "Hello World!",   // 在 verilog 中,每个字符会自动转换成一个[7:0]的常量。例如该变量中[15:8]为0110_0101(e=0x65=0110_0101)
    parameter MSG_LEN = 12
)(
    input clk,
    output reg tx
);
    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;
    localparam BAUD_HALF = BAUD_DIV / 2;


    reg [31:0] baud_cnt;
    reg [ 7:0] bit_in_byte;
    reg [31:0] bit_cnt;

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
    
    always @(posedge clk) begin
        case (state) 
            IDLE: begin
                bit_cnt <= 0;
                baud_cnt <= 0;
                bit_in_byte <= 0;
                state <= BYTE_BEGIN;
            end
            
            BYTE_BEGIN: begin
                if (baud_cnt < BAUD_HALF - 1) begin
                    baud_cnt <= baud_cnt + 1;
                end else begin
                    baud_cnt <= 0;
                    tx <= 0;                    // 发送起始位
                    bit_in_byte <= 0;           // 重置字节内bit计数
                    state <= BYTE;
                end
            end
            
            BYTE: begin
                if (baud_cnt < BAUD_DIV - 1) begin
                    baud_cnt <= baud_cnt + 1;
                end else begin
                    baud_cnt <= 0;
                    // 计算当前是哪个字节的第几位
                    // 从最高位(MSB)发送: MSG[MSG_LEN*8-1 - byte_index*8 - bit_in_byte]
                    tx <= MSG[MSG_LEN*8-1 - bit_cnt];
                    bit_cnt <= bit_cnt + 1;
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
                end else begin
                    baud_cnt <= 0;
                    tx <= 1;                    // 发送停止位
                    
                    // 检查是否所有字节都发完了
                    if (bit_cnt >= MSG_LEN*8) begin
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
endmodule
