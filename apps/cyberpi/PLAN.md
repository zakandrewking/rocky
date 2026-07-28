# Rocky on CyberPi / mBot2

Rocky today is a macOS Electron app. This directory holds the work to give Rocky a body: a
Makeblock mBot2 (CyberPi controller, ESP32-based) that you can talk to out loud.

The plan has two stages. Stage 1 asked whether Makeblock's own operating system (CyberOS) can
carry a realtime voice conversation. It technically can — see the verdict below — but not to the
bar this project wants. **Stage 2 is now the active target.**

## Status: Stage 1 spiked and closed → building Stage 2

Hardware probing (`STEPS.md`) found that CyberOS exposes undocumented raw audio objects —
`cyberpi.mic_o.get_recording_data()` and `cyberpi.mp3_music_o.play_raw_data()` — that Makeblock's
published API says do not exist. Both work. The Stage-1 decision gate, read literally, says stop
there.

But the gate's original wording — "sufficiently low-level access for a **good realtime
conversation**" — undersold what "good" needs to mean. Measured against that bar, CyberOS's
high-level Python audio API has a hard ceiling:

- microphone capture is a **single 10-second preallocated buffer** with no read cursor — no way
  to stream a growing recording, so no way to react to speech before the speaker stops
- nothing confirms simultaneous record + playback, which barge-in requires
- the smallest unit of audio anyone has moved through the Python API is a probe-sized chunk, not
  the ~10 ms frames a duplex pipeline needs
- there is no interrupt path: nothing can cut off `play_raw_data()` mid-clip from a VAD trigger

The product bar for this project is **the full experience: ~10 ms audio buffering and barge-in**,
the same standard the desktop app already meets over WebRTC. CyberOS's Python API cannot get
there — it is a scripting layer over a black-box audio driver, not a real-time audio stack. Only
native firmware with direct I2S control can.

So: Stage 1 is kept as a working reference (the probe scripts, the measured audio format, the
device-api backend) and as proof the hardware itself is capable — the same ES8218E codec that
CyberOS drives will be driven directly in Stage 2, using the register map already found in
[`docs/upstream-sources.md`](docs/upstream-sources.md). None of the Stage-1 work is wasted; it
just isn't the destination.

## Stage 1 — Rocky as a CyberOS app *(spiked, not pursued to production)*

**Goal:** an audio-only Rocky running on CyberPi without replacing Makeblock firmware.

### Deliverable

A normal CyberPi program that:

- connects to Wi-Fi
- captures microphone audio
- sends/streams it to a Rocky/OpenAI backend
- receives spoken responses
- plays them through the built-in speaker
- shows simple animated states on the display: idle, listening, thinking, speaking, error

### Work

1. **Prove CyberOS audio access**
   - determine whether CyberOS exposes raw microphone samples or only higher-level recording APIs
   - determine whether arbitrary PCM/audio streaming can be played through the speaker
2. **Prove networking**
   - HTTPS from CyberOS
   - ideally WebSocket support
   - test sustained bidirectional traffic while audio is active
3. **Build a minimal Rocky device backend**
   - keep the real OpenAI API key off the robot
   - expose an authenticated endpoint that creates a device session / temporary credential
   - reuse Rocky's personality/system prompt where practical
4. **Implement the conversation loop**
   - listen → send audio → model → receive audio → speak
5. **Add the screen UI**
   - tiny Rocky face/avatar
   - state-driven animations
   - optionally animate the mouth from playback amplitude
6. **Package as a normal CyberPi program**
   - install into a program slot
   - exiting Rocky returns to ordinary CyberOS/mBot2 functionality

### Stage-1 success criterion

Turn on the mBot2, select Rocky, talk to it naturally, hear a low-latency spoken response, see
the screen react, and then exit back to the normal Makeblock environment.

### Decision gate — resolved

**Can CyberOS provide sufficiently low-level microphone, speaker, and network access for a good
realtime conversation?** Technically yes for audio I/O, but not for the specific bar this project
set — 10 ms buffering and barge-in. See the status section above for the measured constraints
that decided this. Proceeding to Stage 2.

## Stage 2 — Native Rocky firmware *(active)*

**Goal:** temporarily replace CyberOS with dedicated ESP32 firmware that gives Rocky full control
of the hardware, meeting the same realtime bar the desktop app already meets: **~10 ms audio
buffering and barge-in** (the ability to cut Rocky off mid-sentence by speaking over her, the way
a person would).

This is not destructive rooting — there is no vendor lock to work around. The CyberPi is a plain
ESP32, and Makeblock's own `CyberPi-Library-for-Arduino` (a standard PlatformIO/`esp32dev`
project, no custom bootloader or flash-encryption settings) is itself an invitation to flash
custom firmware. The ESP32's boot ROM can't be overwritten and always accepts a new flash over
USB, so recovery only depends on having a good backup — see
[`docs/recovery.md`](docs/recovery.md) for the actual mechanism.

### Framework — recommended, not yet confirmed

**ESP-IDF, not Arduino-ESP32.** The whole reason for Stage 2 is precise I2S DMA buffer control and
dual-core task scheduling, which is exactly the layer Arduino's abstraction (now itself built as
an ESP-IDF component) sits on top of. Cost: no ready-made peripheral code from Makeblock's Arduino
library, though the one piece that mattered most — the ES8218E register map — is already extracted
into `docs/upstream-sources.md`. Middle ground if peripheral bring-up (screen, buttons) drags:
PlatformIO supports Arduino-as-an-ESP-IDF-component, so Arduino-style libraries can still be used
for the non-audio-critical parts. Not yet acted on — the toolchain step below should confirm this
before committing project structure to it.

### Deliverable

A native C++/PlatformIO application:

```
CyberPi
 ├── audio capture/playback
 ├── realtime WebSocket client
 ├── Rocky display renderer
 ├── Wi-Fi/configuration
 └── mBot2 hardware controller
      ├── motors
      ├── ultrasonic sensor
      ├── line/color sensor
      ├── LEDs
      └── future accessories
```

### Work

1. **Establish native hardware support**
   - reference Makeblock's CyberPi Arduino library (`CyberPi-Library-for-Arduino`, GPL-3.0) for
     hardware facts — pin assignments, init sequences — regardless of which framework this ends
     up built on; read for facts and decide deliberately before shipping any code derived from it
     (see [`docs/upstream-sources.md`](docs/upstream-sources.md))
   - the audio codec is a known part: **Everest ES8218E on I2C `0x10`**, full register map already
     extracted from the GPL-3.0 library's `src/microphone/es8218e.h`
   - drive the codec directly over I2S — this is the whole reason to leave CyberOS: its Python API
     hands back one 10-second block with no cursor, and native I2S DMA gives frame-level control
   - verify screen, controls, mBot2 Shield, and sensors
2. **Bring up OTA updates — prioritized ASAP, right after the toolchain works at all.** Push a
   new `.bin` over Wi-Fi, board flashes itself and reboots. This needs nothing from the audio work
   (just Wi-Fi + a minimal update receiver), and it is the actual lever on iteration speed for
   everything after it — every later step (codec, pipeline, barge-in) gets tested far faster once
   a new build doesn't require physical USB access. It also removes the single biggest practical
   constraint on this project: development happening in a cloud session with no physical access to
   the board can push firmware once this exists, the same way it already pushes commits.
   Recovery (`cyberpi:restore`) stays the fallback for when OTA itself is broken or unreachable —
   USB access doesn't go away, it just stops being the only path.
3. **Implement the realtime audio pipeline, to a concrete spec**
   - **~10 ms frames** (160 samples at 16 kHz, or the equivalent at whatever rate the codec/Realtime
     API settles on) as the unit the whole pipeline moves — I2S DMA buffer size, network frame
     size, and jitter-buffer granularity all follow from this
   - 16 kHz (matching what CyberOS's driver already used) or 24 kHz mono PCM — pick based on what
     the Realtime API path wants and what the ES8218E supports cleanly
   - microphone ring buffer, sized in frames, continuously draining to the network — not a
     record-then-read block
   - speaker jitter buffer, small enough to keep total round-trip latency low, decoding frames as
     they arrive rather than waiting for a whole reply
   - WebSocket/TLS transport, one frame (or a small fixed number of frames) per message
   - **barge-in**: run VAD (or amplitude-threshold triggering, whatever proves reliable) on the mic
     input *while the speaker is active*, and on trigger, flush the speaker jitter buffer and
     cancel the in-flight response immediately — this is the feature CyberOS could not deliver,
     and it is the reason Stage 2 exists
4. **Create the embedded Rocky state machine**

   ```
   BOOTING
      ↓
   IDLE
      ↓
   LISTENING ↔ SPEAKING
      ↓
   THINKING
   ```

   Networking and audio run independently from rendering and motor control.
5. **Preserve Rocky's server-side intelligence.** Do not run the LLM or substantive agent logic
   on the ESP32. Personality, memory, conversation continuity, API credentials, and complicated
   tools stay on the Rocky backend. The robot remains a thin embodied client.
6. **Add robot tool calls.** Expose a deliberately small API to Rocky:

   ```
   drive_cm(distance)
   rotate_degrees(angle)
   stop()
   read_distance()
   read_line_sensors()
   set_lights()
   ```

   OpenAI Realtime tool calls then drive physical actions.
7. **Make recovery trivial** — done first, not last; see [`docs/recovery.md`](docs/recovery.md)
   - `pnpm cyberpi:backup` dumps the board's current flash before any custom firmware touches it
   - `pnpm cyberpi:restore` writes that dump back, with a typed confirmation
   - `pnpm cyberpi:flash-rocky` (once there is a Rocky firmware to flash)

## Repository shape

```
rocky/
├── apps/
│   ├── desktop/          # current Rocky
│   └── cyberpi/
│       ├── src/
│       │   ├── audio/
│       │   ├── realtime/
│       │   ├── display/
│       │   ├── robot/
│       │   └── main.cpp
│       └── platformio.ini
│
├── packages/
│   └── rocky-core/
│       ├── personality
│       ├── tool definitions
│       └── session config
│
└── services/
    └── device-api/
        ├── authentication
        ├── realtime sessions
        ├── memory
        └── continuity
```

Don't over-invest in shared code initially. Desktop Rocky is TypeScript and the embedded client
will likely be C++ (or MicroPython under CyberOS). Share protocols and behavior, not necessarily
implementation.

## Sequence to actually execute

Stage 1 was run as a **feasibility spike first**, exactly as planned, and it did its job: it
proved the hardware itself (mic, speaker, ES8218E codec) is capable, without touching firmware.
That capability carries forward into Stage 2 unchanged.

Stage 2 gets the same discipline — small, verifiable steps before a large implementation,
particularly because this stage touches firmware on a real device:

1. **Recovery first, before anything else is flashed — done.** `pnpm cyberpi:backup` dumped the
   board's current flash (ESP32-D0WD, 8MB, port `/dev/cu.usbserial-210`); `pnpm cyberpi:restore`
   wrote it back, with esptool's own post-write hash verification passing, and the board
   power-cycled straight back into normal CyberOS — home screen and LEDs working. The round trip is
   confirmed on this specific board. One fix was needed to get there: esptool 5.3.1 renamed
   `flash_id`/`read_flash`/`write_flash` to the hyphenated `flash-id`/`read-flash`/`write-flash`;
   the scripts (`apps/cyberpi/scripts/`) now use the current names. Safe to move on to step 2.
2. **Bring up the toolchain and confirm the framework choice — done.** PlatformIO + ESP-IDF
   confirmed (`apps/cyberpi/platformio.ini`, `board = esp32dev` matching the real ESP32-D0WD chip).
   Checked Makeblock's own Arduino library first and found the board has no raw-GPIO LED - front
   lights and buttons are behind I2C (an AW9523B expander, a separate LED driver at `0x5B`) - so
   the trivial program prints over serial instead of blinking. `pnpm cyberpi:flash-rocky` built and
   flashed clean on the real board; serial output confirmed a steady tick counter with no resets.
   Custom firmware is now running on the board - by explicit choice, it was not restored back to
   stock CyberOS afterward, so Stage 2 continues directly from here rather than round-tripping back
   through step 1's restore each time.
3. **Bring up OTA — done.** The board joins Wi-Fi (credentials read from the repo root `.env` into
   a gitignored generated header, never committed) and runs a minimal HTTP `POST /ota` receiver
   that writes the request body to the inactive `ota_0`/`ota_1` partition via `esp_ota_ops` and
   reboots into it. Needed a real partition-table change first — the default single-app layout has
   no room for a second image — sized for the actual 8MB flash. Verified for real: flashed once
   over USB, confirmed the printed IP over serial, then pushed a second build with `pnpm
   cyberpi:ota` and confirmed over serial that the board rebooted into it. No physical access is
   needed for firmware pushes from here on; `cyberpi:restore` over USB remains the fallback if OTA
   itself ever breaks. The receiver has no auth — fine for this LAN-only bring-up tool, not
   acceptable if this ever ships, see TODOS.md.
   Prioritized ASAP per the framework discussion — it's the actual lever on
   iteration speed for every step after this one, and it's what lets a session with no physical
   access to the board (like this one) push firmware the same way it already pushes commits. Needs
   only Wi-Fi and a minimal update receiver; doesn't depend on the codec or audio pipeline at all,
   which is why it comes before them here even though the plan's Work list keeps audio as the
   architecturally central item.
4. **Bring up the codec.** Drive the ES8218E over I2S using the register map already in hand;
   confirm raw capture and playback at the target frame size (~10 ms) before building anything on
   top. OTA should already be usable by this point, so this is the first step that gets to benefit
   from it.
5. **One-directional streaming milestone**, mirroring Stage 1's own first milestone but at the
   native layer: `mic → 10ms frames → network → server`, and separately `server → network → 10ms
   frames → speaker`. No personality, no barge-in logic yet — just prove frames move continuously
   in each direction without gaps or growing latency.
6. **Full duplex + barge-in.** Both directions active at once, VAD on the live mic during
   playback, interrupt-and-flush on trigger. This is the milestone that actually delivers on "the
   full experience."
7. Then personality, the state machine, the screen UI, robot tool calls, and packaging — the rest
   of Stage 2's work list above.
