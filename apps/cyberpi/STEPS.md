# Stage-1 steps

Small programs, run one at a time on real hardware, each proving one thing. Run them in order —
a later step is meaningless if an earlier one failed.

Every step is standalone. mBlock uploads a single program, so each file pastes in whole with no
imports from its siblings.

Fill in the Result column as you go. Steps 8–12 need `services/device-api` running; the rest need
only the board.

| # | File | Proves | Result |
| --- | --- | --- | --- |
| 1 | `steps/step01_hello.py` | upload works, screen draws, console readable | |
| 2 | `steps/step02_speaker.py` | speaker plays tones and presets, volume settable | |
| 3 | `steps/step03_record.py` | mic records and plays back; slot is single-buffered | |
| 4 | `steps/step04_loudness.py` | envelope polling rate — is VAD viable? | |
| 5 | `steps/step05_introspect.py` | **gate:** is there any raw capture path? | |
| 6 | `steps/step06_modules.py` | **gate:** sockets, and `machine.I2S` for raw output | |
| 7 | `steps/step07_wifi.py` | Wi-Fi connects | |
| 8 | `steps/step08_http_get.py` | robot reaches device-api; latency floor | |
| 9 | `steps/step09_upload.py` | uplink throughput vs the 384 kbps PCM needs | |
| 10 | `steps/step10_play_download.py` | **gate:** can server-generated audio reach the speaker? | |
| 11 | `steps/step11_concurrency.py` | does networking survive while audio is active? | |
| 12 | `steps/step12_websocket.py` | is a streaming transport possible? | |

## Running a step

1. Connect the CyberPi over USB, open mBlock 5.
2. Python editor, mode toggle set to **Upload**.
3. Paste the file, click Upload.
4. Read the screen and the serial console. Record the outcome above.

None of these steps modify firmware or persist anything. Power-cycling the board returns it to
normal CyberOS.

## The three checks that decide the gate

Everything else is supporting evidence. Stage 1 lives or dies on:

- **Step 5 — raw capture.** Can we get microphone audio out of CyberOS as bytes? The documented
  API says no ([`docs/cyberos-api-surface.md`](docs/cyberos-api-surface.md)); step 5 looks for an
  undocumented way.
- **Step 10 — raw playback.** Can bytes we generate reach the speaker? Same story.
- **Step 6 — sockets.** Without `socket`/`ssl`, the robot cannot talk to Rocky's backend at all,
  and the only remaining path is Makeblock's cloud redirects.

If capture and playback both fail, CyberOS cannot carry a realtime conversation, and the answer
to the decision gate is **no** → Stage 2.

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
