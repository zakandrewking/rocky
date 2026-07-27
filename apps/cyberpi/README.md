# Rocky on CyberPi

Giving Rocky a body: a Makeblock mBot2 you can talk to out loud.

- [`PLAN.md`](PLAN.md) — the two-stage plan. Stage 1 is Rocky as a normal CyberOS program;
  Stage 2 is native ESP32 firmware if CyberOS cannot carry realtime audio.
- [`STEPS.md`](STEPS.md) — the Stage-1 checklist. **Start here.**
- [`docs/first-upload.md`](docs/first-upload.md) — mBlock setup for the first hardware run.
- [`docs/cyberos-api-surface.md`](docs/cyberos-api-surface.md) — what CyberOS documents it can do.
- [`steps/`](steps) — twelve small programs, run one at a time on hardware.

## Where this stands

Stage 1 is a feasibility spike, not an implementation. The whole thing turns on one question:

> Can CyberOS provide sufficiently low-level microphone, speaker, and network access for a good
> realtime conversation?

Desk research said probably not: Makeblock's published API has no raw sample input and no
arbitrary sample output. **Hardware says otherwise, on both counts.**

```python
# hear
cyberpi.mic_o.get_recording_data(0)      # -> [48-byte header, PCM]
                                         #    16 kHz, 8-bit, mono, 10 s max

# speak
cyberpi.mp3_music_o.play_raw_data(pcm, 16000)   # audible. arbitrary bytes.
```

Neither object appears in Makeblock's published API package, which turns out to be a *subset* of
the firmware rather than a description of it. Both were found by dumping `dir(cyberpi)` on a real
board and noticing undocumented names.

**So the decision gate is answered: CyberOS can carry the conversation, and Stage 2 — native ESP32
firmware — is unnecessary.** No reflashing, no recovery scripts, no risk to the robot. Rocky
becomes a program in a CyberPi slot.

What remains open is how *good* it can be: latency, whether audio can stream rather than move in
whole turns, and networking under load. See `STEPS.md`.

## Getting started

```bash
pnpm device-api      # needed from step 8 onward
```

Then open `STEPS.md` and work down the list. Steps 1–7 need only the CyberPi and a USB cable.

## What is deliberately not here — yet

No conversation loop, no personality on the robot, no animated face, no motor control. Those were
gated on the audio answer, which has now come back yes, so they are next rather than speculative.

The backend already exists in [`services/device-api`](../../services/device-api): it keeps the
OpenAI key off the robot, hands out short-lived credentials, and decodes the CyberPi's audio format
into playable WAVs.
