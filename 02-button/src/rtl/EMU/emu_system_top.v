// Square demo. Same ports as the Game Boy core so top.v can stay unchanged.
//
// vid_system_top and ST7785_panel_master still expect a Game Boy LCD stream
// on hclk: 456 dots/line at hclk/4, 160 pixels, 144 lines, then 10 blank
// lines. gb_lcd_mode[1] is high during the pixel burst and falls after the
// 160th pixel. gb_lcd_vsync is high for line 0. RGB555 is
// {blue[4:0], green[4:0], red[4:0]}.
//
// A 16x16 square starts in the middle. The d-pad moves it one pixel per
// frame. A turns it red, B turns it blue, and both together turn it magenta.

module emu_system_top
(
    input               hclk,
    input               pclk,
    input               fclk,
    input               xclk,
    input               reset_n,
    input               POWER_GOOD,

    input               customPaletteEna,
    input [63:0]        paletteBGIn,
    input [63:0]        paletteOBJ0In,
    input [63:0]        paletteOBJ1In,
    input [2:0]         gbc_color_temp,
    input               paletteOff,
    output              gbc_mode,
    output [63:0]       gpd,

    input               BTN_NODIAGONAL,
    input               BTN_A,
    input               BTN_B,
    input               BTN_DPAD_DOWN,
    input               BTN_DPAD_LEFT,
    input               BTN_DPAD_RIGHT,
    input               BTN_DPAD_UP,
    input               BTN_MENU,
    input               BTN_SEL,
    input               BTN_START,
    input               MENU_CLOSED,
    output              boot_rom_enabled,
    output  [15:0]      CART_A,
    output              CART_CLK,
    output              CART_CS,
    input   [7:0]       CART_D_IN,
    output  [7:0]       CART_D_OUT,
    output              CART_RD,
    output              CART_WR,
    output              CART_DATA_DIR_E,

    input               IR_RX,
    output              IR_LED,

    inout               LINK_CLK,
    output              LINK_CLK_DIR_LV,
    input               LINK_IN,
    output              LINK_OUT,

    output [15:0]       left,
    output [15:0]       right,

    output              lcd_on_int,
    output              lcd_off_overwrite,

    input               LCD_INIT_DONE,
    output              gb_lcd_clkena,
    output [14:0]       gb_lcd_data,
    output [1:0]        gb_lcd_mode,
    output              gb_lcd_on,
    output              gb_lcd_vsync,

    input               latched_cart_rst_n,
    output              o_emulator_reset
);

    localparam [8:0] DOTS_PER_LINE = 9'd456;
    localparam [8:0] PIXEL_START   = 9'd80;
    localparam [8:0] PIXEL_END     = 9'd240; // 80 + 160
    localparam [7:0] VISIBLE_LINES = 8'd144;
    localparam [7:0] TOTAL_LINES   = 8'd154;
    localparam [7:0] SQUARE        = 8'd16;
    localparam [7:0] SQUARE_X0     = 8'd72;  // (160 - 16) / 2
    localparam [7:0] SQUARE_Y0     = 8'd64;  // (144 - 16) / 2
    localparam [7:0] SQUARE_X_MAX  = 8'd144; // 160 - 16
    localparam [7:0] SQUARE_Y_MAX  = 8'd128; // 144 - 16

    localparam [14:0] COL_BG    = 15'b00100_00100_00100;
    localparam [14:0] COL_IDLE  = 15'b11111_11111_11111;
    localparam [14:0] COL_A     = 15'b00000_00000_11111;
    localparam [14:0] COL_B     = 15'b11111_00000_00000;
    localparam [14:0] COL_AB    = 15'b11111_00000_11111;

    // The panel stays black while this is high, and the backlight stays off
    // while boot_rom_enabled is high. Wait until the LCD init and the
    // cartridge power sequence have finished.
    reg [1:0] lcd_sync;
    reg [1:0] pwr_sync;
    reg [1:0] cart_rst_sync;
    always @(posedge hclk or negedge reset_n) begin
        if (!reset_n) begin
            lcd_sync <= 2'b00;
            pwr_sync <= 2'b00;
            cart_rst_sync <= 2'b00;
        end else begin
            lcd_sync <= {lcd_sync[0], LCD_INIT_DONE};
            pwr_sync <= {pwr_sync[0], POWER_GOOD};
            cart_rst_sync <= {cart_rst_sync[0], latched_cart_rst_n};
        end
    end

    wire run = lcd_sync[1] & pwr_sync[1] & cart_rst_sync[1];
    assign o_emulator_reset = ~run;
    assign boot_rom_enabled = 1'b0;
    assign gb_lcd_on = run;
    assign lcd_on_int = run;
    assign lcd_off_overwrite = 1'b0;

    // Buttons are already debounced on gclk. Sample them into hclk.
    reg [1:0] a_sync, b_sync, up_sync, down_sync, left_sync, right_sync;
    always @(posedge hclk or negedge reset_n) begin
        if (!reset_n) begin
            a_sync <= 2'b00;
            b_sync <= 2'b00;
            up_sync <= 2'b00;
            down_sync <= 2'b00;
            left_sync <= 2'b00;
            right_sync <= 2'b00;
        end else begin
            a_sync <= {a_sync[0], BTN_A};
            b_sync <= {b_sync[0], BTN_B};
            up_sync <= {up_sync[0], BTN_DPAD_UP};
            down_sync <= {down_sync[0], BTN_DPAD_DOWN};
            left_sync <= {left_sync[0], BTN_DPAD_LEFT};
            right_sync <= {right_sync[0], BTN_DPAD_RIGHT};
        end
    end

    wire btn_a = a_sync[1];
    wire btn_b = b_sync[1];
    wire btn_up = up_sync[1];
    wire btn_down = down_sync[1];
    wire btn_left = left_sync[1];
    wire btn_right = right_sync[1];

    // hclk is 16.777 MHz. One Game Boy dot is four hclk cycles.
    reg [1:0] phase;
    reg [8:0] dot;
    reg [7:0] ly;
    reg [7:0] sq_x;
    reg [7:0] sq_y;
    wire ce = (phase == 2'd3);

    wire frame_end = ce && (dot == DOTS_PER_LINE - 9'd1) && (ly == TOTAL_LINES - 8'd1);

    always @(posedge hclk or negedge reset_n) begin
        if (!reset_n) begin
            phase <= 2'd0;
            dot <= 9'd0;
            ly <= 8'd0;
            sq_x <= SQUARE_X0;
            sq_y <= SQUARE_Y0;
        end else if (!run) begin
            phase <= 2'd0;
            dot <= 9'd0;
            ly <= 8'd0;
            sq_x <= SQUARE_X0;
            sq_y <= SQUARE_Y0;
        end else begin
            phase <= phase + 2'd1;

            if (ce) begin
                if (dot == DOTS_PER_LINE - 9'd1) begin
                    dot <= 9'd0;
                    if (ly == TOTAL_LINES - 8'd1)
                        ly <= 8'd0;
                    else
                        ly <= ly + 8'd1;
                end else begin
                    dot <= dot + 9'd1;
                end
            end

            if (frame_end) begin
                if (btn_right && !btn_left && (sq_x < SQUARE_X_MAX))
                    sq_x <= sq_x + 8'd1;
                else if (btn_left && !btn_right && (sq_x != 8'd0))
                    sq_x <= sq_x - 8'd1;

                if (btn_down && !btn_up && (sq_y < SQUARE_Y_MAX))
                    sq_y <= sq_y + 8'd1;
                else if (btn_up && !btn_down && (sq_y != 8'd0))
                    sq_y <= sq_y - 8'd1;
            end
        end
    end

    wire visible_line = (ly < VISIBLE_LINES);
    wire in_pixels = visible_line && (dot >= PIXEL_START) && (dot < PIXEL_END);
    wire [8:0] pix_x = dot - PIXEL_START;
    wire [8:0] sq_x_ext = {1'b0, sq_x};
    wire [8:0] sq_y_ext = {1'b0, sq_y};
    wire in_square = in_pixels &&
                     (pix_x >= sq_x_ext) && (pix_x < sq_x_ext + 9'd16) &&
                     ({1'b0, ly} >= sq_y_ext) && ({1'b0, ly} < sq_y_ext + 9'd16);

    wire [14:0] square_color =
        (btn_a && btn_b) ? COL_AB :
        btn_a            ? COL_A :
        btn_b            ? COL_B :
                           COL_IDLE;

    assign gb_lcd_clkena = run && ce && in_pixels;
    assign gb_lcd_data = in_square ? square_color : COL_BG;
    assign gb_lcd_vsync = run && (ly == 8'd0);
    assign gb_lcd_mode =
        (!run || !visible_line) ? 2'b01 :
        (dot < PIXEL_END)       ? (in_pixels ? 2'b11 : 2'b10) :
                                  2'b00;

    // Keep the cartridge, link, and audio pins idle. DIR_E high releases
    // the data bus so the FPGA does not drive the cartridge.
    assign CART_A = 16'd0;
    assign CART_CLK = 1'b0;
    assign CART_CS = 1'b1;
    assign CART_RD = 1'b1;
    assign CART_WR = 1'b1;
    assign CART_D_OUT = 8'd0;
    assign CART_DATA_DIR_E = 1'b1;
    assign IR_LED = 1'b0;
    assign LINK_CLK = 1'bz;
    assign LINK_CLK_DIR_LV = 1'b0;
    assign LINK_OUT = 1'b0;
    assign left = 16'd0;
    assign right = 16'd0;
    assign gbc_mode = 1'b0;
    assign gpd = 64'd0;

    // Ports kept so top.v does not change. The demo does not use them.
    wire _unused_inputs = &{1'b0,
        pclk, fclk, xclk,
        customPaletteEna, paletteOff,
        paletteBGIn, paletteOBJ0In, paletteOBJ1In,
        gbc_color_temp,
        BTN_NODIAGONAL, BTN_MENU, BTN_SEL, BTN_START, MENU_CLOSED,
        CART_D_IN, IR_RX, LINK_IN};
    wire _unused_sink = _unused_inputs;

endmodule
