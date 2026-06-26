# UART printf — FPGA 调试打印模块套件

一套基于 Verilog 的 UART 调试打印模块，专为 FPGA 开发中的实时调试设计。
自动检测数据变化，经 FIFO 缓存 + UART 串口输出到上位机，无需额外逻辑分析仪。

## 模块概览

| 文件 | 模块 | 功能 |
|------|------|------|
| `FIFO.v` | `sync_fifo` | 同步 FIFO，参数化深度/位宽，扩展指针法判空满 |
| `UART TX.v` | `tx` | 单字节 UART 串行器（1 起始位 + 8 数据位 LSB 优先 + 1 停止位） |
| `unpacker.v` | `unpacker` | 字节拆包与控制位解码器，将数据拆为 8 个独立字节 |
| `printf.v` | `printf` | **顶层模块**，整合 FIFO / unpacker / UART TX 全链路 |
| `top example.v` | `top` | 使用示例，展示各种位宽和优先级模式的调用方式 |

## 数据流

```
data_in[71:0]
    │
    ├─ ctrl[7:0] → unpacker 解码 priority / clear / byte_cnt
    │
    └─ data[63:0] → cache FIFO
                        │
                   unpacker 拆字节
                        │
                   custom FIFO (8bit)
                        │
                     UART TX → tx 串行输出
```

优先级数据（ctrl[7]=1）走独立的 priority FIFO，绕过 cache → custom 搬运链路，确保关键数据优先发送。

## 快速使用

```verilog
// 1. 实例化 printf
reg [71:0] data_in;

printf #(
    .FIFO_DEPTH(1024)
) u_printf (
    .clk    (clk),
    .rst_n  (rst_n),
    .tx     (uart_tx),
    .data_in(data_in)
);

// 2. 赋值 data_in 即可自动发送
data_in <= {8'h02, 32'hDEADBEEF, 32'b0};
```

### data_in 格式

```
data_in[71:64] = ctrl
  [7]   priority    — 1=走优先级 FIFO，保证输出
  [6]   clear       — 1=清空 cache FIFO
  [5:3] reserved
  [2:0] byte_cnt    — 有效字节数-1（000=1byte, 111=8byte）

data_in[63:0] = data（大端序，有效字节放在高位）
```

详细控制位说明见 `unpacker.v` 头注释。

## 子模块说明

### sync_fifo (`FIFO.v`)
- 同步 FIFO，单时钟域
- `DATA_WIDTH` / `FIFO_DEPTH` 可参数化，深度须为 2^N
- 扩展指针法判空满（`wr_ptr_ext` 比地址多 1bit）

### tx (`UART TX.v`)
- 纯物理层 UART 发送，无 FIFO 无缓存
- `trigger` 上升沿启动，`busy` 高电平表示发送中
- 参数化 `CLK_FREQ` / `BAUD_RATE`

### unpacker (`unpacker.v`)
- 将 DATA_WIDTH 位宽数据拆为 8 个独立字节
- 从 ctrl 总线解码出 priority / clear / byte_cnt 控制信号
- 字节序号与地址位一一对应（byteN = data_in[8*N+7 : 8*N]）

## 开发环境

- 仿真 / 综合：Vivado、Quartus、Verilator 等任意 Verilog 工具链
- 上位机串口接收：任意串口终端（115200+ 波特率）

## 许可证

MIT
