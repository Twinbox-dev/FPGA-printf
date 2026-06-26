module unpacker#(
    parameter DATA_WIDTH = 64
)(
    // 8位控制位 + 64位数据
    input [7:0] ctrl,
    input [DATA_WIDTH-1:0]  data_in,

    output priority_or_not,
    output clear_cache_FIFO,
    output [2:0] cnt,
    output [7:0] byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7
    
); 

    assign byte0 = data_in[ 7: 0];
    assign byte1 = data_in[15: 8];
    assign byte2 = data_in[23:16];
    assign byte3 = data_in[31:24];
    assign byte4 = data_in[39:32];
    assign byte5 = data_in[47:40];
    assign byte6 = data_in[55:48];
    assign byte7 = data_in[63:56];

    // 目前决定最高位[7]表示是否写入priority FIFO + [2:0]表示字有效(控制8个byte) + [6]表示瞬间清空cache FIFO(很危险但个人觉得有必要) + 其他位置暂时保留
    assign priority_or_not  = ctrl[7];
    assign clear_cache_FIFO = ctrl[6];
    assign cnt = ctrl[2:0];

endmodule