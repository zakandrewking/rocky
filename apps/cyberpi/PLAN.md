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

This is not destructive rooting. The Makeblock firmware stays recoverable and reinstallable.

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
   - build against Makeblock's CyberPi Arduino library (`CyberPi-Library-for-Arduino`, GPL-3.0 —
     read for hardware facts, decide deliberately before shipping any code derived from it; see
     [`docs/upstream-sources.md`](docs/upstream-sources.md))
   - the audio codec is a known part: **Everest ES8218E on I2C `0x10`**, full register map already
     extracted from the GPL-3.0 library's `src/microphone/es8218e.h`
   - drive the codec directly over I2S — this is the whole reason to leave CyberOS: its Python API
     hands back one 10-second block with no cursor, and native I2S DMA gives frame-level control
   - verify screen, controls, mBot2 Shield, and sensors
2. **Implement the realtime audio pipeline, to a concrete spec**
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
3. **Create the embedded Rocky state machine**

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
4. **Preserve Rocky's server-side intelligence.** Do not run the LLM or substantive agent logic
   on the ESP32. Personality, memory, conversation continuity, API credentials, and complicated
   tools stay on the Rocky backend. The robot remains a thin embodied client.
5. **Add robot tool calls.** Expose a deliberately small API to Rocky:

   ```
   drive_cm(distance)
   rotate_degrees(angle)
   stop()
   read_distance()
   read_line_sensors()
   set_lights()
   ```

   OpenAI Realtime tool calls then drive physical actions.
6. **Make recovery trivial**
   - document how to reflash official CyberPi firmware
   - ideally two one-command scripts: `pnpm cyberpi:flash-rocky` and `pnpm cyberpi:restore`

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

1. **Recovery first, before anything else is flashed.** Document and script reflashing official
   CyberPi firmware (`pnpm cyberpi:restore`) and confirm it actually works on this specific board,
   before any custom build goes anywhere near it. This is the one step in Stage 2 where getting
   the order wrong has real cost.
2. **Bring up the toolchain.** PlatformIO project, build against `CyberPi-Library-for-Arduino`,
   flash a trivial program (blink an LED, print over serial), confirm `pnpm cyberpi:flash-rocky`
   round-trips with step 1's restore.
3. **Bring up the codec.** Drive the ES8218E over I2S using the register map already in hand;
   confirm raw capture and playback at the target frame size (~10 ms) before building anything on
   top.
4. **One-directional streaming milestone**, mirroring Stage 1's own first milestone but at the
   native layer: `mic → 10ms frames → network → server`, and separately `server → network → 10ms
   frames → speaker`. No personality, no barge-in logic yet — just prove frames move continuously
   in each direction without gaps or growing latency.
5. **Full duplex + barge-in.** Both directions active at once, VAD on the live mic during
   playback, interrupt-and-flush on trigger. This is the milestone that actually delivers on "the
   full experience."
6. Then personality, the state machine, the screen UI, robot tool calls, and packaging — the rest
   of Stage 2's work list above.
