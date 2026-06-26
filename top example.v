// 演示: printf 极简调用
// 业务只管 write <= value; 底层单周期推入 FIFO, 下一周期 write 即可复用

// todo:  `define printf(idx)\ write <= idx; 
// todo: 用宏/function封装操作,只暴露最简单的`printf(param)给用户

module top (
    input  clk,
    input  rst_n,
    output uart_tx
);

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 例化一次 (4 个信号)
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    reg [71:0] data_in;

    printf #(
        .FIFO_DEPTH(1024)
    ) u_printf (
        .clk(clk),
        .rst_n(rst_n),
        .tx(uart_tx),
        .data_in(data_in)
    );

    reg [31:0] cnt;
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 业务: 每计数到 100_000 打印一次
//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// 综合调试: 涵盖 cache 各宽度 + priority + clear
// data_in[71:64] = ctrl: [7]=prio [6]=clear [1:0]=width
// data_in[63:0]  = data (大端: 有效字节放在高位)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 0;
            data_in <= 0;
        end else begin
            cnt <= cnt + 1;

            case (cnt)
                // 1) cache 通路, width=32bit, data=0xDEADBEEF
                50_000: data_in <= {8'h02, 32'hDEADBEEF, 32'b0};

                // 2) priority 通路 (全 8 字节)
                150_000: data_in <= {8'h80, 64'hCAFEBABE_12345678};

                // 3) cache 通路, width=8bit, data=0xAB
                250_000: data_in <= {8'h00, 8'hAB, 56'b0};

                // 4) cache 通路, width=16bit, data=0xCDEF
                350_000: data_in <= {8'h01, 16'hCDEF, 48'b0};

                // 5) cache 通路, width=64bit
                450_000: data_in <= {8'h03, 64'h0123456789ABCDEF};

                // 6) cache 通路 + clear (先写数据, 然后清空)
                550_000: data_in <= {8'h02, 32'hAABBCCDD, 32'b0};
                650_000: data_in <= {8'h42, 32'hFFFFFFFF, 32'b0}; // ctrl[6]=1 → 清空

                // 7) clear 后验证 cache 是否正常
                750_000: data_in <= {8'h02, 32'h11223344, 32'b0};

                // 8) priority 再次验证
                850_000: data_in <= {8'h80, 64'h5555AAAA_FFFF0000};

                // 循环
                950_000: cnt <= cnt + 1;
            endcase
        end
    end

endmodule
