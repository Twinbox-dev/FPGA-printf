module top (
    input  clk,
    input  rst_n,
    output uart_tx
);

    reg        wr_en;
    reg  [7:0] data_in;

    // "Hello World!\r\n"
    localparam STR_LEN = 14;
    reg [7:0] str [0:STR_LEN-1];
    initial begin
        str[0]  = "H";   str[1]  = "e";  str[2]  = "l";  str[3]  = "l";
        str[4]  = "o";   str[5]  = " ";  str[6]  = "W";  str[7]  = "o";
        str[8]  = "r";   str[9]  = "l";  str[10] = "d";  str[11] = "!";
        str[12] = 8'h0D; str[13] = 8'h0A;
    end

    reg [3:0] idx;
    reg       done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en   <= 1'b0;
            data_in <= 8'h00;
            idx     <= 4'd0;
            done    <= 1'b0;
        end else if (!done) begin
            wr_en   <= 1'b1;
            data_in <= str[idx];
            if (idx == STR_LEN - 1)
                done <= 1'b1;
            else
                idx  <= idx + 1'b1;
        end else begin
            wr_en <= 1'b0;
        end
    end

    write #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (1_000_000),
        .DATA_WIDTH(8),
        .FIFO_DEPTH(1024)
    ) u_write (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (wr_en),
        .data_in(data_in),
        .full   (),
        .empty  (),
        .tx     (uart_tx)
    );

endmodule
