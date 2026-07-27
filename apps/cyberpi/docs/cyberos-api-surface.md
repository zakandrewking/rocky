# CyberOS API surface (audio, network, display)

This is the API inventory Stage 1 depends on. It is desk research, not hardware measurement.

> **Superseded in part by hardware, 2026-07-27.** Running step 5 on a real CyberPi
> (MicroPython `44.01.008-16-g7e26a976-dirty`, 2025-11-14, ESP32) showed the published package
> is a **subset** of the firmware, not a description of it. The board reports **33** members on
> `cyberpi.audio` where the package documents about 20, and it exposes `cyberpi.mic`,
> `cyberpi.microphone`, a third `mic_o…` member, and `cyberpi.audio.file_handle` — none of which
> appear in the package at all.
>
> So the conclusion below — "no raw sample input" — is **not established**. It was inferred from
> an incomplete source. Treat everything past this point as documentation of what Makeblock
> *publishes*, which is useful and still true, but not as a description of what the hardware can do.

## What the firmware actually exposes (step 5c)

`cyberpi.mic_o` is an object of type **`i2s_mic`** — the raw I2S microphone driver, reachable
straight from Python:

| Member | Why it matters |
| --- | --- |
| `get_recording_data()` | **raw sample readout** — the thing the published API has no equivalent of |
| `record_start()` / `record_stop()` | explicit control, the shape a streaming loop needs |
| `record_with_time(n)` | fixed-length capture |
| `record_get_status()` / `record_set_status()` | state inspection |
| `init()` / `deinit()` | configure the I2S peripheral directly |
| `play_recording()`, `get_loudness()` | the parts the documented API also has |

Alongside it: `cyberpi.mic` (the class), `cyberpi.microphone` (a `mic` instance wrapping the
documented `record`/`play_record`/`stop_record`/`get_loudness`), and `cyberpi.audio.file_handle`,
which is `None` and appears to be a placeholder rather than a way in.

Free heap measured **1,273,632 bytes** — about 26.5 seconds of 24 kHz 16-bit mono PCM. Memory is
not a constraint on buffering.

Whether `get_recording_data()` returns real samples, at what rate and width, and whether it can be
read *during* a recording, is what `steps/step05d_raw_capture.py` measures.

**The methodological point:** the board reports 33 members on `cyberpi.audio`; the package
documents about 20. Anything below that says CyberOS "cannot" do something is a statement about
the documentation, not the hardware, until a `dir()` on a real board confirms it.

## Where these names come from

Makeblock publishes the CyberPi API as a generated Python package. Every callable in the
mBlock/CyberOS surface appears there, so it is a reliable inventory of what CyberOS exposes —
more reliable than the HTML docs, which are incomplete.

```bash
pip download makeblock --no-deps -d /tmp/mb && unzip -o /tmp/mb/*.whl -d /tmp/mb_x
sed -n '/^class audio_c/,/^audio=/p' /tmp/mb_x/makeblock/modules/cyberpi/api_cyberpi_api.py
```

Inspected: `makeblock` 0.1.8, `makeblock/modules/cyberpi/api_cyberpi_api.py`.

One caveat worth stating plainly: that package implements *online mode*, where a PC drives the
board over a serial link. On-device *upload mode* MicroPython runs the same names, but the
generated package cannot prove which extra MicroPython modules (`socket`, `ssl`, `machine`)
the CyberOS firmware build ships. The probe covers that gap.

## Audio

The complete audio surface, verbatim:

| Call | What it does |
| --- | --- |
| `cyberpi.audio.play(name)` | play a **preset** audio file by name |
| `cyberpi.audio.play_until(name)` | same, blocking until playback ends |
| `cyberpi.audio.record()` | start recording into one internal slot |
| `cyberpi.audio.stop_record()` | stop recording |
| `cyberpi.audio.play_record()` | play back that slot |
| `cyberpi.audio.play_record_until()` | same, blocking |
| `cyberpi.audio.play_tone(freq, t)` | synthesize a tone |
| `cyberpi.audio.play_note(note, beat)` | synthesize a note |
| `cyberpi.audio.play_drum(type, beat)` | synthesize a drum hit |
| `cyberpi.audio.play_music(note, beat, type)` | synthesize an instrument note |
| `cyberpi.audio.set_vol(v)` / `add_vol(v)` / `get_vol()` | volume |
| `cyberpi.audio.set_tempo(pct)` / `add_tempo(pct)` / `get_tempo()` | tempo |
| `cyberpi.audio.stop()` | stop playback |
| `cyberpi.get_loudness(mode="maximum")` | a single scalar loudness reading |

Read that table against what a realtime voice loop needs:

- **Recording takes no destination and returns nothing.** `record()` / `stop_record()` write to one
  opaque internal slot. There is no path, no handle, no byte buffer — the only documented consumer
  is `play_record()`. No second recording can exist at the same time.
- **Playback takes a name, not data.** `play(name)` selects a preset file. Nothing in the surface
  accepts a caller-supplied PCM buffer, WAV bytes, or a stream.
- **`get_loudness()` is a scalar, not samples.** It is an envelope follower, useful for a
  voice-activity trigger or a mouth animation — not for transmitting speech.

Makeblock's own forum threads match this reading: users repeatedly ask how to record into a
variable, keep more than one recording, or get at recorded audio, and no API is offered in reply.

So the documented surface has **no raw sample input and no arbitrary sample output**. If that
holds on hardware, Stage 1's audio gate fails on its own terms, and no amount of clever
networking rescues it.

The one documented escape hatch is Makeblock's cloud layer, described below.

## Network

| Call | What it does |
| --- | --- |
| `cyberpi.wifi.connect(ssid, password)` | join a network |
| `cyberpi.wifi.is_connect()` | connection status |
| `cyberpi.cloud.setkey(key)` | authenticate to Makeblock cloud |
| `cyberpi.cloud.listen(language, t=3)` / `listen_result()` | record → cloud speech-to-text → string |
| `cyberpi.cloud.tts(language, message)` | text → cloud speech → speaker |
| `cyberpi.cloud.translate(language, message)` | cloud translation |
| `cyberpi.cloud.weather / air / time` | cloud data lookups |
| `cyberpi.cloud.recognition_set_url(url)` | **redirect** speech recognition to a custom URL |
| `cyberpi.cloud.tts_set_url(url)` | **redirect** text-to-speech to a custom URL |
| `cyberpi.cloud.translate_set_url(url)` | redirect translation to a custom URL |
| `cyberpi.wifi_broadcast.set/get`, `cloud_broadcast`, `mesh` | small message passing |

Two things stand out.

There is **no general HTTP client in the CyberPi namespace** — no `get`, no `post`, no socket. If
the robot is to talk to Rocky's own backend, it has to come from the MicroPython runtime
underneath (`socket`, `ssl`, `urequests`). Whether the CyberOS firmware ships those is the single
biggest unknown in Stage 1, and the probe's `network` section exists to answer it.

The `*_set_url` redirects are the interesting find. They suggest a **fallback architecture** that
needs no raw audio at all: point `recognition_set_url` and `tts_set_url` at Rocky's device-api,
and the loop becomes

```
cloud.listen()  → our STT endpoint  → text
                                       ↓
                              Rocky backend / OpenAI
                                       ↓
cloud.tts()     ← our TTS endpoint  ← text
```

That is turn-based, not realtime: no barge-in, no streaming, and latency is the sum of a full
record-upload-think-synthesize-download cycle. It is a worse Rocky than the desktop app. But it
may be a *working* Rocky on unmodified firmware, and it is worth knowing it exists before
committing to Stage 2. The probe records whether these endpoints are reachable and what protocol
they speak, because that protocol is undocumented and would have to be reverse-engineered.

## Display and lights

Enough for the Stage-1 screen UI, with no surprises:

- `cyberpi.display.label(msg, size, x, y)`, `show_label(...)`, `clear()`, `set_brush(r,g,b)`,
  `rotate_to(angle)`, `off()`
- `cyberpi.console.print/println/clear`
- `cyberpi.led.on(r,g,b,id)`, `play(name)`, `show(color)`, `move(step)`, `set_bri(v)`, `off()`

A tiny Rocky face is drawn with labels and brush colors, and the 5 RGB LEDs carry state color.
This part of Stage 1 is not at risk; it is gated entirely on the audio answer.

## What the probe must settle

| # | Question | Why it decides the gate |
| --- | --- | --- |
| A1 | Do `record` / `stop_record` / `play_record` work on device? | baseline audio sanity |
| A2 | Does a filesystem hold the recording where `os` can read it? | an undocumented file is a raw-audio path |
| A3 | Any undocumented member exposing samples or a file argument? | ditto |
| A4 | Can arbitrary PCM/WAV reach the speaker (`machine.I2S`, `machine.DAC`, a file)? | output half of the loop |
| A5 | How fast can `get_loudness()` be polled? | tells us VAD/mouth animation is viable, and reveals scheduler granularity |
| N1 | Does `wifi.connect` work? | prerequisite |
| N2 | Are `socket` / `ssl` / `urequests` importable? | without these there is no Rocky backend at all |
| N3 | HTTPS round trip to device-api, and its latency | measures the network floor |
| N4 | Can a TLS socket carry a WebSocket upgrade? | streaming transport |
| N5 | Does the network keep flowing *while audio is active*? | CyberOS may serialize the two |
| E1 | Free heap, firmware version | how much buffer we could ever hold |

A2, A3, and A4 are the ones that matter. If all three come back negative, CyberOS cannot carry a
realtime conversation, the decision gate answers "no", and Stage 2 starts with no wasted work.
