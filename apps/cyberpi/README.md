# Rocky on CyberPi

Giving Rocky a body: a Makeblock mBot2 you can talk to out loud.

- [`PLAN.md`](PLAN.md) — the plan. Stage 1 (CyberOS) was spiked and closed; **Stage 2 (native
  ESP32 firmware) is the active target.** Start here.
- [`STEPS.md`](STEPS.md) — the Stage-1 hardware log and verdict.
- [`docs/first-upload.md`](docs/first-upload.md) — mBlock setup, for anyone re-running a Stage-1
  probe.
- [`docs/cyberos-api-surface.md`](docs/cyberos-api-surface.md) — what CyberOS documents it can do
  (and doesn't).
- [`docs/upstream-sources.md`](docs/upstream-sources.md) — the ES8218E codec and its register map,
  found in Makeblock's GPL-3.0 Arduino library. **This is what Stage 2 builds on.**
- [`docs/recovery.md`](docs/recovery.md) — the flash backup/restore strategy. Verified against real
  hardware: `pnpm cyberpi:backup` / `pnpm cyberpi:restore` round-trip and boot back into stock
  CyberOS.
- [`platformio.ini`](platformio.ini) / [`src/main.c`](src/main.c) — the native ESP-IDF firmware.
  Verified against real hardware: joins Wi-Fi and serves OTA updates over `pnpm cyberpi:ota`, no
  USB required after the first `pnpm cyberpi:flash-rocky`.
- [`steps/`](steps) — the Stage-1 probe programs, kept as a working reference.

## Where this stands

Stage 1 asked whether CyberOS itself — no firmware changes — could carry a realtime
conversation. It found something the published API says is impossible:

```python
# hear
cyberpi.mic_o.get_recording_data(0)             # -> [48-byte header, PCM]
                                                 #    16 kHz, 8-bit, mono, 10 s max, no cursor

# speak
cyberpi.mp3_music_o.play_raw_data(pcm, 16000)   # audible. arbitrary bytes.
```

Both objects were found by dumping `dir(cyberpi)` on a real board and noticing undocumented
names; neither appears in Makeblock's published package, which turned out to be a *subset* of the
firmware rather than a description of it.

**Read narrowly, that answers the Stage-1 gate: audio I/O works on stock firmware.** But the
actual bar for this project is **the full experience — ~10 ms audio buffering and barge-in** —
the same standard the desktop app meets over WebRTC. CyberOS's Python API cannot get there: the
microphone is one 10-second block with no read cursor, nothing confirms simultaneous
record+playback, and nothing offers frame-level control. It's a scripting layer over an opaque
driver, not a real-time audio stack.

So Stage 1 is closed as a spike, not carried into production, and **Stage 2 — native firmware
driving the ES8218E codec directly over I2S — is where this project is going.** See `PLAN.md` for
the spec and sequence. Nothing from Stage 1 is wasted: the hardware is proven capable, the codec
is identified, its registers are known, and `services/device-api` is the same backend either way.

## Getting started

Stage 1's probe programs (`steps/`) still work and are worth keeping around as a reference for the
measured audio format and for any future MicroPython-level debugging. They are not the path
forward.

Stage 2's first three steps are done and verified on real hardware: recovery
(`pnpm cyberpi:backup` / `cyberpi:restore`), the PlatformIO/ESP-IDF toolchain
(`pnpm cyberpi:flash-rocky`), and OTA (`pnpm cyberpi:ota`, once the board has joined Wi-Fi from a
first USB flash). See `PLAN.md`'s sequence for what's next: the ES8218E codec, then the streaming
milestones.

## What is deliberately not here yet

No C++ audio pipeline, no barge-in implementation, no display or robot-control code. Those are
Stage 2's actual work, tracked in `TODOS.md`.

The backend already exists in [`services/device-api`](../../services/device-api): it keeps the
OpenAI key off the robot, hands out short-lived credentials, and decodes the CyberPi's audio
format into playable WAVs. It carries forward unchanged into Stage 2 — the robot's transport
target, not its audio source, is what's changing.
