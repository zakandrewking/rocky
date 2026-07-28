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
| 5d | `steps/step05d_raw_capture.py` | **gate:** does `get_recording_data()` return real audio, and can it be read mid-recording? | Driver alive: `record_get_status()` → `0`, `record_with_time(2)` → `None`. `get_recording_data()` needs **one argument** — the step called it with none. Superseded by 5e |
| 5e | `steps/step05e_signature.py` | **gate:** find the argument `get_recording_data()` wants, then pull raw samples | **`get_recording_data(x)` → `[b'RIFF…WAVE…', ?]`** — a real WAV stream, 0x3e80 = 16000 Hz in the header. `record_start`/`record_stop` take 0 args and work; `play_recording` wants 2. Not readinto; the argument appears ignored. Payload length still unknown |
| 5f | `steps/step05f_unpack.py` | **gate:** how many audio bytes are behind that header, and do repeated calls stream? | **RAW CAPTURE CONFIRMED.** `[48-byte header, 32000 bytes PCM]` for a 2 s recording = 16,000 B/s. Header: 16000 Hz, 8 bits/sample → **16 kHz 8-bit mono, 128 kbps**. Argument ignored; repeated calls return the same buffer, no cursor |
| 5g | `steps/step05g_stream_and_output.py` | does the buffer grow *during* recording, and is there an `mic_o` equivalent for output? | **No length growth**: constant 160,000 B during recording, 49,664 B after stop. 160,000 ÷ 16,000 B/s = a preallocated **10-second max recording**. `dir(cyberpi)` = 175 members; output candidates `speaker`, `SPEAKER`, `mp3_music_o`, `mp3_music_t`, `speech`. Part 3 truncated by the console |
| 5h | `steps/step05h_output.py` | **gate:** does any output object accept raw audio? Read-only | **FOUND IT.** `cyberpi.mp3_music_o` (type `mp3_music`) has **`play_raw_data`**, **`PLAYER_MODE_RAW`**, `init`/`deinit`, and `PLAY_STATUS_PLAYING_CONTINUE`. `SPEAKER` is just preset sound names; `speech` is the cloud STT layer |
| 5k | `steps/step05k_raw_playback.py` | **THE GATE:** does `play_raw_data()` actually make a sound? | **YES — audible tone.** `play_raw_data(data, rate)` is the working form; `init()` takes no arguments. `PLAYER_MODE_RAW=2`, `PLAY_STATUS_PLAYING_CONTINUE=3`. Tests 2–3 failed on a bug in the step (kept using the one-arg form), not on the hardware |
| 5l | `steps/step05l_playback_shape.py` | is playback blocking, re-feedable, chunkable? Plus the mic echo 5k missed | |
| 5i | `steps/step05i_fill_frontier.py` | does the buffer fill *progressively*, giving us a cursor to stream from? | |
| 5j | `steps/step05j_capture_upload.py` | **milestone:** mic → network → server. Uploads a real recording so you can *listen* to it | |
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

- **Raw capture — ANSWERED YES.** `cyberpi.mic_o.get_recording_data(x)` returns
  `[48-byte header, PCM bytes]` at **16 kHz 8-bit mono**, 128 kbps. Makeblock's published API says
  this is impossible; the firmware does it anyway. Rocky can hear, on stock CyberOS.
- **Raw playback — ANSWERED YES.** `cyberpi.mp3_music_o.play_raw_data(data, rate)` produced an
  audible tone from bytes generated in Python. Found by the same `dir()` trick that found `mic_o`.
- **Step 6 — sockets.** Without `socket`/`ssl`, the robot cannot talk to Rocky's backend at all,
  and the only remaining path is Makeblock's cloud redirects.

If capture and playback both fail, CyberOS cannot carry a realtime conversation, and the answer
to the decision gate is **no** → Stage 2.

### The lesson from steps 5 and 5c

The published API package is a **subset** of the firmware, not a description of it: 33 audio
members on the board versus about 20 in the package, plus an entire undocumented I2S driver. Every
"CyberOS cannot do X" claim derived from that package is unproven until a `dir()` on real hardware
says so. That is what these steps are for.

## Verdict: **CyberOS can do audio I/O — but not to the bar this project set. Building Stage 2.**

- **Raw microphone capture: YES.** `cyberpi.mic_o.get_recording_data(x)` → `[48-byte header,
  PCM]`, 16 kHz 8-bit mono, **10-second maximum, single preallocated buffer, no read cursor.**
- **Raw speaker playback: YES.** `cyberpi.mp3_music_o.play_raw_data(data, rate)` plays bytes
  generated in Python. Confirmed audible. Chunked/re-feedable behavior still open (step 5l).
- Sockets / HTTPS: _pending (steps 6–8)_
- Sustained traffic during audio: _pending (step 11)_

Both audio halves work on **unmodified Makeblock firmware**, through an API Makeblock does not
document. Read narrowly, the plan's decision gate says stop here. But the gate's bar — "a good
realtime conversation" — was underspecified until the product target became explicit: **the full
experience, ~10 ms audio buffering and barge-in**, matching what the desktop app already delivers
over WebRTC.

CyberOS's Python API cannot reach that bar. A 10-second all-or-nothing recording buffer with no
cursor cannot stream; nothing confirms simultaneous record+playback, which barge-in requires; and
nothing in the API offers frame-level control anywhere near 10 ms. It is a scripting layer over an
opaque driver, not a real-time audio stack.

### Decision: proceed to Stage 2

**Native ESP32 firmware, driving the ES8218E codec directly over I2S**, is what full duplex and
barge-in require. See [`PLAN.md`](PLAN.md) for the concrete spec and sequence. None of this work
is wasted:

- the ES8218E register map in [`docs/upstream-sources.md`](docs/upstream-sources.md) is exactly
  what Stage 2 needs to bring the codec up, and it was found before any of this hardware probing
  started
- `services/device-api` is the same backend either way
- the measured audio format (16 kHz, sign convention, WAV decoding) transfers directly

The turn-based cloud-redirect fallback (`cloud.recognition_set_url` / `tts_set_url`) is not being
pursued — it would still fall short of the bar even if it worked.

### What Stage 1 leaves settled for Stage 2

- The hardware is capable: the same mic and speaker this Python API drives will be driven
  natively.
- The codec is identified and its registers are known, without having opened a single I2S line.

Steps 6-12 (sockets, TLS, sustained throughput under MicroPython) are **not being pursued.** The
native client uses a different network stack entirely (ESP-IDF/Arduino `WiFiClientSecure` rather
than `usocket`/`ussl`), so those MicroPython-level results would not transfer, and Stage 2 will
measure its own networking directly against the real client instead of a proxy for it.
