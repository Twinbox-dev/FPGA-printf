//=============================================================================
// Module Name : sync_fifo
// Description : 同步 FIFO（单时钟域），参数化深度和位宽
//               支持任意 2^N 深度，空满判断使用扩展指针法
//
// Parameters:
//   DATA_WIDTH : 数据位宽（bit），默认 8
//   FIFO_DEPTH : FIFO 深度（entry 数），必须是 2 的幂，默认 1024
//
// Interface:
//   写入 : wr_en=1 且 full=0 时，wr_data 写入 FIFO
//   读出 : rd_en=1 且 empty=0 时，rd_data 在本周期末更新为读出值
//   状态 : full / empty 为组合逻辑输出
//
// Timing Note:
//   rd_en=1 的同一周期，rd_data 尚未更新（读旧值）；
//   下一周期末 rd_data 才反映 mem[rd_ptr] 的值（NBA 延迟）。
//   外部逻辑应在 rd_en=1 的下一个周期采 rd_data。
//
// Author     : [Boxchan]
// Date       : [2026-06-24]
// Version    : V3.0
//=============================================================================

module sync_fifo #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 1024
)(
    input  clk,
    input  rst_n,
    input  wr_en,
    input  [DATA_WIDTH-1:0] wr_data,
    output full,
    input  rd_en,
    output reg [DATA_WIDTH-1:0] rd_data,
    output empty
);

//=============================================================================
// 地址宽度计算
//=============================================================================
    localparam ADDR_WIDTH =
        (FIFO_DEPTH <= 2)    ? 1  :
        (FIFO_DEPTH <= 4)    ? 2  :
        (FIFO_DEPTH <= 8)    ? 3  :
        (FIFO_DEPTH <= 16)   ? 4  :
        (FIFO_DEPTH <= 32)   ? 5  :
        (FIFO_DEPTH <= 64)   ? 6  :
        (FIFO_DEPTH <= 128)  ? 7  :
        (FIFO_DEPTH <= 256)  ? 8  :
        (FIFO_DEPTH <= 512)  ? 9  :
        (FIFO_DEPTH <= 1024) ? 10 :
        (FIFO_DEPTH <= 2048) ? 11 :
        (FIFO_DEPTH <= 4096) ? 12 :
        (FIFO_DEPTH <= 8192) ? 13 :
        (FIFO_DEPTH <= 16384)? 14 :
        (FIFO_DEPTH <= 32768)? 15 :
        (FIFO_DEPTH <= 65536)? 16 :
        0;

//=============================================================================
// 存储与指针
//=============================================================================
    reg  [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    wire [ADDR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg  [ADDR_WIDTH:0]   wr_ptr_ext, rd_ptr_ext;

//=============================================================================
// 写入控制
//=============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_ext <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;
            wr_ptr_ext  <= wr_ptr_ext + 1;
        end
    end

//=============================================================================
// 读出控制
//=============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_ext <= 0;
        end else if (rd_en && !empty) begin
            rd_data    <= mem[rd_ptr];
            rd_ptr_ext <= rd_ptr_ext + 1;
        end
    end

//=============================================================================
// 空满判断
//=============================================================================
    assign wr_ptr = wr_ptr_ext[ADDR_WIDTH-1:0];
    assign rd_ptr = rd_ptr_ext[ADDR_WIDTH-1:0];
    // 读出指针追上写入指针,表示此时FIFO已空
    assign empty  = (wr_ptr_ext == rd_ptr_ext);
    // 写入指针多跑一轮FIFO_DEPTH后追上读出指针,表示此时FIFO已满
    assign full   = (wr_ptr_ext == {~rd_ptr_ext[ADDR_WIDTH], rd_ptr_ext[ADDR_WIDTH-1:0]});

endmodule
