// 同步 FIFO（单时钟域），参数化深度和位宽
module sync_fifo #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 1024          // 必须是2的幂，以便使用二进制指针
)(
    input  clk,
    input  rst_n,
    // 写侧
    input  wr_en,
    input  [DATA_WIDTH-1:0] wr_data,
    output full,
    // 读侧
    input  rd_en,
    output reg [DATA_WIDTH-1:0] rd_data,
    output empty
);

    // 地址宽度（log2(FIFO_DEPTH)，兼容纯 Verilog）：支持深度到 65536
    localparam ADDR_WIDTH =
        (FIFO_DEPTH <= 2) ? 1 :
        (FIFO_DEPTH <= 4) ? 2 :
        (FIFO_DEPTH <= 8) ? 3 :
        (FIFO_DEPTH <= 16) ? 4 :
        (FIFO_DEPTH <= 32) ? 5 :
        (FIFO_DEPTH <= 64) ? 6 :
        (FIFO_DEPTH <= 128) ? 7 :
        (FIFO_DEPTH <= 256) ? 8 :
        (FIFO_DEPTH <= 512) ? 9 :
        (FIFO_DEPTH <= 1024) ? 10 :
        (FIFO_DEPTH <= 2048) ? 11 :
        (FIFO_DEPTH <= 4096) ? 12 :
        (FIFO_DEPTH <= 8192) ? 13 :
        (FIFO_DEPTH <= 16384) ? 14 :
        (FIFO_DEPTH <= 32768) ? 15 :
        (FIFO_DEPTH <= 65536) ? 16 :
        0;

    // 双端口 RAM
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    // 读写指针（二进制计数）
    wire [ADDR_WIDTH-1:0] wr_ptr, rd_ptr;
    // 额外的一位用于区分满/空（格雷码可选，但单时钟域直接用二进制即可）
    reg [ADDR_WIDTH:0] wr_ptr_ext, rd_ptr_ext;

    // 写指针更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_ext <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;              // 写入
            wr_ptr_ext <= wr_ptr_ext + 1;
        end
    end

    // 读指针更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_ext <= 0;
        end else if (rd_en && !empty) begin
            rd_data <= mem[rd_ptr];              // 读出
            rd_ptr_ext <= rd_ptr_ext + 1;
        end
    end

    // 分离低位指针（方便寻址）
    assign wr_ptr = wr_ptr_ext[ADDR_WIDTH-1:0];
    assign rd_ptr = rd_ptr_ext[ADDR_WIDTH-1:0];
    // 空满判断（利用扩展的最高位）
    assign empty = (wr_ptr_ext == rd_ptr_ext);                                              // 读出指针追上写入指针
    assign full  = (wr_ptr_ext == {~rd_ptr_ext[ADDR_WIDTH], rd_ptr_ext[ADDR_WIDTH-1:0]});   // 写入指针多跑一轮FIFO_DEPTH后追上读出指针

endmodule
