# Changelog

## 2026-11-04 (`releases/Apple-IIgs_20261104.rbf`)

### Memory (MMU)
- The MMU now matches captures from physical ROM 01 and ROM 03 machines. The MMUPROBE results agree in all 45,824 cases on each ROM; before, 2,128 differed.
  - Shadowing follows the physical bank. Odd banks use the aux rules.
  - Even high banks under CYAREG[4] honour RAMRD and RAMWRT at `$2000-$3FFF`.
  - Language card bank 2 sits at physical `$Cxxx` and bank 1 at `$Dxxx`.
  - Writes to slot space (`$C100-$CFFF`) never reach RAM.
- The core models the `$C800-$CFFF` ownership latch (INTC8ROM).
  - A `$C3xx` access with SLOTC3ROM=0 claims the internal ROM.
  - Any `$CFFF` access releases it.
  - Reads of the space while nothing owns it return the floating-bus byte.

### WOZ floppy (3.5" and 5.25")
- 5.25" reads follow the Disk II sequencer: a completed nibble stays latched until the next pulse, instead of being cleared when read. First Math Adventures now boots.
- An access to `$C08D` (Q6H) resets the read shift register. Wings of Fury and Commando rely on this.
- SmartPort mode bits no longer block 5.25" flux during early boot.
- The CPU stays at 1 MHz through the IWM's one-second 5.25" motor-off holdover. Bouncing Kamungas now boots.
- 5.25" bit cells follow the WOZ INFO optimal bit timing.
- Weak bits now repeat for the same head position, as on real media. Unmapped tracks are no longer marked as changed.
- Each 3.5" track side is loaded in multi-block SD requests (up to 16 KB) instead of one block per request. This removes a timeout on slow HPS responses that broke Alien Mind after a track change.
  - Fix, rebuilt into the same file: the first 20261104 build broke every zipped image and every `.po`, `.2mg`, `.dsk`, `.do`, `.nib` or DiskCopy floppy ("Check startup device!"). Main's IIgs disk layer answers those reads one block at a time; the core now advances by the blocks it actually receives.

### Serial (SCC)
- Fixed a Z8530 WR0 register-pointer bug that hung GS/OS printing in the ROM interrupt handler.
- New OSD "Serial Port" option: route either the modem port (the default) or the printer port to the MiSTer UART, with RTS/CTS on both channels.

### Testing
- vsim's `regression.sh` passes 10/10. The WOZ test suite passes 43 of 45 (both Stargate failures already existed).
- Hardware (DE10-Nano):
  - MMUPROBE matches on ROM 01 and ROM 03, and mmu_test passes 26/26.
  - These boot: Alien Mind, Tomahawk, Qix (woz-a-day image), Arkanoid, Karateka, and A Mind Forever Voyaging.
  - GS/OS prints to the MiSTer printer daemon.

### Notes
- The ROM checks each boot slot once at power-on. A disk mounted after that check (for example by an `.mgl` with a non-zero `delay`) shows "Check startup device!" until you reset, the same as a real IIgs. Use `delay="0"` in `.mgl` files.
- Copy-protected images must stay write-protected. Qix, for example, rejects its disk once its own startup has written to it.

## 2026-07-12 (`releases/Apple-IIgs_20260712.rbf`)
- Initial public release.
