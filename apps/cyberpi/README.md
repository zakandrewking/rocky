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
arbitrary sample output. **Hardware says otherwise.** The firmware exposes its raw I2S microphone
driver directly in Python —

```
cyberpi.mic_o  (type i2s_mic)
    init / deinit
    record_start / record_stop / record_with_time
    record_get_status / record_set_status
    get_recording_data          <-- raw samples
    play_recording
```

— none of which appears in the published package, which turns out to be a *subset* of the
firmware rather than a description of it. Free heap is 1.27 MB, about 26 seconds of 24 kHz PCM,
so buffering was never the constraint either.

Capture now looks likely to work on unmodified CyberOS. Playback is the open question and the
binding constraint. Steps 1–4 and 5c have run on hardware; see `STEPS.md` for what each one found.

## Getting started

```bash
pnpm device-api      # needed from step 8 onward
```

Then open `STEPS.md` and work down the list. Steps 1–7 need only the CyberPi and a USB cable.

## What is deliberately not here

No conversation loop, no personality on the robot, no animated face, no motor control. Those are
the plan's later Stage-1 items and they are all gated on the audio answer. Building a screen UI for
a robot that turns out to be unable to speak would be wasted work.

The backend is the exception, and it is in [`services/device-api`](../../services/device-api). It
is the same service either way — Stage 2 needs it too — so it is worth having early. It keeps the
OpenAI key off the robot and hands out short-lived credentials instead.
