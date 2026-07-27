# Rocky on CyberPi / mBot2

Rocky today is a macOS Electron app. This directory holds the work to give Rocky a body: a
Makeblock mBot2 (CyberPi controller, ESP32-based) that you can talk to out loud.

The plan has two stages. Stage 1 asks whether Makeblock's own operating system (CyberOS) can
carry a realtime voice conversation. Stage 2 is what we do if it cannot.

## Stage 1 — Rocky as a CyberOS app

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

### Decision gate

The important question: **can CyberOS provide sufficiently low-level microphone, speaker, and
network access for a good realtime conversation?**

- If yes, stop here architecturally. CyberOS is the better solution.
- If no, Stage 2 solves the limitations.

## Stage 2 — Native Rocky firmware

**Goal:** temporarily replace CyberOS with dedicated ESP32 firmware that gives Rocky full control
of the hardware.

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
   - build against Makeblock's CyberPi Arduino library
   - identify microphone/speaker hardware and pins
   - access audio directly through I2S/codec APIs if necessary
   - verify screen, controls, mBot2 Shield, and sensors
2. **Implement the realtime audio pipeline**
   - ~24 kHz mono PCM, or whatever format the Realtime API/device path settles on
   - microphone ring buffer
   - speaker jitter buffer
   - WebSocket/TLS transport
   - interruption/barge-in handling
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

Stage 1 is a **feasibility spike first**, not a large implementation. The first milestone is only:

```
CyberOS mic → network → server → generated audio → CyberPi speaker
```

No personality, animations, memory, or robot motion yet.

That experiment tells us quickly which branch the project takes:

- CyberOS works → Rocky becomes a nicely installable mBot2 app.
- CyberOS hits an audio/network wall → move directly to native firmware, with essentially no
  wasted architectural work.
