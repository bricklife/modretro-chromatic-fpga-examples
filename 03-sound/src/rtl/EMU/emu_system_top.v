// Sound demo. Same ports as the Game Boy core so top.v can stay unchanged.
//
// Keys play C4-C5 through sine_key_synth while held. The LCD is a 160x144
// oscilloscope of that sine: y = sin(phase + x*k), with k proportional to
// the DDS step so higher notes show more cycles. Phase is latched at the
// start of each frame so the trace does not tear. Silence is a flat line
// at mid-screen (sample 0).

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
    localparam [7:0] WAVE_MID      = 8'd72;
    // Spatial step = audio_step * SCALE. 802 puts ~2 cycles of C4 (and ~4 of
    // C5) across 160 pixels: 160 * 66976 * 802 / 2^32 ≈ 2.
    localparam [9:0] VIS_SCALE     = 10'd802;
    localparam [14:0] COL_BG       = 15'b00000_00000_00000;
    localparam [14:0] COL_WAVE     = 15'b00000_11111_00000;

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
    reg [1:0] sel_sync, start_sync;
    always @(posedge hclk or negedge reset_n) begin
        if (!reset_n) begin
            a_sync <= 2'b00;
            b_sync <= 2'b00;
            up_sync <= 2'b00;
            down_sync <= 2'b00;
            left_sync <= 2'b00;
            right_sync <= 2'b00;
            sel_sync <= 2'b00;
            start_sync <= 2'b00;
        end else begin
            a_sync <= {a_sync[0], BTN_A};
            b_sync <= {b_sync[0], BTN_B};
            up_sync <= {up_sync[0], BTN_DPAD_UP};
            down_sync <= {down_sync[0], BTN_DPAD_DOWN};
            left_sync <= {left_sync[0], BTN_DPAD_LEFT};
            right_sync <= {right_sync[0], BTN_DPAD_RIGHT};
            sel_sync <= {sel_sync[0], BTN_SEL};
            start_sync <= {start_sync[0], BTN_START};
        end
    end

    wire signed [15:0] tone;
    wire [31:0] dds_phase;
    wire [31:0] dds_step;
    reg [7:0] lut_index;
    wire signed [15:0] lut_q;

    sine_key_synth u_sine_key_synth (
        .clk(hclk),
        .reset_n(reset_n),
        .enable(run),
        .btn_left(left_sync[1]),
        .btn_down(down_sync[1]),
        .btn_up(up_sync[1]),
        .btn_right(right_sync[1]),
        .btn_sel(sel_sync[1]),
        .btn_start(start_sync[1]),
        .btn_b(b_sync[1]),
        .btn_a(a_sync[1]),
        .sample(tone),
        .dds_phase(dds_phase),
        .dds_step(dds_step),
        .lut_index(lut_index),
        .lut_q(lut_q)
    );

    assign left = tone;
    assign right = tone;

    // hclk is 16.777 MHz. One Game Boy dot is four hclk cycles.
    reg [1:0] phase;
    reg [8:0] dot;
    reg [7:0] ly;
    wire ce = (phase == 2'd3);

    always @(posedge hclk or negedge reset_n) begin
        if (!reset_n) begin
            phase <= 2'd0;
            dot <= 9'd0;
            ly <= 8'd0;
        end else if (!run) begin
            phase <= 2'd0;
            dot <= 9'd0;
            ly <= 8'd0;
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
        end
    end

    wire visible_line = (ly < VISIBLE_LINES);
    wire in_pixels = visible_line && (dot >= PIXEL_START) && (dot < PIXEL_END);

    // One multiply per frame, then an adder per pixel. phase_frame is held
    // for the whole frame so the trace does not tear.
    reg [31:0] phase_frame;
    reg [27:0] vis_step;
    reg [31:0] wave_ph;
    reg signed [15:0] s0_r;
    reg signed [15:0] s1_r;

    wire [27:0] vis_step_next = dds_step[17:0] * VIS_SCALE;
    wire [31:0] wave_ph_next = wave_ph + vis_step;

    always @(posedge hclk or negedge reset_n) begin
        if (!reset_n) begin
            phase_frame <= 32'd0;
            vis_step    <= 28'd0;
            wave_ph     <= 32'd0;
            lut_index   <= 8'd0;
            s0_r        <= 16'sd0;
            s1_r        <= 16'sd0;
        end else if (!run) begin
            phase_frame <= 32'd0;
            vis_step    <= 28'd0;
            wave_ph     <= 32'd0;
            lut_index   <= 8'd0;
            s0_r        <= 16'sd0;
            s1_r        <= 16'sd0;
        end else begin
            if (ce && (ly == 8'd0) && (dot == 9'd0)) begin
                phase_frame <= dds_phase;
                vis_step    <= vis_step_next;
            end

            // Reload at the first visible pixel of every line. Otherwise
            // advance once per pixel, at the same edge that leaves that pixel.
            if (phase == 2'd3 && (ly < VISIBLE_LINES) && (dot == PIXEL_START - 9'd1))
                wave_ph <= phase_frame;
            else if (phase == 2'd3 && in_pixels && (dot != PIXEL_END - 9'd1))
                wave_ph <= wave_ph + vis_step;

            // One ROM port, two samples: address at phase 0 and 1, data
            // lands the next cycle, both are held by phase 3.
            if (phase == 2'd0)
                lut_index <= wave_ph[31:24];
            if (phase == 2'd1) begin
                s0_r <= lut_q;
                lut_index <= wave_ph_next[31:24];
            end
            if (phase == 2'd2)
                s1_r <= lut_q;
        end
    end

    wire signed [7:0] amp0 = s0_r[15:8];
    wire signed [7:0] amp1 = s1_r[15:8];
    wire signed [8:0] y0 = $signed({1'b0, WAVE_MID}) - amp0;
    wire signed [8:0] y1 = $signed({1'b0, WAVE_MID}) - amp1;
    wire signed [8:0] y_lo = (y0 < y1) ? y0 : y1;
    wire signed [8:0] y_hi = (y0 < y1) ? y1 : y0;
    wire on_wave = ({1'b0, ly} >= y_lo) && ({1'b0, ly} <= y_hi);

    assign gb_lcd_clkena = run && ce && in_pixels;
    assign gb_lcd_data = on_wave ? COL_WAVE : COL_BG;
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
    assign gbc_mode = 1'b0;
    assign gpd = 64'd0;

    // Ports kept so top.v does not change. The demo does not use them.
    wire _unused_inputs = &{1'b0,
        pclk, fclk, xclk,
        customPaletteEna, paletteOff,
        paletteBGIn, paletteOBJ0In, paletteOBJ1In,
        gbc_color_temp,
        BTN_NODIAGONAL, BTN_MENU, MENU_CLOSED,
        CART_D_IN, IR_RX, LINK_IN};
    wire _unused_sink = _unused_inputs;

endmodule
