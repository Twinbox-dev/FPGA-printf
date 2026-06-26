//=============================================================================
// Module Name : unpacker
// Description : 字节拆包与控制位解码器
//               将 DATA_WIDTH 位宽的数据拆分为 8 个独立字节（byte0~byte7），
//               同时从 ctrl 总线中解码出 priority、clear、byte_cnt 等控制信号。
//
//               本模块承担了 printf.v 中的"控制位解析"职责，将其解耦出来后，
//               printf.v 不再需要关心 ctrl 每一位的语义。
//
// Parameters:
//   DATA_WIDTH : 输入数据位宽（bit），默认 64；8 字节拆分时请确保 ≥ 64
//
// Interface:
//   data_in           : 输入数据总线，位宽 DATA_WIDTH
//   ctrl[7:0]         : 控制位总线（详见 Ctrl Bit Field）
//   byte0~byte7       : 拆分后的 8 个字节
//                         byte0 = data_in[ 7: 0]  (LSB)
//                         byte1 = data_in[15: 8]
//                         ...
//                         byte7 = data_in[63:56]  (MSB)
//                       即：字节序号与地址位一一对应
//                       （byteN = data_in[8*N+7 : 8*N]），
//                       外部按 byte0→byte7 顺序发送即可还原为大端字节序。
//   priority_or_not   : 高电平表示走优先级 FIFO（ctrl[7]）
//   clear_cache_FIFO  : 高电平表示清空 cache FIFO（ctrl[6]）
//   cnt[2:0]          : 有效字节数 - 1（ctrl[2:0]），控制后续发送几个 byte
//
// Ctrl Bit Field:
//   ctrl[7]   - priority    : 1=走优先级 FIFO，保证输出
//   ctrl[6]   - clear       : 1=瞬间清空 cache FIFO（有风险，谨慎使用）
//   ctrl[5:3] - reserved    : 保留，暂未使用
//   ctrl[2:0] - byte_cnt    : 有效字节数 - 1（000=1byte, 111=8byte）
//
// Author     : [Boxchan]
// Date       : [2026-06-26]
// Version    : V3.0
//=============================================================================

module unpacker #(
    parameter DATA_WIDTH = 64
)(
    input  [7:0]            ctrl,
    input  [DATA_WIDTH-1:0] data_in,

    output                  priority_or_not,
    output                  clear_cache_FIFO,
    output [2:0]            cnt,
    output [7:0] byte0, byte1, byte2, byte3,
                byte4, byte5, byte6, byte7
);

//=============================================================================
// 字节拆分
//   byteN = data_in[8*N+7 : 8*N]   (N=0..7)
//   按 byte0→byte7 发送可还原为大端序
//=============================================================================
    assign byte0 = data_in[ 7: 0];
    assign byte1 = data_in[15: 8];
    assign byte2 = data_in[23:16];
    assign byte3 = data_in[31:24];
    assign byte4 = data_in[39:32];
    assign byte5 = data_in[47:40];
    assign byte6 = data_in[55:48];
    assign byte7 = data_in[63:56];

//=============================================================================
// 控制位解码
//=============================================================================
    assign priority_or_not  = ctrl[7];
    assign clear_cache_FIFO = ctrl[6];
    assign cnt              = ctrl[2:0];

endmodule
