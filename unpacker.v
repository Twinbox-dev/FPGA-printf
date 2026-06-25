module unpacker#(
    parameter DATA_WIDTH = 64
)(
    input clk,
    input rst_n,
    input [7:0] ctrl,
    input [DATA_WIDTH-1:0]  data_in,

    output priority_or_not,
    output clear_cache_FIFO,
    output reg [1:0] valid_byte,
    output reg [DATA_WIDTH-1:0]  data_out,
    
); 

assign data_out = {
    data_in[7:0],   // 最低字节 → unpack_byte[7]
    data_in[15:8],  //              unpack_byte[6]
    data_in[23:16], //              unpack_byte[5]
    data_in[31:24], //              unpack_byte[4]
    data_in[39:32], //              unpack_byte[3]
    data_in[47:40], //              unpack_byte[2]
    data_in[55:48], //              unpack_byte[1]
    data_in[63:56]  // 最高字节 → unpack_byte[0]
};

endmodule