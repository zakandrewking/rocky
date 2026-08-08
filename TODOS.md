# Rocky TODOs

## Product and platform direction

- Build for local, family use with kid-friendly behavior by default.
- Prefer the simplest reliable local-first architecture.
- Prioritize voice latency and conversational feel over model cost initially.
- Optimize for macOS on this computer first; portability can come later.
- Allow Rocky to create and open local `.xlsx` files, launch approved macOS apps, and provide
  a Dock or Desktop launcher.
- Create an original character voice with Rocky's curious, musical, enthusiastic spirit; do
  not reproduce copyrighted dialogue verbatim.

## Future work

in approximate priority order

- [x] Choose a local macOS-first architecture for voice and native file control.
- [x] Build the first Electron voice shell around OpenAI's Realtime API.
- [x] Add a `create_spreadsheet` voice tool with `.xlsx` generation and automatic opening in
  the default macOS spreadsheet app.
- [x] Test the first full spoken conversation against the live API.
- [x] Verify direct workbook creation and foreground handoff to Numbers.
- [x] Keep ignored local transcript and spreadsheet history in `local-data/`.
- [x] Persist bounded recent conversation continuity across app restarts in ignored local data, so
  a fresh Realtime session can resume after a crash, disconnect, or manual restart.
- [x] Standardize spreadsheet viewing and editing on open-source ONLYOFFICE Desktop Editors.
- [x] make sure we have some personality instruction in the prompt. use what you learned from the 
  film. rocky likes to connect and interact with people, learn about them, connect. If you do not
  have the film screenplay, download it to this repo for reference.
- [x] to make this possible, implement a rudimentary memory system that saves to and reads from a 
  local file. and update the prompt appropriately
- [x] Make the Electron UI text-free: only the rock, with hover, click, and draggable-background behavior.
- [x] Make repeated spreadsheet updates open as distinct workbook revisions so ONLYOFFICE visibly foregrounds the new content instead of showing a cached copy of the original path.
- [x] Add repeatable text-mode style evals and preserve failed phrases as negative examples.
- [x] Make the initial greeting, acknowledgement, science, and safety style evals pass repeatedly
  in text mode.
- [x] Automatically capture failed Realtime greetings and their broken rules under `local-data/`.
- [x] Audit every Realtime reply against the default cadence profile during family testing.
- [x] Add personality evals for specific curiosity, direct emotional connection, cadence, and
  natural recall of one relevant memory.
- [x] Add an interactive text-only conversation lab using the production prompt and memory.
- [x] Add an offline reviewer for every captured voice and text-lab utterance.
- [x] Locate the author's gist, reference audio, trained RVC model, and stated personal-use terms.
- [x] Benchmark persistent local YourTTS on this Mac (0.41–0.49 seconds for 4–6 second clips).
- [x] Add a loopback-only persistent YourTTS worker without committing voice assets or weights.
- [x] A/B raw and 1.5× YourTTS output against the author's published final-product sample; initial
  family feedback says the generated examples are not good enough.
- [x] Port Lahiru Maramba's MIT-licensed Eridian alien-voice synthesizer to TypeScript/Web Audio:
  deterministic three-note word chords, special emotional vocabulary, stable hashed chords for
  unknown words, melodic name signatures, punctuation/excitement dynamics, and pre-warmed caching.
- [x] Add an offline WAV renderer for auditioning the live Eridian vocabulary and timing without
  launching a conversation or spending an API call.
- [x] Evaluate Hume custom voice cloning from the Rocky seed/reference audio. Verify the current
    creation workflow, account-private voice-ID behavior, API availability, latency, pricing, and
    personal-use terms; never commit the Hume API key or voice ID. A/B it against Piper candidates.
  - [x] Confirm Octave 2 supports private saved voices, incremental WebSocket text input, streaming
    output, and advertised model latency near 100 ms before network transit.
  - [x] Add a no-secret, ignored-output audition command that generates three original adult alien
    voice designs. Prefer this consent-safe design route unless suitable rights for cloning exist.
  - [x] Add a local Hume API key, generate three original Voice Design candidates, and family-rank
    them; candidate 3 was the clear initial winner.
  - [x] Save Voice Design candidate 3 as the private account voice `Rocky Original` and keep its ID
    in ignored local configuration.
- [ ] Implement Hume Octave 2 bidirectional streaming behind a provider boundary, with buffered incremental text, immediate barge-in cancellation, and the Eridian chord layer mixed locally.
  - [ ] Keep the Hume key and private voice ID in Electron's main process; give the renderer only
    narrowly scoped IPC audio events, never reusable credentials.
  - [ ] Switch OpenAI Realtime to text-only output when Hume is selected while preserving WebRTC
    microphone input, semantic VAD, conversation state, memory, and spreadsheet tool calls.
  - [ ] Stream sentence-aware text chunks to Hume and schedule returned PCM without gaps, while
    keeping orb listening/thinking/speaking states synchronized to real playback.
  - [x] Let concise alien chords begin immediately and rely on natural Hume generation latency for
    their head start; compress chord timing so the human translation finishes later. Keep an optional
    bounded extra English-start delay, defaulting to zero, for family tuning and future settings UI.
  - [x] Reduce Hume flush boundaries by buffering short sentence chunks into larger utterances and
    sending an explicit final flush at the end of Rocky's turn to reduce accent/prosody drift.
  - [x] Fix Rocky repeating lines aloud: the first-audio watchdog retried Hume speech after 2.5s of
    silence without cancelling the original request, so a merely slow (not lost) synthesis and its
    retry both delivered audio for the same text back to back. Cancel the stale session before
    resending.
  - [ ] On barge-in, cancel the active OpenAI response, abort Hume generation, clear queued PCM and
    Eridian chords immediately, and prevent Rocky's output from feeding back into the microphone.
  - [ ] Fall back cleanly to the working OpenAI voice if Hume is unavailable, rate-limited, or
    misconfigured; record a useful ignored diagnostic without speaking implementation details.
  - [ ] Measure time-to-first-audio and full turn latency in ignored session diagnostics, then run
    end-to-end family tests for greeting, interruption, memory, and spreadsheet creation/update.
- [x] Implement a live ONLYOFFICE active-sheet bridge so Rocky can update the visible workbook in
  place instead of creating a new revision for every follow-up edit.
  - [x] Add an authenticated loopback bridge in Electron main, with local token storage under
    ignored `local-data/`.
  - [x] Add a hidden ONLYOFFICE Desktop Editors plugin that polls Rocky and replaces the active
    sheet with the complete updated table.
  - [x] Add install/status scripts and verify the plugin connects when a workbook is open in
    ONLYOFFICE Spreadsheet Editor.
- [x] Add a small Rocky `.xlsx` command-line tool for inspect, set-cell, and append-row workflows,
  so agent/debug work can edit Excel files without driving ONLYOFFICE UI.
- [x] Make Rocky's generated `.xlsx` and `.docx` files durable and discoverable across sessions:
  save them under ignored `local-data/`, inject recent file context into new conversations, and
  add voice tools for listing/opening prior Rocky files so useful work is not lost.
- [ ] Extend the Rocky `.xlsx` CLI toward the richer Claude spreadsheet skill pattern:
  /var/folders/6w/1gtm6b0n6s16j6p_fvlqbrfm0000gn/T/claude-hostloop-plugins/ccb68a6b8377b360/skills/xlsx/SKILL.md
- [ ] Rework live spreadsheet edits to operate more like Claude's spreadsheet skill: inspect/read
  the existing workbook, apply targeted cell/range/table operations with dedicated Excel tools,
  save the `.xlsx`, and use ONLYOFFICE only as the final visual refresh/control layer. Rocky
  should not tell users he can only replace a whole sheet.
  - [ ] Support concurrent human + Rocky edits in ONLYOFFICE: before Rocky edits, ask the
    ONLYOFFICE plugin to save/sync the active document, reread the relevant workbook ranges with
    CLI tools, apply targeted edits to the freshest `.xlsx`, then refresh only the affected visible
    cells/ranges. Avoid overwriting user changes made since Rocky last opened the file.
    - [x] Add first-pass `save_active_document` bridge command and call it before disk-based
      targeted edits when the ONLYOFFICE plugin is connected.
    - [ ] Validate the save command end to end inside ONLYOFFICE Desktop Editors with a human edit
      made in the visible workbook before Rocky edits.
  - [ ] Add voice tools for reading current workbook structure/ranges and applying targeted edits.
  - [ ] Preserve existing formulas, styles, sheet names, and user conventions when editing a
    workbook; never flatten formulas by accidentally saving a value-only read.
  - [ ] Add formula-aware verification: detect formulas, recalculate with LibreOffice when needed,
    report formula errors, and avoid shipping changed workbooks with new calculation failures.
  - [ ] Add clear assumptions/comments for hardcoded values in generated spreadsheets where useful.
  - [ ] Extend the ONLYOFFICE bridge beyond whole-sheet replacement to ranged cell updates, append
    rows, sheet selection, and refresh/reopen behavior.
  - [ ] Make prompts prefer targeted workbook edits for follow-up spreadsheet changes, falling
    back to whole-sheet replacement only when the requested edit genuinely changes the full table.
- [ ] Rework DOCX generation to match the Claude docx skill pattern for production-quality output:
  `docx` npm generation with explicit US Letter geometry, real headings/lists, no literal bullets
  or newline hacks, and a render-to-PDF/image verification loop where practical.
  - [ ] Add a DOCX render smoke/QA script using LibreOffice and Poppler for generated how-to docs.
  - [ ] If Rocky edits existing DOCX files later, unzip/edit XML/validate instead of using
    `docx` as if it could safely round-trip existing documents.
- [ ] Test a spoken spreadsheet tool call end to end.
- [ ] Test a spoken visible-spreadsheet update end to end.
- [ ] Verify that asking for all Minecraft biomes proactively opens a scoped biome workbook.
- [ ] Make Rocky naturally learn who is speaking: when the current speaker has not introduced
  themselves, ask once per session what first name or nickname to use, remember the volunteered
  answer, and associate later safe facts with that person without requesting private information.
- [ ] Improve local memory identity correction and merging so a speech-to-text misspelling such as
  `Zac` can be corrected to `Zak` without leaving duplicate people or orphaning earlier facts.
- [x] Add first-pass asynchronous research handoffs for questions without obvious or stable answers. Rocky's
  low-latency conversation should dispatch a slower web-search-enabled reasoning agent, continue
  talking without blocking, and let the research agent pop naturally back into the live conversation
  when ready, similar to GPT-Live offloading long-running work to GPT-5.5.
  - [x] Preserve the originating question and conversation context, expose pending/completed/failed
    state, save results locally, and inject same-session completions back into conversation.
  - [x] Persist recent background-research status and load it into the debug panel after restarts.
  - [x] Return a concise spoken answer with source provenance saved in the local transcript; apply
    kid-safe browsing rules and never let untrusted web content directly control local tools.
  - [ ] Add explicit cancellation UI/voice behavior and stale-topic suppression beyond session matching.
- [ ] Tune Rocky's prompt, voice, interruption behavior, and musical personality with the family.
  - [x] Stabilize the voice state machine by disabling automatic Realtime VAD response creation
    and interruption, making Rocky explicitly create the first short greeting, and guarding
    speech-start events that are likely caused by Rocky's own output.
  - [x] Add rare, context-triggered family easter eggs for oversized encouragement, literal joke
    reveals, ball-sport innocence, whole-good wordplay, affection for Earth and friendship, sensory
    planet names, reciprocal creature nicknames, messy-room reactions, and alien disgust at eating;
    reserve exact `Rocky hate Mark.` for the explicitly invoked fictional in-joke only.
- [ ] Add a friendly settings screen for model, voice, and API-key status.
- [ ] Package and sign a macOS `.app`, then add it to the Dock and optionally the Desktop.
- [x] Add an unsigned macOS DMG build, GitHub Releases workflow, README release docs, and a
  one-time family-Mac bootstrap script that installs ONLYOFFICE, writes app-data config, installs
  the ONLYOFFICE plugin, and opens the latest Rocky DMG.
- [ ] Add code signing, notarization, and polished versioned release notes for public-quality
  macOS releases when Apple credentials are available.
- [ ] Verify the hardened greeting on the exact Realtime voice model and add its transcript to
  the negative set if it drifts.
- [ ] Select a voice engine only after it clearly beats the published YourTTS sample in family A/B.
- [ ] Replace the preset voice with the trained Rocky voice from [Pedram Amini's Rocky voice-clone project](https://pedsidian.pedramamini.com/Claude/Blog/2026-03-28-rocky-voice-clone#The%20Final%20Product). Locate the model/artifacts, confirm their license and permitted use, and determine the lowest-latency way to combine them with the conversational model. Do not constrain the architecture to OpenAI Realtime: evaluate Deepgram and other realtime STT, conversational-model, and TTS providers or local STT/TTS engines, choosing the stack with the best naturalness, interruption handling, latency, and tool use for Rocky. Local speech-to-text and text-to-speech are acceptable; keep the conversational/reasoning model hosted for now because local AI models are expected to be too slow.
- [ ] Add optional long-term family memory with clear parental controls.
- [ ] Swap to GPT-Live when OpenAI makes it available through the API and it improves the
  experience over GPT-Realtime.
- [ ] Try a Hume voice clone from the best available Rocky reference audio after confirming the necessary rights or speaker consent. A/B the clone directly against Voice Design candidate 3; keep all uploaded source audio, generated samples, and private voice IDs local and uncommitted.
- [ ] A/B the public Piper `en_US-lessac-low` and `en_US-joe-medium` ONNX voices with identical
  Rocky lines; tune speech rate and Piper variation controls, and verify each model card/license.
- [ ] Keep searching the internet for stronger public Piper ONNX candidates. Prefer candidates
  with an author-provided YouTube/audio demo, exact downloadable model and JSON files, clear
  provenance, and personal-use-compatible licensing so expectations can be set before setup.
- [ ] Layer the Eridian voice with translated English without harming intelligibility. Family-test
  quiet simultaneous chords versus a short emotional chord before speech, with independent volume
  and mute controls; keep the alien voice instant, local, and available even if English TTS fails.
- [ ] Add an experimental Realtime text-output mode and play local WAV replies only after a voice
  engine passes that quality gate.
- [ ] Preserve interruption handling by stopping local playback as soon as the family speaks.
- [ ] Compare YourTTS against the supplied RVC model only if artifacts and latency justify it.

## Rocky on a robot (apps/cyberpi)

Giving Rocky a body: a Makeblock mBot2/CyberPi. The plan is in `apps/cyberpi/PLAN.md`; the
Stage-1 hardware log is `apps/cyberpi/STEPS.md`.

**Stage 1 (CyberOS, no firmware changes) is spiked and closed. Stage 2 (native ESP32 firmware) is
the active target**, because the product bar is the full experience — ~10 ms audio buffering and
barge-in — which CyberOS's Python audio API cannot reach even though raw audio I/O on it works.

### Stage 1 — done, kept as reference

- [x] Write the two-stage plan: CyberOS app first, native ESP32 firmware if CyberOS cannot meet
  the bar.
- [x] Document the CyberOS API surface from Makeblock's published `makeblock` package. It claims no
  raw sample input and no arbitrary sample output - wrong, as hardware later showed, but the
  starting hypothesis.
- [x] Break Stage 1 into small hardware steps, each proving one thing, each standalone because
  mBlock uploads a single program at a time.
- [x] Build `services/device-api`: device-token auth, ephemeral OpenAI client secrets so the key
  never lives on the robot, probe endpoints, a report sink under `local-data/cyberpi/`, and a
  decoder that turns the CyberPi's raw audio format into playable WAVs. Carries forward into
  Stage 2 unchanged.
- [x] Run steps 1-4 on real hardware: toolchain, speaker, microphone, loudness all work.
- [x] Discover the published API is a *subset* of the firmware. The board exposes an undocumented
  raw I2S microphone driver (`cyberpi.mic_o`, type `i2s_mic`) and an undocumented raw playback
  object (`cyberpi.mp3_music_o`, `play_raw_data`).
- [x] Confirm raw capture: `cyberpi.mic_o.get_recording_data(x)` -> `[48-byte header, PCM]`, 16 kHz
  8-bit mono, **10-second maximum, single preallocated buffer, no read cursor**.
- [x] Confirm raw playback: `cyberpi.mp3_music_o.play_raw_data(data, rate)` produced an audible
  tone from Python-generated bytes.
- [x] Check for published source before reverse-engineering further. Makeblock's CyberOS firmware
  is closed, but a GPL-3.0 sibling library (`CyberPi-Library-for-Arduino`) named the audio codec -
  **Everest ES8218E on I2C 0x10** - and its full register map. See
  `apps/cyberpi/docs/upstream-sources.md`. This is Stage 2's starting point.
- [x] **Decide: CyberOS's Python audio API cannot reach the ~10 ms buffering / barge-in bar.** A
  10-second all-or-nothing recording block with no cursor cannot stream; nothing confirms
  simultaneous record+playback; nothing offers frame-level control. Close Stage 1 as a spike,
  proceed to Stage 2. Full reasoning in `apps/cyberpi/STEPS.md`.

### Stage 2 — native firmware, active

The product bar is explicit: **the full experience - ~10 ms audio buffering and barge-in** -
matching the desktop app's WebRTC session, not a turn-based approximation of it.

- [x] Design the recovery strategy: dump the board's entire flash before any custom firmware
  touches it, rather than depending on Makeblock publishing a downloadable official image (they
  don't appear to - updates go through mBlock's GUI flow only). Write `pnpm cyberpi:backup` /
  `pnpm cyberpi:restore` (`apps/cyberpi/scripts/`, `docs/recovery.md`). **Verified against real
  hardware**: full 8MB backup/restore round trip on the real board (ESP32-D0WD, port
  `/dev/cu.usbserial-210`), esptool's own hash verification passing, and a confirmed power-cycle
  back into normal CyberOS.
- [x] **Run the recovery scripts for real**, on a machine with physical access to the board.
  `pnpm cyberpi:backup` and `pnpm cyberpi:restore` both ran clean against the real board (ESP32-
  D0WD, 8MB flash, port `/dev/cu.usbserial-210`): full 8MB backup, restore with esptool's own
  post-write hash verification passing, and a confirmed power-cycle back into normal CyberOS (home
  screen, LEDs). One real fix was needed - esptool 5.3.1 renamed `flash_id`/`read_flash`/
  `write_flash` to the hyphenated `flash-id`/`read-flash`/`write-flash`; scripts updated to match.
- [x] Bring up the PlatformIO toolchain and confirm the framework: **ESP-IDF**, confirmed
  (`apps/cyberpi/platformio.ini`, `board = esp32dev`). Checked `CyberPi-Library-for-Arduino` first
  and found the board's LEDs/buttons are behind I2C (AW9523B expander, LED driver at `0x5B`), not
  raw GPIO, so the trivial program prints over serial instead of blinking. `pnpm cyberpi:flash-rocky`
  built and flashed clean; serial output confirmed a steady tick counter with no resets. Also fixed
  a real flash-size mismatch (`sdkconfig.esp32dev` had picked up ESP-IDF's 2MB default against this
  board's actual 8MB). By explicit choice, not restored back to stock CyberOS afterward - Stage 2
  continues from the custom firmware now on the board.
- [x] **Bring up OTA updates - done.** Board joins Wi-Fi (credentials from the repo root `.env`
  into a gitignored generated header) and runs a minimal HTTP `POST /ota` receiver that writes to
  the inactive `ota_0`/`ota_1` partition (new `partitions_ota.csv`, sized for the real 8MB flash)
  and reboots into it. Verified for real: flashed once over USB, then pushed a second build with
  `pnpm cyberpi:ota` and confirmed over serial the board rebooted into the new firmware. No auth on
  the receiver yet - fine for LAN-only bring-up, needs fixing before this ever ships.
  `cyberpi:restore` over USB stays the fallback for when OTA itself is unreachable.
- [ ] Add auth to the CyberPi's `/ota` HTTP receiver (currently open to anything on the LAN) before
  this firmware is ever used somewhere the Wi-Fi network isn't fully trusted.
- [x] **Bring up the ST7789 display - done.** Native SPI driver against ESP-IDF's `spi_master`,
  DC/RESET/backlight driven through the AW9523B I2C expander rather than raw ESP32 pins. Verified
  for real: `st7789_fill()` painted a solid green screen on the real board.
- [ ] Bring up the ES8218E over I2S using the register map already in hand; confirm raw capture and
  playback at ~10 ms frames before building anything on top.
- [ ] One-directional streaming milestones: `mic -> 10ms frames -> network -> server` and
  `server -> network -> 10ms frames -> speaker`, each proven gap-free before combining them.
- [ ] Full duplex + barge-in: both directions active at once, VAD on the live mic during playback,
  interrupt-and-flush on trigger. This is the milestone that actually delivers "the full
  experience" and the reason Stage 2 exists.
- [ ] Then: the embedded Rocky state machine, personality reuse from the backend, robot tool calls
  (`drive_cm`, `rotate_degrees`, `read_distance`, ...), and packaging.
- [ ] Extract `packages/rocky-core` for the shared persona once the native client's needs are
  clearer. Until then `services/device-api` imports `ROCKY_INSTRUCTIONS` from the desktop app by
  relative path, which is why `verbatimModuleSyntax` is off in its tsconfig.

## Rocky on a robot, take two: a networked body (apps/robot)

Independent from the `apps/cyberpi` track above. That one asks whether the CyberPi can carry a
realtime *voice* conversation on-device. This one doesn't need that answer: the laptop keeps the
microphone and speaker (the existing desktop app already meets the realtime bar), and the CyberPi
only drives the mBot2 Shield's motors and sensors over Wi-Fi. Plan is in `apps/robot/PLAN.md`.

**North star: Rocky navigates a room, finds a person, follows them, and talks to them, without
crashing.**

- [x] Write the plan: architecture, the three original open questions answered (OTA is not what
  the initial source claimed; obstacle avoidance is a device-side reflex, not a firmware toggle;
  route-planning lives on the laptop), spatial mapping via ultrasonic rotate-and-ping, and a
  camera-based semantic layer for finding people.
- [x] Check published sources before assuming the mBot2 Shield's Python API: found real device
  examples (`github.com/PerfecXX/mBot2`) giving confirmed `mbot2.straight(cm)`, `mbot2.turn(deg)`,
  `mbot2.drive_speed()`, and `cyberpi.get_yaw()` for heading — stronger evidence than the
  generated `makeblock` PyPI package alone, which is where the ultrasonic/line-sensor calls still
  come from. See `apps/robot/docs/mbuild-api-surface.md`.
- [x] Build the laptop-side SDK (`@rocky/robot`): bounded command protocol so an LLM tool call can
  never request unsafe speed/distance/angle, a mock transport for hardware-free testing, and a
  real TCP transport. 25 tests passing, no hardware needed.
- [x] Write the CyberOS device agent (`apps/robot/device/rocky_agent.py`) against the confirmed
  API. Untested on hardware — no board attached in this environment. Built on `drive_speed()` in
  short interruptible bursts rather than the (apparently blocking) `straight()`/`turn()`, because
  the obstacle-avoidance reflex needs to be able to cut in mid-drive.
- [ ] **Run `apps/robot/STEPS.md`'s hardware gate**: confirm a real TCP socket actually opens from
  an uploaded stock-CyberOS program. Strong circumstantial evidence it works (an MQTT example
  reaches a public broker), but unconfirmed by this project. If it fails, the fallback is porting
  this agent onto `apps/cyberpi`'s already-working native-firmware networking instead.
- [ ] Confirm whether `mbot2.straight()`/`turn()` actually block the interpreter, which decides
  whether the `drive_speed`-based interruptible loop is necessary.
- [ ] Calibrate drive_speed RPM-to-cm/s and deg/s, and the em1/em2-to-wheel sign convention.
- [ ] Rotate-and-ping ultrasonic scan against a real room; stitch 2-3 scans into one occupancy
  grid using odometry + `cyberpi.get_yaw()`; check real-world drift.
- [ ] Verify the obstacle-avoidance reflex stops a commanded drive locally, without waiting on the
  laptop, when something is placed in the ultrasonic's path mid-motion.
- [ ] Laptop-side frontier navigation against the occupancy grid.
- [ ] Camera semantic layer: detect a person, estimate bearing, turn to face them. Needs a camera
  on/near the robot, which otherwise doesn't arrive until the laptop's physical mount — decide
  explicitly whether to add a cheap webcam earlier instead of waiting.
- [ ] Add an explicit, visible on/off for the camera layer and no persistent recording by default;
  a camera on a family device is a bigger privacy step than audio alone.
- [ ] Find/follow: combine occupancy-grid navigation with person bearing to approach and hold a
    comfortable distance.
- [ ] North-star run: navigate, find a person, approach, and hand off to the existing desktop
  Rocky voice conversation, without crashing. Run repeatedly; tune thresholds against what
  actually happens on hardware, not what was assumed in the plan.
