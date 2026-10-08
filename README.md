# ModRetro Chromatic FPGA examples

Example projects for using a [ModRetro Chromatic](https://modretro.com/) as an FPGA development board. Each directory is a Gowin project that drives the console’s own LCD, buttons, and audio codec. They are not Game Boy games.

The FPGA is a Gowin GW5A-25 (`GW5A-EV25UG256`). The stock console firmware stays on the ESP32 and still draws the settings menu over the FPGA picture.

These projects are unofficial. They are not from ModRetro.

## Projects

The three projects share the same board files and the same LCD, audio, USB, and menu logic. The picture and sound you see come from [`emu_system_top.v`](01-lcd/src/rtl/EMU/emu_system_top.v) in each directory.

| Project | What it does | Where to edit |
|---|---|---|
| [`01-lcd`](01-lcd/) | Eight vertical color bars on the 160×144 LCD. Buttons do nothing. | [`emu_system_top.v`](01-lcd/src/rtl/EMU/emu_system_top.v) |
| [`02-button`](02-button/) | A 16×16 square. The D-pad moves it one pixel per frame. A is red, B is blue, and A+B is magenta. | [`emu_system_top.v`](02-button/src/rtl/EMU/emu_system_top.v) |
| [`03-sound`](03-sound/) | Held keys play one sine tone: Left C4, Down D4, Up E4, Right F4, Select G4, Start A4, B B4, A C5. The LCD draws that wave. Silence is a flat line through the middle. | [`emu_system_top.v`](03-sound/src/rtl/EMU/emu_system_top.v) and [`sine_key_synth.v`](03-sound/src/rtl/EMU/sine_key_synth.v) |

`sine_key_synth.v` is generated. Change [`03-sound/scripts/gen_sine_key_synth.py`](03-sound/scripts/gen_sine_key_synth.py) and run it, rather than editing the Verilog by hand:

```sh
python3 03-sound/scripts/gen_sine_key_synth.py
```

## Where the code comes from

Almost every file outside `emu_system_top.v` is copied from the official Chromatic FPGA design:

https://github.com/ModRetro/oss-chromatic-console-fpga

That includes the LCD panel driver, the audio codec, USB, constraints, and the Gowin project. `03-sound` also adds the sine generator and its script. The copied design is GPL-3.0. Each project directory contains the license text.

## Tools

You need [GOWIN EDA](https://www.gowinsemi.com/en/) (Gowin FPGA Designer), about **1.9.12**. The upstream Chromatic tree was built with 1.9.12.03. Other versions are untested.

The standard IDE does not run until you install a license. Gowin gives that license away for non-commercial use. Apply here:

https://www.gowinsemi.com/en/support/license

It is tied to your computer and expires after one year. Apply again when it expires. The IDE asks for the `.lic` file on startup.

There is also a license-free **Education** edition. Its published device list covers some GW5A-25 packages, not the Chromatic’s `GW5A-EV25UG256`. Use the standard IDE and the free license unless a newer Education release explicitly lists that part.

To load a bitstream you can use Gowin Programmer, which needs the GWU2X cable driver, or [`openFPGALoader`](https://github.com/trabucayre/openFPGALoader) built with GWU2X support.

## Build

Open `evt1_x2.gprj` in the IDE and run synthesis and place-and-route. The bitstream is `impl/pnr/evt1_x2.fs`.

From a shell, with `gw_sh` on `PATH` or `GOWIN_SH` pointing at it:

```sh
cd 01-lcd
./build_evt1_x2.sh
```

That runs `build.tcl` and copies `evt1_x2.fs` and `evt1_x2.bin` into `build/`.

## Run it

Turn the power switch **ON**. The programmer cannot see the FPGA while the console is off.

**SRAM load.** This is the one to use while experimenting. It configures the FPGA only. Power off, and the bitstream is gone. The next power-on boots whatever is still in flash, which is the official design if you have not written flash.

```sh
openFPGALoader --cable gwu2x 01-lcd/impl/pnr/evt1_x2.fs
```

In Gowin Programmer, choose the SRAM operation, not external flash.

**Flash.** This replaces the bitstream stored in the console. It stays after power off.

```sh
openFPGALoader --write-flash --cable gwu2x --reset 01-lcd/impl/pnr/evt1_x2.fs
```

To put the official FPGA design back, use the [ModRetro Update Tool](https://modretro.com/pages/downloads).

A cartridge is not required. The picture stays dark until LCD init and the cartridge-power wait finish, which takes a fraction of a second after power-on.

## Disclaimer

These examples can leave the console unable to boot a game until you restore the official bitstream. Writing the wrong file to flash, or a design that drives the cartridge, audio, or power pins badly, can damage the hardware.

You use this repository at your own risk. The author is not responsible for a broken Chromatic, lost data, or anything that follows from building or loading these projects.
