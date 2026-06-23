//=============================================================================
// dbg_printf - 极简调试打印模块
//
// 顶层例化:
//   dbg_printf #(.FMT_STR("pc=%x\r\n"), .FMT_LEN(7))
//   u_dbg (.clk, .rst_n, .write(pc), .tx(uart_tx));
//
// 业务逻辑只需:
//   write <= some_value;   // 模块自动检测变化, 格式化后串行发出
// 无需握手, 无需关注底层什么时候发完.
//
// 模块内部:
//   ① 空闲时检查 write 与上次打印值 last_printed 是否不同
//   ② 不同则锁存新值, 按 FMT_STR 模板做格式转换
//   ③ 字节写入内部 FIFO → UART TX 串行发出
//   ④ 格式转换期间 write 再变 → 不会丢失, 当前帧发完后回空闲重新检测
//
// Parameters:
//   CLK_FREQ  : 时钟频率
//   BAUD_RATE : 波特率
//   FMT_STR   : 格式模板, 如 "pc=%x\r\n"
//   FMT_LEN   : 模板字符数
//   VAL_WIDTH : write 位宽 (默认 32)
//
// 占位符: %x(hex, 全位宽), %d(dec, 抑制前导零), %b(bin), %%(%)
//=============================================================================

module dbg_printf #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 1_000_000,
    parameter FMT_STR   = "write=%x\r\n",
    parameter FMT_LEN   = 10,
    parameter VAL_WIDTH = 32
)(
    input                     clk,
    input                     rst_n,
    input  [VAL_WIDTH-1:0]    write,
    output                    tx
);

//============================================================================
// 内部例化 write (UART TX + FIFO)
//============================================================================
    wire        fifo_full, fifo_empty;
    reg         wr_en_int;
    reg  [7:0]  data_int;

    write #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_WIDTH(8),
        .FIFO_DEPTH(1024)
    ) u_write (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en_int),
        .data_in(data_int),
        .full(fifo_full),
        .empty(fifo_empty),
        .tx(tx)
    );

//============================================================================
// 常量 & 内部寄存器
//============================================================================
    localparam NIBBLES    = (VAL_WIDTH + 3) / 4;
    localparam BCD_DIGITS = 10;

    localparam CONV_HEX = 2'd0;
    localparam CONV_DEC = 2'd1;
    localparam CONV_BIN = 2'd2;

    reg [1:0] state;
    localparam S_IDLE = 2'd0;
    localparam S_SEND = 2'd1;
    localparam S_DONE = 2'd2;

    reg [VAL_WIDTH-1:0] last_printed;
    reg [31:0]          val_latched;
    reg [31:0]          fmt_idx;
    reg                 in_conv;
    reg [1:0]           conv_type;
    reg [5:0]           conv_cnt;

    reg [39:0]  bcd_buf;
    reg [5:0]   dec_shift;
    reg [5:0]   dec_sig;
    reg         dec_done;

//============================================================================
// 辅助函数
//============================================================================
    function [7:0] fmt_byte;
        input [31:0] idx;
        begin
            fmt_byte = FMT_STR >> ((FMT_LEN - 1 - idx) * 8);
        end
    endfunction

    function [7:0] nibble_ascii;
        input [3:0] n;
        begin
            nibble_ascii = (n < 10) ? ("0" + n) : ("A" + n - 10);
        end
    endfunction

    function [39:0] bcd_adjust;
        input [39:0] bcd;
        integer i;
        begin
            bcd_adjust = bcd;
            for (i = 0; i < BCD_DIGITS; i = i + 1)
                if (bcd_adjust[i*4 +: 4] >= 5)
                    bcd_adjust[i*4 +: 4] = bcd_adjust[i*4 +: 4] + 3;
        end
    endfunction

    function [5:0] count_sig_digits;
        input [39:0] bcd;
        integer i;
        reg found;
        begin
            found = 0;
            count_sig_digits = 1;
            for (i = BCD_DIGITS - 1; i >= 0; i = i - 1)
                if (!found)
                    if (bcd[i*4 +: 4] != 0) begin
                        count_sig_digits = i + 1;
                        found = 1;
                    end
        end
    endfunction

//============================================================================
// 主状态机 (单 always, 无多驱动)
//============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            wr_en_int    <= 0;
            data_int     <= 8'h00;
            fmt_idx      <= 0;
            val_latched  <= 0;
            in_conv      <= 0;
            conv_type    <= 0;
            conv_cnt     <= 0;
            bcd_buf      <= 0;
            dec_shift    <= 0;
            dec_sig      <= 0;
            dec_done     <= 0;
            last_printed <= 0;
        end else begin
            wr_en_int <= 0;

            case (state)
                // ═══════════ IDLE: 空闲检测 write 变化 ═══════════
                S_IDLE: begin
                    if (write != last_printed) begin
                        val_latched  <= write;
                        last_printed <= write;
                        fmt_idx      <= 0;
                        in_conv      <= 0;
                        dec_shift    <= 0;
                        bcd_buf      <= 0;
                        dec_done     <= 0;
                        state        <= S_SEND;
                    end
                end

                // ═══════════ SEND: 按格式串逐字节写入 FIFO ═══════════
                S_SEND: begin
                    if (fifo_full) begin
                        // FIFO 已满, 等待
                    end else if (in_conv) begin
                        // -- 正在输出格式转换的字节 --
                        case (conv_type)
                            CONV_HEX, CONV_BIN: begin
                                if (conv_cnt > 0) begin
                                    wr_en_int <= 1;
                                    conv_cnt  <= conv_cnt - 1;
                                    if (conv_type == CONV_HEX)
                                        data_int <= nibble_ascii(
                                            val_latched[(conv_cnt-1)*4 +: 4]);
                                    else
                                        data_int <= val_latched[conv_cnt-1] ?
                                            8'h31 : 8'h30;
                                end else begin
                                    in_conv <= 0;
                                end
                            end

                            CONV_DEC: begin
                                if (!dec_done) begin
                                    // 双倍 dabble 转换
                                    if (dec_shift < VAL_WIDTH) begin
                                        bcd_buf   <= {bcd_adjust(bcd_buf)[38:0],
                                                      val_latched[VAL_WIDTH-1 - dec_shift]};
                                        dec_shift <= dec_shift + 1;
                                    end else begin
                                        dec_done <= 1;
                                        dec_sig  <= count_sig_digits(bcd_buf);
                                    end
                                end else if (dec_sig > 0) begin
                                    wr_en_int <= 1;
                                    data_int  <= "0" + bcd_buf[(dec_sig-1)*4 +: 4];
                                    dec_sig   <= dec_sig - 1;
                                end else begin
                                    in_conv <= 0;
                                end
                            end
                        endcase

                    end else begin
                        // -- 正常解析格式串 --
                        if (fmt_idx >= FMT_LEN) begin
                            state <= S_DONE;
                        end else if (fmt_byte(fmt_idx) == "%" &&
                                     fmt_idx + 1 < FMT_LEN) begin
                            case (fmt_byte(fmt_idx + 1))
                                "x": begin
                                    conv_type <= CONV_HEX;
                                    conv_cnt  <= NIBBLES;
                                    in_conv   <= 1;
                                    fmt_idx   <= fmt_idx + 2;
                                end
                                "d": begin
                                    conv_type <= CONV_DEC;
                                    in_conv   <= 1;
                                    dec_shift <= 0;
                                    bcd_buf   <= 0;
                                    dec_done  <= 0;
                                    dec_sig   <= 0;
                                    fmt_idx   <= fmt_idx + 2;
                                end
                                "b": begin
                                    conv_type <= CONV_BIN;
                                    conv_cnt  <= VAL_WIDTH;
                                    in_conv   <= 1;
                                    fmt_idx   <= fmt_idx + 2;
                                end
                                "%": begin
                                    wr_en_int <= 1;
                                    data_int  <= "%";
                                    fmt_idx   <= fmt_idx + 2;
                                end
                                default: begin
                                    wr_en_int <= 1;
                                    data_int  <= fmt_byte(fmt_idx);
                                    fmt_idx   <= fmt_idx + 1;
                                end
                            endcase
                        end else begin
                            wr_en_int <= 1;
                            data_int  <= fmt_byte(fmt_idx);
                            fmt_idx   <= fmt_idx + 1;
                        end
                    end
                end

                // ═══════════ DONE: 转回 IDLE, 自动重检 write ═══════════
                S_DONE: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
