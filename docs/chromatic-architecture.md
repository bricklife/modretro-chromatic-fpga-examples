# ModRetro Chromatic: what the FPGA and the MCU each do

The FPGA is what puts a game on the screen. The ESP32 draws the settings menu and sends brightness, palettes, and the other settings to the FPGA. The USB port belongs to the FPGA as well. Wi-Fi and Bluetooth are present on the ESP32 chip and are unused by this published firmware.

This note was written from the public trees [oss-chromatic-console-fpga](https://github.com/ModRetro/oss-chromatic-console-fpga) (FPGA version register 18.14, Gowin GW5A-25) and [oss-chromatic-console-mcu](https://github.com/ModRetro/oss-chromatic-console-mcu) (ESP-IDF 5.3, package version string 4.5, app version 0.13.7). A console updated in the field can differ. In this examples repository the FPGA files live under each project (`01-lcd/src/top.v` and so on) instead of the upstream `esp32t/src/` prefix. The MCU sources are not copied here.

## Contents

- [Who owns what](#who-owns-what)
- [What the FPGA owns](#what-the-fpga-owns)
- [What the MCU owns](#what-the-mcu-owns)
- [How they talk](#how-they-talk)
- [USB port](#usb-port)
- [Wi-Fi and Bluetooth](#wi-fi-and-bluetooth)
- [Boot sequence](#boot-sequence)
- [Management UART packets](#management-uart-packets)
- [Pins the RTL does not read](#pins-the-rtl-does-not-read)
- [Where to attach a sample](#where-to-attach-a-sample)

## Who owns what

When the power switch turns on, the FPGA configures from its bitstream and directly runs the Game Boy / Game Boy Color core, the LCD, the audio codec, the cartridge, and USB. The FPGA then enables the ESP32, which owns the menu and the saved settings.

| Function | Owner | What it actually does |
|---|---|---|
| Game | FPGA | MiSTer-derived GB/GBC core (`gb.v`). CPU, PPU, APU, boot ROM, cartridge bus. Locked in CGB mode (`isGBC = 1`). |
| LCD | FPGA | Initializes the ST7785 over 3-wire SPI and scans it with an RGB666 dot clock. Frame blend, color correction, the low-battery frame, and OSD compositing are also in the FPGA. |
| OSD picture | MCU | LVGL draws 160×144. QSPI writes that frame into FPGA PSRAM, and the FPGA overlays it on the game picture. |
| Buttons | Both | A, B, D-pad, START, SELECT, and MENU are FPGA pins and are debounced there. During a game they go straight to the core. While the menu is open they are sent over UART and LVGL reads them. The MCU can OR extra buttons in for debugging. |
| Speaker / headphones | FPGA | Stereo from the core goes to the TLV320 over an I2S-like link. The volume wheel and headphone detect are polled from the codec over I2C. Only the silent setting comes from the MCU. |
| Cartridge | FPGA | Address, data, clock, reset, power, and the level shifters. Inserting or removing a cartridge resets the emulator. |
| Infrared | FPGA | The GBC RP register (`IR_LED` / `IR_RX`). The MCU is not involved. |
| Link cable | FPGA | GB serial (`LINK_CLK` / `LINK_IN` / `LINK_OUT`). A level shifter selects who drives the clock. |
| USB port | FPGA | USB 2.0 soft PHY. A composite device: video, game audio, and serial. The ESP32’s own USB controller is unused. |
| Power, charge, battery | Both | The FPGA owns the ADC, the BQ24296 charger, the TMP112 temperature sensor, the LED, and backlight PWM. The MCU receives voltage and charge state and draws the battery icon. |
| Saved settings | MCU | Brightness, mute, palettes, color temperature, player number, and the rest live in ESP32 NVS and are sent to the FPGA again at every boot. |
| Wi-Fi | Unused | The ESP32 radio hardware is there. This MCU source never calls `esp_wifi`, and nothing in the settings turns the radio on. |
| Bluetooth | Unused | Likewise, there is no Bluedroid or NimBLE init. It is not a controller or a headset. |

```text
 cartridge                         ST7785 LCD
 ROM / RAM / power                 RGB + backlight PWM
        \                               /
         \                             /
          +--------+ FPGA GW5A-25 +---+
          | GB/GBC core, video mix, USB|
          | cartridge, audio, battery  |
          | PSRAM frame buffer         |
          +-------------+--------------+
                        | management UART 115200
                        | and QSPI
                        v
                   ESP32 MCU
              menu, NVS, console

 TLV320 + PMIC                  USB port
 I2S audio / I2C                UVC video, UAC audio, CDC serial
```

## What the FPGA owns

The top module is `src/top.v` (`esp32t/src/top.v` upstream). `CLK_FPGA` is 33.554432 MHz (2^25 Hz). The PLL makes these domains:

| Signal | Frequency in the comments | Main use |
|---|---|---|
| `fClk` | about 150 MHz | Synchronizing cartridge detect, emulator internals |
| `xClk` | about 75 MHz | LED, cartridge-reset watch, memory |
| `pClk` | about 33.554 MHz | Extra button filtering, video |
| `hClk` | about 16.777 MHz | GB core `clk_sys`, cartridge power sequence |
| `gClk` | about 8.389 MHz | System monitor, management UART, USB reset delay, ESP32 enable |
| `CLK_24MHz` | 24 MHz | Reference into the USB soft-PHY PLL |

### Screen

`vid_system_top` initializes the ST7785 and expands the GB 15-bit color (RGB555) to 6 bits per channel for the panel. Frame blend is an average with the previous frame. While the menu is open, `hDrawOSD` is high and the OSD stored in PSRAM is composited on top. The transparent color matches the MCU LVGL chroma key `0xFF00FF`. The low-battery frame and the debug frame are sprite overlays inside the FPGA.

Backlight is `LCD_PWM`. Brightness is 0 to 15, default 3. The PWM period is 449 counts of `gClk`, and the duty is brightness times 16.

### Audio

The core’s left and right 16-bit samples pass a filter, then `aud_system_top_8_16` sends them to the TLV320 (I2C address `0x18`). `AUD_MCLK` is `gClk`. `AUD_BCLK`, `AUD_WCLK`, and `AUD_DIN` carry the data. The same samples also branch to USB audio. The volume wheel is codec page 0, register 117. Headphone detect is a GPIO register. Output is forced to zero on the menu SILENT setting, or when the volume register is above `0x76`.

`board.h` on the MCU lists I2S pins (GPIO 33/25/26/27). The MCU sources do not use them. On the FPGA, `I2S_BCLK` is just the menu-closed flag `menuDisabled`. It is not an audio bus to the MCU.

### Cartridge

`cartridge_interface` sequences cartridge power at about 16.8 MHz, independent of emulator reset. The states are OFF, POWER_UP (about 50 ms), SETTLE (about 10 ms), then RUNNING. `cartridge_ready` stays 0 until RUNNING, and the core waits on `POWER_GOOD`. On a newer board, data and control stay isolated until shutdown finishes, so nothing leaks onto the cartridge. An older board (`VERSION_DET = 1`) keeps the original output-enable behavior. A change on `CART_DET` asserts `memrst` and resets the core.

### Power and the LED

`POWER_ON_FPGA` is 1 when USB power is present and the power switch is OFF. In that state the USB core stays in reset, cartridge power is off, and the screen is off. `CHG_EN_FPGA` is tied to 1 in this RTL.

I2C first runs the TLV320 init sequence, then `polling_master_8_16` keeps cycling through:

- TLV320 `0x18` — volume, headphones, output path
- BQ24296 `0x6B` — watchdog off, charge current, system status REG08, fault REG09. Charging means `CHRG_STAT` in REG08 is precharge or fast charge
- TMP112 `0x48` — temperature, used to pick the charge current

Battery voltage is the FPGA’s built-in ADC. `ADC_SEL` switches between AA and LiPo. After boot it measures both for a while and picks whichever is higher. While the menu is open, the averaged ADC value is sent to the MCU. If the AA pack sags, the backlight goes to 0 until the voltage recovers, then the previous brightness returns. The LED is active low: white while charging, flashing red on low voltage.

### Infrared and the link

Infrared is the GBC RP register. Write bit 0 is `IR_LED`. `IR_RX` is what gets read back. The link cable is GB serial. When `sc_int_clock2` is 1 the FPGA drives the clock. The SD-link mentioned in comments is unused, and `LINK_SD_DIR_LV` is tied to 0.

## What the MCU owns

The entry point is `app_main` in `main/main.c`. It is FreeRTOS on ESP-IDF 5.3, and the UI library is LVGL. The draw size is the same 160×144 as the game.

There are five menu groups: status (brightness, silent), display (frame blend, USB stream color, screen transitions, low-battery icon), controls (reject diagonal D-pad input, hotkey help), palette or GBC color temperature, and system (player number, serial number). Settings stay in an NVS namespace and are sent to the FPGA again at every boot.

The MCU does not scan buttons itself. `Button_Update` takes the bitmap from the FPGA and uses it only while the OSD is visible. If the management UART is quiet for 100 ms, the MCU enters light sleep and wakes when the FPGA UART line goes low. Opening the menu makes the FPGA start streaming, which wakes the MCU.

The console REPL is GPIO 35 (RX) and GPIO 36 (TX). The prompt is `mcu>`. That UART is the MCU side of the USB CDC bridge described below.

## How they talk

There are three data paths. Game pixels and game audio do not use them.

| Path | Pins | Direction | Contents |
|---|---|---|---|
| Management UART | FPGA `ESP32_MCU_D11` to MCU GPIO 10. MCU GPIO 9 to FPGA `ESP32_MCU_D12`. | Both ways, 115200 8N1 | Settings, buttons, voltage, version, palettes. Protocol below. |
| OSD QSPI | MCU is master. CS = GPIO 5, CLK = GPIO 18, IO0–3 = GPIO 23/19/22/21. | MCU to FPGA | 40 MHz, 11-bit command, 32-bit address. One 160×144×16-bit frame is split into 45 transactions into PSRAM. Menu pixels turn on after `qAddress == 0` has been seen twice. |
| USB serial bridge | FPGA `ESP32_MCU_D4` is the MCU RX, `ESP32_MCU_D3` is the MCU TX. The firmware console is GPIO 36 / 35. | USB CDC to ESP32 UART | Flashing, logs, the `mcu>` shell. DTR and RTS drive ESP32 EN and IO0. |

Buttons are combined inside the FPGA. The debounced physical buttons are ORed with the 9-bit `MCU_buttons` from the MCU. While the menu is open they are not passed to the game (`MENU_CLOSED` is 0). Releasing the menu button toggles `menuDisabled`. With the menu closed, the FPGA also detects hotkeys: left and right change brightness, up and down change GBC color temperature or step the palette, and those events are reported to the MCU.

The player number arrives in `system_control[7:4]` and is also used in the USB product string “Chromatic - Player XX”.

### `system_control` bits

`fpga_tx.c` on the MCU sends 16 bits as command `0x04`. `system_monitor` on the FPGA keeps them.

| Bits | Meaning |
|---|---|
| 0 | Silent |
| 1 | Frame blend |
| 2 | LCD color correction |
| 3 | USB video color correction (menu name STREAMING) |
| 7:4 | Player number |
| 11 | Drop diagonal D-pad input |
| 12 | Screen-transition correction. The core port is named `paletteOff` |
| 14:13 | Low-battery display mode |

Bit 8, the timer display, is forced to 0 in `top.v`. Bits 9 and 10 (timer run and timer reset) are wired into the video path, but the MCU never sets them.

## USB port

D+ and D− on the connector are FPGA `usb_dxp_io` and `usb_dxn_io`. The PHY is Gowin’s USB 2.0 soft PHY, with an internal PLL from 24 MHz. The video stream runs only while `usb_highspeed` is set. At full speed there is no video. `VBUS_DET` and `USBC_FLIP` are commented out as unused.

The device is composite, with six interfaces. Descriptor IDs are vendor `0x0403`, product `0x6010`, manufacturer string ModRetro, product string “Chromatic - Player XX”. The definitions are in `usb_descriptor_video.v`.

| Function | Class | Contents |
|---|---|---|
| Screen capture | UVC 1.1 | Uncompressed YUY2. Default frame is 320×288 (the game picture doubled, an integer scale). The host can also pick 160×144. Target 60 fps. Isochronous IN is 1024 bytes. Color correction follows MCU setting bit 3. |
| Game audio | UAC 2.0 | Stereo 16-bit PCM, 44.1 kHz. The input terminal type is line in, not a microphone. The core’s left and right samples are placed on the stream as they are. |
| Serial | CDC-ACM | Bridged to the ESP32 UART. Accepted baud rates are 115200 and 921600. Any other SET_LINE_CODING runs as 115200. This is the port for logs and `idf.py flash`. On Linux it shows up as `/dev/ttyACM0`. |

After USB enumerates, `ESP32_EN` is the inverse of CDC RTS, and `ESP32_IO0` is 0 when both DTR and RTS are 0. Pulsing EN while IO0 is low puts the ESP32 into the download bootloader. Until USB has locked, EN and IO0 are both held at 1 so the ESP32 boots normally. Programming the FPGA itself uses the same USB socket, with the power switch ON, through Gowin Programmer or `openFPGALoader --cable gwu2x`, as the README describes.

While the switch is OFF and USB is attached, `ERST = usbrst | POWER_ON_FPGA` holds the USB device in reset. Charging is the FPGA’s job, over I2C and `CHG_EN_FPGA`.

## Wi-Fi and Bluetooth

The MCU is an ESP32, so the chip has 2.4 GHz Wi-Fi and Bluetooth (Classic and BLE). The published Chromatic MCU firmware starts neither of them.

- `sdkconfig.defaults` has neither `CONFIG_ESP_WIFI` nor `CONFIG_BT`
- The tree never calls `esp_wifi`, `esp_bt`, NimBLE, or Bluedroid
- The FPGA has no radio control pins and no packet path
- The menu has no network item. The player number is a USB string and a logical link id, not a radio address

Within these sources the Chromatic is neither a wireless console nor a wireless controller. Infrared and the link cable are how two units talk, and both are driven directly by the GB core on the FPGA.

## Boot sequence

Times below assume `gClk` is 8.388608 MHz and `hClk` is 16.777216 MHz. A measured PLL will be a little off.

1. The power switch turns ON and the FPGA configures. While `POWER_ON_FPGA` is 1 (switch OFF, USB power only) it stays in a charge-only state: USB, cartridge, and the screen are held off.
2. The LED stays off until the PLL locks. The LED is active low. System clocks start after lock.
3. After about one second of `gClk`, USB PHY reset `usbrst` is released. It is not released while the switch is OFF.
4. ESP32 EN waits until a 12-bit counter has wrapped 8 times. One wrap is about 0.49 ms, so if USB has not locked, EN rises after about 3.9 ms. IO0 stays 1, so this is a normal boot.
5. The cartridge power state machine samples `VERSION_DET`, applies power for about 50 ms, waits about 10 ms, then raises `cartridge_ready`. Core reset also waits for `CART_DET` to settle. `memrst` starts at 1.
6. I2C initializes the TLV320, then switches to polling and configures the charger and the temperature sensor. The ADC measures the battery about every 5 ms and decides AA versus LiPo over a few hundred samples.
7. ST7785 init finishes and raises `LCD_INIT_DONE`. `LCD_BACKLIGHT_INIT` goes to 1 on the first half-second pulse. The display enable waits for three vertical syncs after both of those are set. While the boot ROM runs, `LCD_INIT_DONE` into the system monitor is masked.
8. PSRAM BIST runs. The QSPI slave does not show menu pixels until address 0 has been written twice.
9. ESP32 `app_main` reads settings from NVS, opens UART1 at 115200, and a transmit task sends every setting (system control, brightness, palettes, color temperature, a version request, a button poke, and a palette readback request) six times, 10 ms apart.
10. The MCU initializes QSPI and LVGL and builds the OSD. The console REPL starts on the USB-bridge UART. Two seconds later the power-manager task starts, and if the management UART is quiet for 100 ms the MCU enters light sleep.
11. When the user releases the menu button, the FPGA clears `menuDisabled`. It then streams buttons, voltage, PMIC status, brightness, and the version over UART. The MCU wakes, writes the OSD over QSPI, and game input stays masked for that time.

If a USB host toggles RTS, EN falls and the ESP32 resets. If DTR and RTS are both 0, IO0 is 0 as well, and the next EN release enters download mode. FPGA CHANGELOG v18.8 notes that this EN/IO0 control sometimes failed to start the ESP32.

## Management UART packets

The current format is version 2. The FPGA receiver only looks for header `0x8F`. The MCU can also receive the old `0x8A` form (4 bytes, data in the low 7 bits).

Version 2 is `8F | address | length | payload | CRC-8`. The CRC is SAE J1850, polynomial `0x1D`, initial value `0xFF`. 16-bit values are big-endian, and the MCU transmitter byte-swaps them. The length limit is 10 bytes.

The FPGA sends to the MCU on a regular cadence only while the menu is open. Right after the menu opens, about 15 bytes are lost coming out of sleep, so the FPGA first emits 20 bytes of padding.

| Address | Direction | Contents |
|---|---|---|
| `0x00` | FPGA to MCU | AA-pack ADC. Board-revision bits in the top of the word. |
| `0x01` | FPGA to MCU | LiPo ADC. Same layout. |
| `0x02` | FPGA to MCU | Buttons. Bit 0 is START through bit 7 down, bit 8 is menu pressed, bit 9 is menu closed. |
| `0x03` | FPGA to MCU | Volume (7 bits), headphones, brightness. The MCU keeps only the brightness. |
| `0x04` | MCU to FPGA | `system_control`. See the bit table above. |
| `0x05` | MCU to FPGA | Backlight, 0–15. |
| `0x05` | FPGA to MCU | PMIC REG08. The MCU shows the charging icon only when `CHRG_STAT == 0b10`. |
| `0x06` | Both | The MCU requests it and the FPGA returns the version. In this tree that is major 18, minor 14. |
| `0x07` | FPGA to MCU | Reserved. The integer part of the temperature is sometimes here. The MCU discards it. |
| `0x08` | FPGA to MCU | Extended status: low-power, GBC mode, color temperature, palette hotkey (1 = next, 2 = previous). |
| `0x09` | MCU to FPGA | Button poke. ORed into the game inputs. |
| `0x09` | FPGA to MCU | Readback of 8 bytes of the game-side palette. |
| `0x0B` | MCU to FPGA | Background palette, 8 bytes. Bit 63 enables the custom palette. |
| `0x0C` | MCU to FPGA | Sprite palette. Bit 63 is 0 for OBJ0 and 1 for OBJ1. |
| `0x0D` | MCU to FPGA | Request a palette readback. |
| `0x0E` | MCU to FPGA | GBC color temperature, 0–5. |

The same address means different things in each direction because transmit and receive are separate decoders. The transmit command table is `fpga_tx.c`, the receive table is `fpga_rx.h`, and the FPGA branch is `system_monitor.sv`.

## Pins the RTL does not read

- `CART_AUDIN` — declared only. Cartridge audio is not mixed in.
- `VERSION_DET2`, `DISPLAY_ID` — declared only. Only `VERSION_DET` selects the board generation.
- `VBUS_DET`, `USBC_FLIP` — commented out.
- The MCU’s four I2S pins — defined only. Audio stays between the FPGA and the TLV320.

## Where to attach a sample

The real-time console lives under `top.v`. To replace the core for a small example, put your logic in place of `emu_system_top`. Use the RGB output of `vid_system_top` for the LCD, the debounced `BTN_*_filtered` signals for buttons, and `left` / `right` for audio. That leaves power, USB, and cartridge isolation alone. Menu and saved settings belong on the MCU. To reach the FPGA, use an existing management-UART command or add a free address. A Wi-Fi or Bluetooth sample has no base in this firmware: that is a separate ESP-IDF radio init. Extra USB gadgets belong in the FPGA’s `usbuvcuart_top`.

Sources for this note are the published trees. The main files are FPGA `esp32t/src/top.v`, `rtl/BSP/system_monitor.sv`, `rtl/EMU/cartridge_interface.v`, `rtl/EMU/emu_system_top.v`, `rtl/USB/USBUVCUART/`, and MCU `main/main.c`, `main/fpga_tx.c`, `main/fpga_rx.c`, `main/pwrmgr.c`.
