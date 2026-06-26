module unpacker#(
    parameter DATA_WIDTH = 64
)(
    // 8位控制位 + 64位数据
    input clk,
    input rst_n,
    input [7:0] ctrl,
    input [DATA_WIDTH-1:0]  data_in,

    // 输出[8:0]byteX 最高位表示字有效
    output priority_or_not,
    output clear_cache_FIFO,
    output [8:0] byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7
    
); 

    assign byte0 = {(ctrl[2:0] >= 0) ? 1'b0:1'b1, data_in[ 7: 0]};
    assign byte1 = {(ctrl[2:0] >= 1) ? 1'b0:1'b1, data_in[15: 8]};
    assign byte2 = {(ctrl[2:0] >= 2) ? 1'b0:1'b1, data_in[23:16]};
    assign byte3 = {(ctrl[2:0] >= 3) ? 1'b0:1'b1, data_in[31:24]};  
    assign byte4 = {(ctrl[2:0] >= 4) ? 1'b0:1'b1, data_in[39:32]};    
    assign byte5 = {(ctrl[2:0] >= 5) ? 1'b0:1'b1, data_in[47:40]};   
    assign byte6 = {(ctrl[2:0] >= 6) ? 1'b0:1'b1, data_in[55:48]};
    assign byte7 = {(ctrl[2:0] >= 7) ? 1'b0:1'b1, data_in[63:56]};

    assign priority_or_not  = ctrl[7];
    assign clear_cache_FIFO = ctrl[6];

endmodule