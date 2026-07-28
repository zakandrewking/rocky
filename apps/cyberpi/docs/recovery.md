# Recovering the CyberPi

Stage 2 replaces CyberOS with custom firmware. This is how the board gets back to normal, and it
is deliberately the first thing built — before a single line of custom firmware is written —
because it is the one step in this whole project where getting the order wrong has real cost to a
device the family uses.

## Strategy: back up first, don't hunt for an official image

Makeblock does not appear to publish CyberOS as a standalone downloadable firmware file — updates
happen through mBlock's own GUI flow (Settings → Firmware Update), not a file you fetch yourself.
See [`upstream-sources.md`](upstream-sources.md) for what was and wasn't found there.

So instead of depending on that flow being available, or on Makeblock's servers being reachable
whenever a restore is needed: **dump the board's entire flash before anything else ever touches
it.** That dump is guaranteed byte-identical to what shipped, needs nothing from Makeblock at
restore time, and is the standard, well-established way to make ESP32 work reversible.

```
cyberpi-backup.sh   reads the whole flash -> apps/cyberpi/firmware/backups/cyberpi-stock-*.bin
cyberpi-restore.sh  writes a backup back, with a typed confirmation before it overwrites anything
```

Both live in [`../scripts/`](../scripts) and are wired up as `pnpm cyberpi:backup` /
`pnpm cyberpi:restore`.

## Status: verified against real hardware

`pnpm cyberpi:backup` and `pnpm cyberpi:restore` have both run for real against this board (an
ESP32-D0WD, 8MB flash, port `/dev/cu.usbserial-210` — not the `wchusbserial*` name originally
guessed from Makeblock's `platformio.ini`; `lib.sh`'s port-detection glob already covered
`usbserial-*` too, so no change was needed there). The backup read all 8MB, the restore wrote it
back with esptool's own post-write hash verification passing, and the board power-cycled back into
normal CyberOS — home screen and LEDs working. The one real fix needed: esptool 5.3.1 renamed
`flash_id`/`read_flash`/`write_flash` to `flash-id`/`read-flash`/`write-flash` (the old names still
work today but only via a deprecated alias esptool says it will remove) — the scripts now use the
current names directly.

## What to do, in order

1. **Install esptool** if it isn't already: `uv tool install esptool`
2. **Connect the CyberPi** over USB and power it on.
3. **Run the backup:**
   ```bash
   pnpm cyberpi:backup
   ```
   If port auto-detection fails or picks the wrong thing, override it:
   ```bash
   CYBERPI_PORT=/dev/cu.wchusbserial14120 pnpm cyberpi:backup
   ```
   (`ls /dev/cu.*` with the board plugged in vs. unplugged shows which entry is it.)
4. **Read the output carefully.** The script is written defensively — it fails loudly rather than
   silently producing a bad backup — but this is its first real run, so treat any surprise as a
   bug in the script to fix, not something to work around by hand.
5. **Verify the round trip before doing anything else:** run `pnpm cyberpi:restore`, power-cycle
   the board, and confirm it boots into normal CyberOS — home screen, LEDs, mBlock can reconnect.
   Only once that works is it safe to move on to flashing anything custom.
6. Keep the resulting `.bin` file. It is gitignored on purpose (multi-megabyte binary, and
   arguably sensitive if any saved Wi-Fi credentials are baked into flash) but it should never be
   deleted — it's the only way back to stock CyberOS this project has.

## If something goes wrong here

- **`flash_id` fails / board not found:** wrong port (set `CYBERPI_PORT`), or the board needs a
  manual bootloader-entry button combo instead of the automatic DTR/RTS reset most ESP32 boards
  use. Try holding whatever button maps to `BOOT`/`GPIO0` while the script connects, if simply
  running it doesn't work.
- **Restore doesn't boot cleanly:** don't guess further — this is exactly the scenario `esptool`'s
  own recovery tools exist for (`esptool --port <PORT> chip-id` to confirm the chip is still
  reachable at all; if it is, the flash contents can always be rewritten again, including a fresh
  backup attempt if the board somehow still has something bootable on it).
- **Genuinely bricked feeling:** the ESP32's boot ROM is separate silicon, not part of what gets
  overwritten, and it always listens for a new flash over USB. There is essentially no state a
  bad flash puts the chip into that a correct `esptool write_flash` can't recover from.
