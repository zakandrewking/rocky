# Stage-1 steps

Small programs, run one at a time on real hardware, each proving one thing. Run them in order —
a later step is meaningless if an earlier one failed.

Every step is standalone. mBlock uploads a single program, so each file pastes in whole with no
imports from its siblings.

Fill in the Result column as you go. Steps 8–12 need `services/device-api` running; the rest need
only the board.

| # | File | Proves | Result |
| --- | --- | --- | --- |
| 1 | `steps/step01_hello.py` | upload works, screen draws, console readable | **PASS** — uploaded to Program 1 |
| 2 | `steps/step02_speaker.py` | speaker plays tones and presets, volume settable | **PASS** |
| 3 | `steps/step03_record.py` | mic records and plays back; slot is single-buffered | **PASS** — ran; single-buffer behaviour still to be confirmed |
| 4 | `steps/step04_loudness.py` | envelope polling rate — is VAD viable? | **PASS** — ran; Hz figures still to be recorded |
| 5 | `steps/step05_introspect.py` | **gate:** is there any raw capture path? | **Found undocumented `cyberpi.mic`, `cyberpi.microphone`, `mic_o…`, `audio.file_handle`.** `record()` takes no path. `play(path)` failed on an internal firmware bug, not a clean rejection. Board crashed before the filesystem listing |
| 5c | `steps/step05c_mic_object.py` | **follow-up:** what are those mic objects? Calls nothing — read-only | **`cyberpi.mic_o` is an `i2s_mic`** with `init`/`deinit`, `record_start`/`record_stop`/`record_with_time`, `record_get/set_status`, `play_recording`, and **`get_recording_data`**. Free heap 1,273,632 B = 26.5 s of 24 kHz PCM. `audio.file_handle` is `None` — dead end |
| 5d | `steps/step05d_raw_capture.py` | **gate:** does `get_recording_data()` return real audio, and can it be read mid-recording? | |
| 6 | `steps/step06_modules.py` | **gate:** sockets, and `machine.I2S` for raw output | |
| 5b | `steps/step05b_gate_screen.py` | **replaces 5 and 6** when the serial console is unreadable — same findings, rendered on the CyberPi screen | |
| 7 | `steps/step07_wifi.py` | Wi-Fi connects | |
| 8 | `steps/step08_http_get.py` | robot reaches device-api; latency floor | |
| 9 | `steps/step09_upload.py` | uplink throughput vs the 384 kbps PCM needs | |
| 10 | `steps/step10_play_download.py` | **gate:** can server-generated audio reach the speaker? | |
| 11 | `steps/step11_concurrency.py` | does networking survive while audio is active? | |
| 12 | `steps/step12_websocket.py` | is a streaming transport possible? | |

## Running a step

**First time?** Read [`docs/first-upload.md`](docs/first-upload.md) — it covers the mBlock setup,
Live vs Upload mode, program slots, and how to get the board back to normal afterwards.

1. Connect the CyberPi over USB, open mBlock 5.
2. Python editor, mode toggle set to **Upload** (not Live — Live runs the code on your computer
   and would measure your Mac's audio and network stack instead of the robot's).
3. Paste the file, pick a program slot, click Upload.
4. Read the screen and the terminal panel. Record the outcome above.

None of these steps modify firmware or persist anything. Power-cycling the board returns it to
normal CyberOS.

### Extra setup for steps 7–12

Every network step has a small config block at the top. Fill it in before uploading:

```python
WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"   # your computer's LAN IP, never "localhost"
API_PORT = 8787
```

CyberPi is 2.4 GHz only, and hidden SSIDs and captive portals do not work.

Steps 8–12 also need the backend running on your computer:

```bash
pnpm device-api
```

Those steps POST their own numbers to it, so results land in `local-data/cyberpi/` as JSON and
get summarized in the service's terminal — no transcribing from a serial console. Set
`POST_RESULTS = False` in a step to turn that off.

## The three checks that decide the gate

Everything else is supporting evidence. Stage 1 lives or dies on:

- **Raw capture — step 5d.** Can we get microphone audio out of CyberOS as bytes? Makeblock's
  published API says no, but the firmware exposes its raw I2S microphone driver as
  `cyberpi.mic_o`, including `get_recording_data()`. Step 5d finds out whether that returns real
  samples. **This looks likely to pass**, which was not the expectation going in.
- **Step 10 — raw playback.** Can bytes we generate reach the speaker? Still open, and now the
  binding constraint. Worth checking whether an `i2s`-flavoured *output* object exists too, by the
  same trick that found `mic_o`.
- **Step 6 — sockets.** Without `socket`/`ssl`, the robot cannot talk to Rocky's backend at all,
  and the only remaining path is Makeblock's cloud redirects.

If capture and playback both fail, CyberOS cannot carry a realtime conversation, and the answer
to the decision gate is **no** → Stage 2.

### The lesson from steps 5 and 5c

The published API package is a **subset** of the firmware, not a description of it: 33 audio
members on the board versus about 20 in the package, plus an entire undocumented I2S driver. Every
"CyberOS cannot do X" claim derived from that package is unproven until a `dir()` on real hardware
says so. That is what these steps are for.

## Verdict

Fill this in once steps 1–12 have run.

- Raw microphone capture: _pending_
- Raw speaker playback: _pending_
- Sockets / HTTPS: _pending_
- Sustained traffic during audio: _pending_
- **Decision gate:** _pending_

### If the answer is no

Two options, and they are not equally good:

1. **Stage 2, native firmware.** Full control, realtime conversation, robot motion. The plan
   already describes it, and no Stage-1 work is wasted — `services/device-api` is the same
   backend either way.
2. **Turn-based cloud-redirect Rocky.** Point `cyberpi.cloud.recognition_set_url` and
   `tts_set_url` at device-api and accept a record → upload → think → synthesize → play cycle
   with no barge-in. Runs on unmodified firmware. Worth prototyping only if reflashing turns out
   to be unacceptable, and the endpoint protocol would have to be reverse-engineered first.
