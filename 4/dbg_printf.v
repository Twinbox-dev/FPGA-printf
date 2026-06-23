//=============================================================================
// dbg_printf - 共享调试打印模块 (单实例, 双接口)
//
// 顶层例化一次, 所有需要打印的业务逻辑共享此模块:
//
//   dbg_printf #(.FMT_STR("my_reg=%x\r\n"), .FMT_LEN(12))
//   u_dbg (.clk, .rst_n, .tx(uart_tx),
//          .fmt_trig(my_trig), .fmt_val(some_val), .fmt_busy(),
//          .push_en(), .push_data(), .push_full());
//
// 【接口 A - 自动格式化 (推荐)】
//   业务逻辑只管给 fmt_val + 脉冲 fmt_trig, 模块按 FMT_STR 模板
//   自动做 hex/dec/bin 转换并推送 FIFO, busy 期间忽略新触发.
//
// 【接口 B - 逐字节直写】
//   需要推固定字符串时使用, push_en/push_data 直通内部 FIFO.
//   当 fmt_busy 或 fifo_full 时 push_full=1, 业务需等待.
//
// Parameters:
//   CLK_FREQ  : 时钟频率
//   BAUD_RATE : 波特率
//   FMT_STR   : 格式模板, 如 "reg=%x\r\n"
//   FMT_LEN   : 模板字符数
//   VAL_WIDTH : fmt_val 位宽
//
// 占位符: %x(hex), %d(dec), %b(bin), %%(%)
//=============================================================================

module dbg_printf #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 1_000_000,
    parameter FMT_STR   = "dbg=%x\r\n",
    parameter FMT_LEN   = 8,
    parameter VAL_WIDTH = 32
)(
    input  clk,
    input  rst_n,

    // 接口 A: 自动格式化
    input             fmt_trig,
    input  [VAL_WIDTH-1:0] fmt_val,
    output reg        fmt_busy,

    // 接口 B: 逐字节直写 (fmt_busy=0 时才可推入)
    input  [7:0]      push_data,
    input             push_en,
    output            push_full,

    // UART
    output            tx
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
// 仲裁: 格式化器忙时让格式化器写 FIFO, 否则让外部直写
//============================================================================
    reg        fmt_wr_en;
    reg [7:0]  fmt_data;

    assign push_full = fifo_full | fmt_busy;
    assign wr_en_int = fmt_busy ? fmt_wr_en : (push_en | fmt_wr_en);
    assign data_int  = fmt_busy ? fmt_data  : (fmt_wr_en ? fmt_data : push_data);

//============================================================================
// 常量 & 内部寄存器
//============================================================================
    localparam NIBBLES    = (VAL_WIDTH + 3) / 4;
    localparam BCD_DIGITS = 10;

    localparam CONV_HEX = 2'd0;
    localparam CONV_DEC = 2'd1;
    localparam CONV_BIN = 2'd2;

    reg trigger_d;
    wire trigger_rise = fmt_trig && !trigger_d;

    reg [1:0] state;
    localparam S_IDLE = 2'd0;
    localparam S_SEND = 2'd1;
    localparam S_DONE = 2'd2;

    reg [31:0]  fmt_idx;
    reg [31:0]  val_latched;
    reg         in_conv;
    reg [1:0]   conv_type;
    reg [5:0]   conv_cnt;

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
// 主状态机
//============================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            fmt_busy     <= 0;
            fmt_wr_en    <= 0;
            fmt_data     <= 8'h00;
            trigger_d    <= 0;
            fmt_idx      <= 0;
            val_latched  <= 0;
            in_conv      <= 0;
            conv_type    <= 0;
            conv_cnt     <= 0;
            bcd_buf      <= 0;
            dec_shift    <= 0;
            dec_sig      <= 0;
            dec_done     <= 0;
        end else begin
            trigger_d <= fmt_trig;
            fmt_wr_en <= 0;

            case (state)
                S_IDLE: begin
                    fmt_busy <= 0;
                    if (trigger_rise) begin
                        val_latched <= fmt_val;
                        fmt_idx     <= 0;
                        in_conv     <= 0;
                        dec_shift   <= 0;
                        bcd_buf     <= 0;
                        dec_done    <= 0;
                        state       <= S_SEND;
                        fmt_busy    <= 1;
                    end
                end

                S_SEND: begin
                    if (fifo_full) begin
                    end else if (in_conv) begin
                        case (conv_type)
                            CONV_HEX, CONV_BIN: begin
                                if (conv_cnt > 0) begin
                                    fmt_wr_en <= 1;
                                    conv_cnt  <= conv_cnt - 1;
                                    if (conv_type == CONV_HEX)
                                        fmt_data <= nibble_ascii(
                                            val_latched[(conv_cnt-1)*4 +: 4]);
                                    else
                                        fmt_data <= val_latched[conv_cnt-1] ?
                                            8'h31 : 8'h30;
                                end else begin
                                    in_conv <= 0;
                                end
                            end

                            CONV_DEC: begin
                                if (!dec_done) begin
                                    if (dec_shift < VAL_WIDTH) begin
                                        bcd_buf   <= {bcd_adjust(bcd_buf)[38:0],
                                                      val_latched[VAL_WIDTH-1 - dec_shift]};
                                        dec_shift <= dec_shift + 1;
                                    end else begin
                                        dec_done <= 1;
                                        dec_sig  <= count_sig_digits(bcd_buf);
                                    end
                                end else if (dec_sig > 0) begin
                                    fmt_wr_en <= 1;
                                    fmt_data  <= "0" + bcd_buf[(dec_sig-1)*4 +: 4];
                                    dec_sig   <= dec_sig - 1;
                                end else begin
                                    in_conv <= 0;
                                end
                            end
                        endcase

                    end else begin
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
                                    fmt_wr_en <= 1;
                                    fmt_data  <= "%";
                                    fmt_idx   <= fmt_idx + 2;
                                end
                                default: begin
                                    fmt_wr_en <= 1;
                                    fmt_data  <= fmt_byte(fmt_idx);
                                    fmt_idx   <= fmt_idx + 1;
                                end
                            endcase
                        end else begin
                            fmt_wr_en <= 1;
                            fmt_data  <= fmt_byte(fmt_idx);
                            fmt_idx   <= fmt_idx + 1;
                        end
                    end
                end

                S_DONE: begin
                    fmt_busy <= 0;
                    state    <= S_IDLE;
                end
            endcase
        end
    end

endmodule
