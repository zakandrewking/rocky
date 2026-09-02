# Rocky TODOs

## Rocky on a robot, take two: a networked body (apps/robot)

Independent from the `apps/cyberpi` track above. That one asks whether the CyberPi can carry a
realtime *voice* conversation on-device. This one doesn't need that answer: **an iPhone
(`apps/ios`) is Rocky's mic/speaker/camera/face**, mounted on or near the robot, and the CyberPi
only drives the mBot2 Shield's motors and sensors over Wi-Fi. Plan is in `apps/robot/PLAN.md`.
(Originally the laptop was going to keep this role instead — moved to the iPhone for its own
audio hardware/AEC and camera; see `apps/robot/PLAN.md`'s "Relationship to apps/cyberpi".)

**North star: Rocky navigates a room, finds a person, follows them, and talks to them, without
crashing.**

- [x] Add direct S3/S4 accessory-servo controls to iOS: one true vertical drag track on each edge,
  persistent min/max/reverse calibration per port, 100ms latest-target coalescing without ACK
  gating, hard 0–180° bounds on both sides, and correlated command/ack/error latency logs. The
  CyberPi slews locally toward only the newest target at about 160°/s, smoothing bursty input
  without queuing stale angles. Saved calibration remains honored, but its button and sheet are
  no longer exposed. This stays on the official grabber build's dedicated S3/S4 sockets; S1/S2 raw
  PWM was investigated and rejected as the wrong default wiring. The board call is command-time
  only, not boot-time, and non-S3/S4 ports are rejected.
- [x] Stabilize all four edge controls after live input traces exposed absolute touch-down mapping:
  make every drag relative to its current thumb position, give all four cards identical rail/overall
  height, add throttle/steering center dead zones and progressive curves, and send shaped rather
  than raw drive values. Diagnostic logs now connect finger travel and raw/shaped values to sent
  drive/servo targets, ACK latency, servo slew state, and physical target-reached latency; this also
  makes any reported post-release motion measurable instead of inferred.
- [x] Add voice-independent manual robot control to iOS: spring-return throttle and steering
  tracks sit beside the edge servo controls, appear only while the robot link is connected, take
  exclusive ownership over autonomous motor writes, heartbeat quietly at 5Hz, and stop immediately
  on release or after a 650ms lost-heartbeat
  watchdog. The board stays stopped for 700ms before returning to autonomy. Manual input fully
  overrides the autonomous obstacle reflex while held. Robot discovery runs
  at app launch independently of Realtime/API availability, with Connect/Retry kept in the
  expanded status/log popup. Voice/camera and robot controls therefore form four independent UI
  states: neither, voice+preview only, robot controls only, or both. App backgrounding explicitly
  releases the wheels and foregrounding replaces the possibly suspended robot TCP connection.
- [x] Let the person collapse the connected robot controls without disconnecting the body: a
  persistent top-left eye toggle hides/shows all four edge controls, hiding immediately releases
  any held drive input, and the toggle itself remains available while the controls are hidden.
- [x] Remove post-release wheel motion caused by observer backlog: live correlated traces showed
  stop commands taking 2.1–2.5s to be read after held-drive packets. The CyberPi now drains up to
  1024 bytes of compact control messages per tick instead of 256, while the phone retains the
  deliberately quiet 5Hz heartbeat. Finger-up therefore reaches the front of the board's work
  promptly without weakening the 650ms lost-stream watchdog.
- [x] Make Rocky's iOS speech provider swappable and add Rocky1 on ElevenLabs
  `eleven_v3_conversational`: a single ignored `.env` value selects `elevenlabs` or `hume`, while
  both implementations keep the same PCM player, interruption, and turn lifecycle. ElevenLabs uses
  the v3-only Text-to-Dialogue WebSocket with 24 kHz raw PCM, exact final-turn markers, a 10-second
  keepalive, epoch-protected cancellation, and logs for socket lifecycle, provider errors, chunk
  count, and first-audio latency. Hume remains intact as a one-line rollback plus redeploy. The
  personal-device build still bakes its limited provider key; revisit with a token-minting service
  before distributing the app.
- [x] Put a direct Gemini Robotics ER 2 + ElevenLabs voice prototype behind
  `ROCKY_VOICE_ENGINE=er2`, leaving `realtime` as the stable default. The alternate transport
  streams echo-cancelled 16 kHz PCM to ER2 Live, adapts its text/VAD/tool messages into the existing
  turn machinery, and therefore keeps the same persona, body executor, world projection, pause,
  barge-in, diagnostics, and ElevenLabs playback. OpenAI is never contacted in an ER2 session.
  The shared VoiceProcessingIO graph gained a native microphone sink rather than starting a second
  audio engine. ER2 tools are generated from the baked source-of-truth schemas as blocking Gemini
  function declarations. Its current prototype compromises are explicit: body-tool changes apply
  on reconnect, and genuinely ambiguous salience becomes quiet context because ER2 has no sideband
  response lane; deterministic safety interruptions still run locally. A device trace also caught
  the prototype's local energy detector hearing the first ElevenLabs syllable as a barge-in. Local
  energy VAD is now gated only while Rocky's audio is playing (the PCM microphone keeps streaming),
  with Gemini interruption/transcription as the authoritative barge-in signal and gated frame/peak
  RMS summaries in the log so any remaining AEC behavior is measurable. A second device trace then
  caught an audio-graph startup transient before playback, proving energy alone is not a safe speech
  start under either condition. ER2 starts are now exclusively server-confirmed; local energy only
  detects silence after such a start. The first-audio watchdog also checks actual player chunks and
  queued PCM before retrying, so stale response bookkeeping cannot cancel audio demonstrably heard.
  The following trace proved PCM callbacks were alive but ER2 automatic VAD never transcribed or
  closed a user turn. A generic-Live explicit-activity experiment cleanly detected the next spoken
  turn but ER2 closed the socket immediately after `activityEnd`. The ER2-specific guide and SDK
  source showed that its documented `send_realtime_input(media=Blob(...))` path serializes as one
  `realtimeInput.mediaChunks` blob. The next real trace supplied the missing distinction: ER2
  accepted more than 1,000 of those frames without closing the socket, but produced no VAD,
  transcription, or response event. Google's current Live wire guide instead uses the dedicated
  `realtimeInput.audio` field for microphone PCM. Rocky now uses that specialized envelope with
  automatic VAD and no explicit activity messages. Logs retain five-second uploaded frame/byte
  counts, local RMS as diagnostic-only data, and WebSocket close code/reason so attachment,
  transport, acoustics, and rejection are distinct. The first successful audio trace then exposed
  a different perceived failure: ER2 transcribed the user correctly but ignored an explicit prompt
  prohibition and called `look_now` for “what do you think?”. The fresh-look round trip plus ER2's
  continuation consumed 10.7 seconds; the user paused 1.2 seconds before its eventual text reached
  TTS. The ER2 prototype now omits demand-driven `look_now` structurally while retaining passive
  visual context, so ordinary voice turns cannot disappear behind that camera path. Body tools
  remain available when the robot is connected. The next no-tool trace transcribed two complete
  utterances but still never finalized the turn, proving residual room/AEC energy can hold ER2's
  default end detector open. Rocky now configures automatic VAD explicitly (high start/end
  sensitivity, 600ms silence) and uses Google's documented hybrid-VAD escape hatch: each input
  transcript schedules an 800ms-debounced `audioStreamEnd`, cancelled if generation begins or a
  newer transcript arrives. Automatic VAD still owns speech starts, and the audio stream can resume
  immediately, but a recognized utterance can no longer wait forever for quieter room energy. A
  sustained real conversation exposed two independent finite-resource endings: ElevenLabs began
  returning `quota_exceeded`, and ER2 sent a 50-second GoAway before force-closing code 1008 because
  Rocky ignored it. Quota errors now end the local turn immediately without a pointless retry (the
  key's quota must still be raised), while GoAway proactively rotates to a fresh ER2 session before
  the deadline. Hybrid flush also emits the adapter's speech-stop event, anchoring shared latency
  metrics to the current turn instead of an old pause; the earlier 89–148 second “think” numbers
  were instrumentation errors, not measured ER2 generation time.
- [x] Raise the ElevenLabs API key's custom quota before the next real Rocky conversation. Live
  2026-08-30 probes corrected the initial diagnosis: the free workspace has credits and both
  Flash HTTP and v3 TTD are reachable, but this particular key was capped at only 10 credits. A
  32-character Flash line alone required 16; ordinary Rocky replies cannot fit. The installed
  release selects `eleven_v3_conversational`, so increasing the same key's quota takes effect
  without another app build. Keep the cap bounded, but large enough for several thousand reply
  characters rather than several words.
- [x] Recover voice after iOS backgrounds the app. A live 2026-08-30 trace ruled out end detection:
  after foregrounding, the retained WebRTC objects still claimed to be open but no server events
  arrived—not even `response.created` for an explicit resume request, and no VAD start/stop for
  speech. Real background transitions now mark that session stale; foreground replaces it when
  voice was live, while a deliberately paused conversation waits for the person's resume tap.
  Transient inactive states do not force a reconnect.
- [x] Make the rich device log readable by default without throwing evidence away. `ios:log` now
  leads with errors/recovery and the voice/audio/app lifecycle; `--controls`, `--vision`, `--raw`,
  and `--world` expose the busy specialist views. Every `response.create` is logged at send time
  and guarded by a five-second acknowledgement watchdog, turning a nominally-open but dead data
  channel into an explicit reconnectable failure rather than ambiguous silence.
- [x] Replace queued live-control commands with a latest-state protocol after the larger TCP read
  proved to be only a mitigation. iOS now publishes one epoch/sequence-stamped UDP state for drive,
  steering, S3, and S4; the CyberPi drains a bounded batch and applies only the newest. Finger-up is
  repeated three times, stale/reordered frames are rejected, and the device watchdog remains the
  final stop boundary. TCP is retained for discovery, autonomous/voice intentions, and correlated
  `control_applied` diagnostics. Servo targets now go directly to the hobby servo's continuous
  controller instead of advancing in a main-loop-timed 8° staircase. Incremental touch tracking
  also clamps the translation-reset discontinuity captured in the S4 trace.
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
- [x] **Run `apps/robot/STEPS.md`'s hardware gate**: confirmed on real hardware — sockets work in
  both directions (board-as-client and board-as-server), no fallback to `apps/cyberpi`'s native
  firmware needed. Two real findings along the way: `network.WLAN(network.STA_IF).ifconfig()`
  never reports a real address on this firmware even when the connection is genuinely working
  (don't use it for IP discovery), and uploading a new program while a previous one's unbounded
  loop is still running can stall the transfer indefinitely — press the board's Home button before
  every re-upload. Both documented in `apps/robot/STEPS.md`.
- [x] **Run `apps/robot/STEPS.md`'s step 4b on real hardware**: confirmed — `device/bootstrap.py`
  uploaded once via mBlock, then `scripts/push.mjs` reloaded a test payload three times in a row
  with zero further mBlock/USB, including one push with the USB cable fully disconnected. Scripted
  OTA is real on stock CyberOS; `PLAN.md`'s OTA answer updated accordingly.
- [x] Make robot pushes recover from the recurring macOS/Node route mismatch: when Node reports
  `EHOSTUNREACH`/`ENETUNREACH` before connecting, `push.mjs` now retries once through the native
  TCP client. Confirmed the failure mode against a reachable live robot before adding the fallback;
  a native client uploaded the same payload and received the board's byte-count reply immediately.
- [x] Rewrite `rocky_agent.py` as a proper `bootstrap.py` payload (`tick()`-based) instead of a
  standalone blocking program left over from before the OTA loader existed. Fixed a real bug in
  the process: `drive`/`turn` used to loop internally for the whole commanded distance/angle,
  which could block the push-listener and the heartbeat watchdog for seconds. Now pushable with
  the existing `scripts/push.mjs`, no mBlock/USB needed. **Command-handling confirmed on real
  hardware**: a direct TCP client got an instant `stop` → `ack` round trip against the live board.
- [x] Added on-screen status (connection state, last command, last result, a beacon send counter,
  and the board's own detected IP) directly on the CyberPi's display, so watching the robot
  itself is enough to follow a test session — the person testing usually can't see the laptop's
  logs. Fixed a real bug along the way: `set_face()` was calling `cyberpi.display.clear()` on
  every face change, wiping the other status lines, and colliding label ids with the status line.
- [x] Scaffold `apps/ios` and **install/run it on a real iPhone** — a minimal SwiftUI app
  (XcodeGen-generated, since there's no way to drive Xcode's project GUI here) with on-device
  Speech-framework command words (forward/back/left/right/stop) over a Swift port of
  `apps/robot/src`'s protocol, and a Swift port of `push.mjs` for iPhone→CyberPi OTA. Signing
  pinned to a specific personal Apple Developer team (found and fixed a wrong team ID along the
  way — the number in a cert's display name isn't the same as its actual Team ID) so this never
  lands on a work/org account's App Store Connect. `pnpm ios:deploy` does a full build → install →
  launch over Wi-Fi with no Xcode GUI, cable, or App Store involved.
- [x] Found and fixed three real bugs from live device testing, using `xcrun devicectl` to pull
  structured crash reports and app logs straight off the phone with no Xcode GUI (same technique
  as pulling files in general — `devicectl device info files` / `devicectl device copy from`,
  `--domain-type systemCrashLogs` for crashes, `--domain-type appDataContainer` for the app's own
  files):
  - Two separate `SFSpeechRecognizer`/`AVAudioEngine` crashes (`EXC_BREAKPOINT`/`SIGTRAP`): a
    closure written directly inside a method of a `@MainActor` class defaults to MainActor-
    isolated purely from *where it's written*, regardless of what it captures, whenever the SDK's
    completion-handler parameter isn't marked `@Sendable` — and both `requestAuthorization` and
    `installTap`'s callbacks are invoked by iOS from threads that are never actually the main
    thread. Fixed by moving each into a `nonisolated static` helper.
  - A stuck "Connecting..." with no way to cancel: `NWConnection` has a `.waiting` state that can
    persist forever against an unreachable address without ever calling back. Added a connect
    timeout and a real Cancel button.
  - Voice commands "kind of worked but not well": a pulled `session.log` showed real speech
    reaching a partial transcript, then the task erroring with "No speech detected" before ever
    going final — traced to tearing down and rebuilding the *entire* audio engine and tap on every
    utterance, not just the recognition request. Now the engine/tap are set up once per listening
    session and only the lightweight request/task pair cycles per utterance; command matching
    also switched back to partial-result matching with a once-per-cycle debounce, since matching
    only on `isFinal` (an earlier, less-informed fix) starved real commands entirely once final
    results turned out to be unreliable.
- [x] Fixed a real "Stop Listening doesn't stop" bug: recognition cycles restart automatically on
  every error/final (happening every 1-2 seconds per `session.log`), so a completion callback
  from the cycle active *before* the user tapped Stop was very likely already queued and would
  restart listening again right after `stop()` tore things down. Fixed with a cycle id that every
  completion callback checks against the current one before acting — a stale callback is now a
  guaranteed no-op regardless of queuing order. Also put real usage instructions directly in the
  app (what to say, that there's no need to pause before speaking) instead of leaving that to be
  asked about.
- [x] **Settled by source research (2026-08-14): an uploaded program on stock CyberOS cannot
  learn its own IP address — there is no API for it, published or discovered.** Three legs, all
  checked against sources rather than probed: (1) `socket.getsockname()` has *never existed* in
  MicroPython's ESP32 port — verified against the socket object's actual C method table in
  upstream `modsocket.c` at v1.12, v1.17, v1.19, and master; Makeblock's firmware is a fork, so
  every `getsockname()` call raises `AttributeError`, always. (2) `network.WLAN(STA_IF)
  .ifconfig()` returns `0.0.0.0` on this firmware (already proven live in STEPS.md) because
  CyberOS manages Wi-Fi through its own private C layer, decoupled from the standard `network`
  module. (3) Makeblock's published wifi API is `connect()` + `is_connect()` — nothing else, and
  zero community examples anywhere read the board's own IP; all known networking examples are
  outbound-only. Consequence adopted: the discovery beacon carries no IP and doesn't need one —
  the receiver reads the sender's address off the UDP packet itself, the one address that is
  always correct. The on-screen "ip:" line is gone; "waiting for client" only ever meant "the
  payload booted and bound its listener locally," which says nothing about Wi-Fi.
- [ ] **Board-freeze incident, root cause CORRECTED (supersedes the earlier getsockname
  attribution): the boot-path `network.WLAN(network.STA_IF)` call is the prime suspect.** The
  clincher: after every post-freeze power cycle, the board reached "waiting for client" then
  dropped off the network entirely (no ARP, no ping, port 8766 SYN-ACKs but never serviced —
  classic hung-interpreter signature) *without any client ever connecting* — so the
  accept-branch `getsockname()` (which anyway just raises `AttributeError` and is caught, per
  the research above) never even ran. The only network-touching code that did run was the
  boot-path WLAN call, fighting CyberOS's private Wi-Fi manager for the driver.
  `rocky_agent.py` now has no `import network` at all, with the incident documented inline.
  Remaining: actually recover the board — its flash still holds the buggy payload
  (`bootstrap.py` re-execs it from flash on every boot, so power cycling alone can't clear it):
  1. Start `node apps/robot/scripts/rescue.mjs 192.168.1.136 apps/robot/device/rocky_agent.py`
     FIRST, then power the board on — it hammers the OTA port to win the race against the bad
     payload's first tick (`check_for_push()` runs before each tick, so a connection already in
     the backlog replaces the payload before the bad boot path executes). Roughly a coin flip
     per boot; power cycle again and let it keep hammering if the first try misses.
  2. Guaranteed fallback if the race can't be won: upload `steps/step18_delete_payload.py` via
     mBlock over USB (deletes `/flash/rocky_payload.py`), press Home, re-upload
     `device/bootstrap.py`, then a normal `push.mjs` delivers the fixed agent.
- [x] Auto-connect (not just auto-fill) the moment discovery finds the robot, so the only manual
  step left is tapping "Start Listening" — untested pending the beacon issue above.
- [x] **Add real OpenAI Realtime voice to `apps/ios`, replacing the fixed command-word vocabulary
  entirely.** Checked first, not assumed: GPT-Live (what was originally asked for) is confirmed
  not API-accessible yet — launched July 2026 as ChatGPT-only, OpenAI's own page says "bring it
  to the API soon." Built on `gpt-realtime-2.1` instead (already what desktop Rocky uses, itself
  the latest Realtime release); swapping to GPT-Live later is a config change, not a rearchitecture,
  once OpenAI ships it. Also checked OpenAI's current docs directly for transport choice: WebRTC
  (not WebSocket) is what OpenAI itself says is for "browser and mobile clients that capture or
  play audio directly," so the iOS app connects straight to `/v1/realtime/calls`, no relay
  server, mirroring `apps/desktop`'s own `RTCPeerConnection` flow — via `stasel/WebRTC` (the
  standard community SPM package; Google retired official iOS binary distribution in 2020).
  `services/device-api/src/session.ts` gained the real tool surface (`drive_cm`, `rotate_degrees`,
  `stop_robot`, `read_distance`, `set_face`) replacing the empty Stage-2 placeholder, and the
  persona addendum now describes an iPhone-mounted body that can actually move. Deleted
  `VoiceCommandRecognizer.swift` entirely rather than keeping both paths — replacement, not an
  option toggle. **Verified for real**: 77 device-api + 25 robot SDK + 11 iOS tests all pass;
  installed and launched on the physical iPhone; ran `device-api` live and confirmed a full round
  trip — minted a real ephemeral secret, session config carries all five tools and the persona
  correctly.
- [ ] **Actually have a live voice conversation with the robot** — the WebRTC/tool-calling path is
  built and the ephemeral-secret mint is confirmed working, but no one has actually talked to it
  yet. First real test: connect to the robot, enter the laptop's `device-api` host/token in the
  app (shown once in this session's chat log, stored in `.env`, never committed), tap "Talk to
  Rocky," and see whether a tool call actually reaches the robot end to end.
- [ ] Add Python lint/type-check infra (`uv` + `ruff` + `basedpyright`, `pyproject.toml` +
  `typings/`): done and verified — ruff found and fixed 2 real bugs project-wide (an unused
  import, an SCons global false-positive), and permissive stubs cleared basedpyright's false
  `cyberpi.display` attribute error in Zed. Not yet done: wire `uv run ruff`/`basedpyright` into
  `pnpm check`, and add `pytest` coverage for `rocky_agent.py`'s pure helpers (needs a
  `if __name__ == "__main__":` guard first so the module is importable without hitting hardware).
- [ ] Confirm whether `mbot2.straight()`/`turn()` actually block the interpreter, which decides
  whether the `drive_speed`-based interruptible loop is necessary.
- [ ] Calibrate drive_speed RPM-to-cm/s and deg/s, and the em1/em2-to-wheel sign convention.
  Partial real data: `drive_speed(+RPM, -RPM)` confirmed to drive forward (found incidentally
  during the loudness-driving experiment below), cm/s and deg/s still unmeasured.
- [ ] **Voice-volume-controlled driving: fresh pass built, needs its hardware run.** Seven
  live-iterated versions (`apps/robot/steps/step05` through `step11_loudness_drive_tuned.py`)
  all fell short — history and root causes in
  `apps/robot/docs/loudness-drive-problem-statement.md`. The tooling that doc asked for now
  exists (same doc, "The fresh pass, built" section): a telemetry logger
  (`apps/robot/scripts/telemetry.mjs`), a guided calibration payload
  (`steps/step12_loudness_calibration.py`), an analyzer that emits measured constants
  (`scripts/analyze-calibration.mjs`), and the v8 drive payload that consumes them
  (`steps/step13_loudness_drive_calibrated.py`). Remaining: one ~45s calibration session with
  the robot and a person, paste the constants, and iterate on logged numbers.
- [ ] Rotate-and-ping ultrasonic scan against a real room; stitch 2-3 scans into one occupancy
  grid using odometry + `cyberpi.get_yaw()`; check real-world drift.
- [x] Build the sensor qualification gate before trusting that mapping design. The disposable
  `apps/robot/steps/step19_navigation_sensor_qualification.py` payload and
  `pnpm robot:qualify` recorder capture raw 20 Hz yaw/range telemetry beside tape/protractor ground
  truth, with only explicit <=500 ms, <=60 RPM motion pulses and local stop-on-disconnect/obstacle.
  `pnpm robot:qualify:analyze` reports distributions without turning one good demo into a pass.
  The procedure and predeclared acceptance gates live in `apps/robot/STEPS.md` step 18. Deliberate
  terminology correction: stock CyberOS exposes encoder-regulated `drive_speed`, but no published
  readable wheel-position primitive, so this measures actual pulse repeatability rather than
  inventing “wheel deltas.”
- [ ] Run that qualification matrix on the physical robot with the iPhone mounted. Use the result
  to decide each sensor's narrow role independently: short-turn correction, short-displacement
  estimate, forward obstacle veto, or no navigation role. Do not begin occupancy-grid work merely
  because one sensor passes a different role's gate.
- [ ] Keep the navigation coordinator and its tools independent of the selected conversational
  engine. Flag the engine decision when progress/recovery events are wired: GPT Realtime + the
  separate ER vision lane can receive sideband context without sharing ER's turn latency, while
  direct ER2 voice has no parallel sideband response lane and must never hold a conversational
  tool call open for a multi-minute route.
- [ ] Verify the obstacle-avoidance reflex stops a commanded drive locally, without waiting on the
  laptop, when something is placed in the ultrasonic's path mid-motion.
- [ ] iPhone-side frontier navigation against the occupancy grid.
- [x] **Camera semantic layer, brought forward ahead of the physical mount (2026-08-21):
  person-presence and bearing, standalone on the phone, not yet wired to the robot.**
  `apps/ios/Rocky/Sources/PersonCamera.swift` reads the **front** camera (the side the screen's
  face is on) as a continuous `AVCaptureVideoDataOutput` stream, throttled in software to ~1fps;
  `PersonVision.swift` sends each sampled frame to Gemini Robotics-ER
  (`gemini-robotics-er-2-streaming-preview`, over Gemini's Live API WebSocket -- the model only
  exists in streaming form, so the session stays open for the camera's whole run rather than
  reconnecting per frame) for person/bearing judgment — a second model and provider from the
  OpenAI Realtime voice session, deliberately, so a slow vision call can never stall the one
  session that has to keep talking. Records nothing — each frame is judged and discarded, no video
  file, no photo-library write. `apps/robot/PLAN.md`'s camera section and `apps/ios/README.md` are
  updated with the design and the reasoning for the second-model choice. Verified live against the
  real Gemini API (not just docs): the actual reply arrives as `serverContent.outputTranscription
  .text`, not `modelTurn.parts[].text` as the reference docs describe, wrapped in a markdown code
  fence despite the prompt asking for bare JSON — both handled and covered by
  `PersonVisionTests.swift`. Deployed and confirmed working on a real iPhone, including the
  true-positive path (an actual person in frame). Not yet tagged onto the occupancy grid or
  turning the robot to face someone — that's still real work, blocked on the physical mount
  (Phase 6) and occupancy grid (Phases 3-4) below.
- [x] **Made the camera fluid and automatic, by request (2026-08-21).** Two changes:
  capture switched from a discrete `AVCapturePhotoOutput.capturePhoto()` per tick (real shutter
  latency, ~2.5s cadence) to the continuous video stream above, throttled to Gemini's documented
  ≤1fps ceiling instead of paced by a slow capture call — the bearing marker now tracks like video
  rather than a slideshow. And the camera's on/off moved from a manual Start/Stop the person had
  to remember to visit, to following the voice conversation's own lifecycle: on the instant a
  conversation connects (including resuming from pause), off the instant it pauses, ends, or
  fails (`ContentView.swift`'s `handleVoiceStateChangeForCamera`). This deliberately reverses the
  "explicit, visible on/off" privacy line from the original camera plan — the person asked for
  automatic over asked-every-time. What's kept: still never on for a merely-open app, only for a
  conversation the person themselves just started; still records nothing; and the camera panel's
  Stop button remains a within-conversation manual override.
- [x] **Found and fixed a real bug from the first live device test: Rocky could not actually use
  the camera.** Asked in conversation, she answered honestly — "I cannot see it yet. No picture
  came through" — because `PersonCamera`'s detections only ever reached the debug panel; nothing
  told the OpenAI Realtime session anything. Fixed with
  `RealtimeVoiceSession.updatePersonDetection`: `ContentView` forwards every detection change to
  it, and on an actual presence change (not every ~1s sample) it inserts a quiet
  `<vision>...</vision>` conversation item via the same `insertWorldItem` door `WorldProjector`
  uses for body facts — no response requested, just context available for whenever Rocky next has
  something to say. Deliberately kept outside `WorldStore`: vision is a fact about the person in
  front of the camera, not the robot's own body, and doesn't belong in salience machinery built
  for that sense. Also found in the same pass: nothing about the camera's operation was ever
  written to `RockyLog`/`session.log`, the exact file `pull-log.sh` exists to make "it didn't
  work" diagnosable after the fact — added start/stop/error/presence-change logging to
  `PersonCamera.swift` so a future silent failure is actually visible in the pulled log instead of
  invisible the way this one was.
- [x] **Found and fixed the actual cause: still "no eyes" after the fix above, and the newly-added
  logging is exactly what found it (2026-08-21).** With logging in place, the pulled log showed the
  detection firing and the `<vision>` item being built correctly, immediately followed by
  `realtime error: Invalid 'item.id': string too long. Expected a string with maximum length 32,
  but got a string with length 39 instead.` OpenAI's Realtime API rejects any conversation item id
  over 32 characters, and `"vision_" + UUID` (39 chars) was one — the vision context was being
  silently dropped by the server every time. Found the same defect already live in
  `suspendActivePerformance`'s `"performance_paused_" + UUID` (52 chars), meaning an interrupted
  performance's resume context has likely been silently dropped this whole time too. Fixed both
  with one helper, `RealtimeVoiceSession.shortItemId(_:)`, that keeps a generated id under the
  limit by construction rather than trusting each call site's arithmetic; covered by
  `testGeneratedItemIdsNeverExceedTheRealtimeAPIsLimit`.
- [x] **Debounced vision announcements after a live false-negative (2026-08-21).** With the id-length
  fix in, a real session showed a genuine failure mode instead: one Gemini turn timed out under
  network contention (three simultaneous sessions — OpenAI Realtime WebRTC, Hume speech, Gemini
  vision — sharing one phone's Wi-Fi), and the very next frame's single noisy read of "no person"
  got told to Rocky as fact immediately, who then correctly but wrongly said the friend had left.
  `RealtimeVoiceSession.updatePersonDetection` now requires the same presence verdict twice in a
  row (`personPresenceConfirmations = 2`) before announcing a change, trading roughly one extra
  sample interval (~1s) of latency for not flip-flopping on a single bad frame. Not unit-tested:
  the guard sits behind `canReachVoice`, which needs a live data channel this class doesn't mock
  elsewhere either — verified live instead.
- [x] **Added a periodic vision refresh after a live stale-description bug (2026-08-21).** With the
  debounce fix in, a real session showed presence never toggling back to false across a whole
  conversation — because someone stayed continuously in frame — so the one-time
  presence-changed announcement never fired again: the camera panel's live description had moved
  on to "child with striped shirt," but Rocky kept confidently describing "person with glasses"
  minutes later, because that was the only `<vision>` item she'd ever been given. Fixed by
  refreshing on a 10s timer (`visionRefreshInterval`) while someone remains present, not only on
  the true/false edge — worded as "an updated look," not a fresh arrival, so it doesn't read as a
  second person showing up.
- [x] **Rocky can see things, not just people, and can look on demand (2026-08-23).** A friend held
  a can of coconut water up to the camera and asked about it; the camera panel read "man holding
  coconut water" and Rocky still missed it entirely. Three separate causes, all fixed together:
  - **She was never told about objects at all.** `PersonVision` asked Gemini one question — is a
    person present — and threw away everything else, so `person_present: true` was the whole truth
    available. Its prompt now describes the entire frame (`SceneReading.scene`: what people are
    holding, wearing, showing, plus objects and readable text, named specifically — "a can of
    coconut water", not "a drink"), and `scene` survives a `person_present: false` reading, because
    an empty room and an empty room with a drawing held up in it are different facts.
  - **Nothing fired.** The passive `<vision>` stream only announced on the person-present edge and
    a 10s timer. The friend never left frame, so presence never flipped and nothing was said. A
    materially different scene now announces itself too — rate-limited (`sceneChangeMinInterval`,
    4s) rather than debounced, since holding something up shouldn't wait two frames. "Materially"
    can't be a string comparison, since Gemini rephrases itself every frame, so
    `RealtimeVoiceSession.sceneChanged` compares significant-word overlap; unit-tested in
    `VisionContextTests` against both a real object appearing and pure rewording.
  - **Sight is always slightly in the past.** Frames are sampled at ~1fps and take another beat to
    judge, so at the instant any question lands, the newest look predates it. New `look_now` tool
    (this repo's first tool that is the *phone's*, not the board's) blocks the answer until a frame
    captured **after** the question comes back, up to 3.5s, then falls back to the newest look and
    says how old it is so Rocky can speak it as old. Needed three supporting changes: it must skip
    the body guard, it must survive `withoutRobotBody` (`phoneToolNames` — losing the body must not
    blind a phone whose camera is wide open), and it needs its own follow-up prompt, because the
    normal one exists to keep movement silent ("produce no additional words") and would have
    suppressed the answer.
  Also found: `<vision>` had **no prompt rule at all** — it was reaching Rocky as unexplained text
  with nothing saying not to read it aloud. There is now a `YOUR EYES` section covering the tag,
  the lag, when to call `look_now`, and saying plainly when she cannot see rather than inventing.
- [x] **Made this flow debuggable, since all three causes above were invisible in the log
  (2026-08-23).** Camera logging deliberately fired only on presence change — the exact definition
  under which this bug produced no lines at all. Now: every reading logs seq, round-trip ms,
  presence, bearing and scene; `PersonVision` logs Gemini's verbatim reply with timing, plus setup,
  reconnects, timeouts and a distinct line for a reply that parsed to nothing; suppressed
  announcements say *which* gate held them (unconfirmed flip vs. scene steady vs. too soon), since
  "nothing changed" and "changed but rate-limited" look identical from outside and want opposite
  fixes; and `look_now` logs the wait, what came back, and any fallback.
- [x] **Closed the five reliability gaps found in the vision-flow review (2026-08-27).** `look_now`
  now requests the first camera frame captured after the tool call and judges it on a separate,
  pre-warmed Gemini Live lane, so it never waits behind the passive frame already in flight.
  Gemini timeouts and send failures retire the entire socket epoch before another turn can use it;
  this also fixed an older watchdog bug that could reset a healthy idle session eight seconds
  after a successful turn. Invalid/missing presence JSON is now no observation rather than false
  evidence that the room is empty. Passive `<vision>` items carry `seq` and measured `age_ms`, with
  a prompt-level highest-sequence-wins rule. Scene comparison now canonicalizes common rewordings,
  compares against the shorter description, and separately detects changed colors and
  held/shown/worn details. Logging correlates passive/look lane, socket epoch, request generation,
  capture timestamp, JPEG size, judgment latency, freshness/fallback, invalid replies, and resets.
  The same pass removed the recurring “my body is unavailable/not connected” voice leak: missing
  robot hardware is now described privately as Rocky's own wheels/touch going numb, sight stays a
  normal first-person sense, and both tool failures and projected link events use that vocabulary.
  A follow-up live-language fix also makes the sequencing wrapper explicitly unspeakable and words
  its contents as direct first-person perception, preventing “sight notes” or “vision updates” from
  leaking into Rocky's conversation. Phone logs then showed a second problem: passive scene changes
  arrived every few seconds and the explicit-look follow-up invited a room tour plus an invented
  “vibe.” Passive scene pushes are now spaced at least 30s apart with a 60s steady refresh, while
  both the system prompt and tool continuation make sight ambient evidence used only when the
  person's actual question needs it.
  Verified with 96 device-api tests and 136 iOS simulator tests, plus successful physical iPhone
  build, install, and launch. The next live session should measure the real `look_now` p50/p95
  rather than tune its 3.5s budget from estimates.
- [x] **Show the active selfie camera without turning the main screen into a debug panel
  (2026-08-27).** While Rocky's eyes are open, the conversation view now carries a small rounded
  FaceTime-style preview in the top-right. It is image-only, noninteractive, and disappears with
  the camera; detection text and camera controls remain in the existing diagnostics sheet.

## Knowing friends: private face + voice identity (apps/ios)

**Outcome:** Rocky can recognize an explicitly enrolled friend, attach that identity to the live
conversation and the right private memories, remain plainly uncertain about everyone else, and
recover the encrypted profiles after an app reinstall. This is friendly open-set recognition, not
authentication: no safety, access-control, or purchasing decision may depend on it.

This section is the source of truth for the work. Keep each milestone as one checkbox until its
acceptance gate is met; add dated findings and notable design changes beneath the relevant item,
including real-device evidence. Implementation details belong beside the iOS code, but a decision
that changes privacy, stored data, model compatibility, or product behavior is recorded here.

Decisions already made:

- Recognition inference runs on the iPhone. Gemini continues to describe scenes but never stores,
  enrolls, or names a face; OpenAI/Gemini/voice providers receive no identity embeddings.
- Enrollment is explicit and reversible. Persist chosen names, several face/voice embeddings,
  quality/calibration metadata, and exact model versions; never persist enrollment photos, video,
  or raw audio. Treat embeddings as sensitive biometric data even though they are not source media.
- `unknown` is a successful result. A name needs multi-sample agreement and separation from the
  runner-up, and conflicting face/voice evidence returns to unknown rather than choosing a side.
- Face is the first and primary signal. Voice is later supporting evidence for poor light, a turned
  head, or someone outside the frame; it must consume a copy of PCM from `RockyRTCAudioDevice`'s
  existing VoiceProcessingIO graph, never start a competing audio engine or block its callback.
- Local profiles use iOS file protection. Optional recovery stores only an encrypted, versioned
  identity vault in the user's private CloudKit database, plus a user-controlled encrypted export
  for a no-iCloud path. Recognition still runs locally. Reinstall restore is a designed flow, not
  an assumption that the app container or Keychain happened to survive deletion.

- [ ] **Prove one face-embedding model in isolation.** Check published source, weights provenance,
  training-data and redistribution terms before conversion; reject a technically good model whose
  weights cannot responsibly ship. Build a disposable Core ML probe that accepts already-cropped
  fixtures and reports embedding distance plus inference timing without touching `PersonCamera`.
  Gate: deterministic output, tests for preprocessing/distance, useful same-person vs different-
  person separation on representative private fixtures, and acceptable p50/p95 latency on the
  actual mounted iPhone. Record the model hash, input normalization, embedding size, compute units,
  license decision, measurements, and fixture policy here before integrating it.
- [ ] **Define the durable identity-vault contract before collecting anyone.** Add versioned
  `FriendProfile`, face-template, voice-template, and model-version types; an actor-isolated local
  store; complete file protection; atomic writes; delete/export/import; and migrations that refuse
  incompatible embeddings rather than silently comparing them. Raw media must be impossible to
  represent in the persisted schema. Gate: unit tests cover round-trip, corruption, atomic
  replacement, deletion, old/new schema handling, and incompatible model versions.
- [ ] **Add local face detection, alignment, quality gating, and open-set matching.** Reuse the
  continuous front-camera buffers, with Apple Vision doing face boxes/landmarks locally and the
  proven Core ML model seeing only aligned crops. Run independently of the existing ~1fps Gemini
  scene lane, throttle for heat rather than queueing frames, track multiple faces separately, and
  publish observations without names until temporal consensus is stable. Gate: a ten-minute live
  voice+camera run has no added network traffic, frame backlog, thermal runaway, or voice latency
  regression; dim light, profile pose, occlusion, two people, leaving/re-entering, and an unknown
  person all produce honest measured outcomes.
- [ ] **Build explicit friend enrollment and management UI.** “Let Rocky remember me” collects
  several quality-approved face angles under visible camera use, shows what will be stored, asks
  the person to confirm their name, and commits only at the end. A Friends screen lists, renames,
  retrains, exports, and completely deletes profiles. Gate: cancelling at every step leaves no
  profile or temporary media; enrollment cannot silently absorb a bystander; VoiceOver and camera-
  permission failure paths work; deletion is verified on disk.
- [ ] **Project stable identity into conversation and memory without making it a greeting alarm.**
  Add one identity resolver and one quiet, sequence-aware context path beside vision. Tell the live
  session only on a stable transition or bounded refresh, scope retrieved private memory by opaque
  profile id, and keep names out of routine telemetry. Rocky may use a known relationship naturally
  but does not announce recognition on every arrival. A spoken correction requests confirmation
  before changing a profile and never trains automatically from its own guess. Gate: deterministic
  tests cover arrival, departure, unknown, stale/out-of-order results, two people, correction, and
  session reconnect; live tests include false-match attempts and log review.
- [ ] **Make reinstall recovery real.** Sync the versioned encrypted vault through encrypted fields
  in the user's private CloudKit database only after explicit opt-in, and offer a recovery-phrase-
  protected export/import path that does not require iCloud. On a clean install, offer restore,
  validate integrity and model compatibility before activation, merge by stable profile id, and
  make cloud deletion/status visible. Gate: delete the app from a real iPhone, reinstall it, restore
  profiles, recognize the enrolled people, then delete the recovered vault locally and remotely;
  also test offline/no-iCloud, wrong recovery phrase, corrupt backup, keychain reset, and downgrade.
- [ ] **Prove speaker embeddings without disturbing conversation audio.** Audit and convert a
  compact speaker-verification model, then feed a timestamped bounded PCM ring buffer from the
  existing echo-cancelled capture path. Inference runs off the real-time thread on sufficiently
  long, single-speaker utterances delimited by the existing VAD events; short/noisy/overlapping
  audio yields no identity. Gate: callback work is bounded and allocation-free, Rocky never matches
  her own playback, a sustained live conversation shows no audio starvation or barge-in regression,
  and representative household/impostor trials establish thresholds rather than borrowing them.
- [ ] **Fuse face and voice conservatively, then decide whether adaptive enrollment is warranted.**
  Accumulate calibrated evidence per tracked person: agreeing signals strengthen a result; conflict,
  overlap, ambiguity, or insufficient margin returns unknown. Do not continuously update templates
  in the first release. Gate: a written device-test matrix reports false accepts/rejects by signal,
  lighting, distance, noise, duration, and multiple-person condition; no name is exposed from one
  marginal sample; profile poisoning attempts fail. Consider confirmed high-confidence adaptation
  only after drift and rollback can be measured.

- [ ] Find/follow: combine occupancy-grid navigation with person bearing to approach and hold a
    comfortable distance. The bearing this needs is unchanged; `SceneReading` keeps it.
- [ ] North-star run: navigate, find a person, approach, and hand off to the iOS app's own Realtime
  voice conversation, without crashing. Run repeatedly; tune thresholds against what actually
  happens on hardware, not what was assumed in the plan.

## Behaviour + voice collaboration (a thin slice of all four phases now exists)

`apps/robot/device/rocky_agent.py` is step16's autonomous loop plus an observation/intention
layer. Its tuning is byte-identical to `steps/step16_loudness_drive_sticky.py`, which stays as the
tuning record and the rollback; `pnpm robot:check` fails if they drift.

The shape, and why: the motion loop decides at ~20Hz with reactions lasting 0.3-4s, while the
voice character cannot speak in under ~2s. So state travels as *recent history* ("4s ago something
loud startled me") and control travels as Rocky's own *intentions*, never as human remote control.
Once chosen, every physical expression takes over its automatic counterpart immediately. Stop is
the one human imperative.

- [x] Built, then removed, a personality selector on iOS: a main-screen pill that let a person
  create and tune custom AI-generated characters (literary-quote-driven trait sliders, a
  GPT-5.6 Sol compiler synthesizing a name/essence/voice-design seed, ElevenLabs voices) alongside
  the fixed Rocky. Reverted 2026-08-21 back to Rocky as the only personality — no selector UI, no
  custom-character generation or storage, no ElevenLabs. `services/device-api`'s `CHARACTERS`
  registry (currently `[ROCKY]`) and session builder are unaffected; they were always the shared
  infrastructure behind both the selector and the robot's own live session.
- [x] A: observation. Ring buffer on `_enter` (the single transition choke point), TCP event
  stream on 8768, UDP beacon under a different service name so the motion-agent discovery ignores
  it.
- [x] B: awake moods as multipliers over the tuned constants at their point of use, never rewriting
  them. `still` is a hard interlock above the state handlers: the board boots still, reasserts zero
  motor speed every tick and suppresses loudness/floor/proximity reflexes. Rocky's own deliberate
  movement and light choices can still express themselves without waking those reflexes.
- [x] Finish the disposition lifecycle: rename ambiguous `normal` to `exploring` end-to-end, let
  temporary `excitable` decay to `calm` after 45 seconds, and execute payload module-level code
  under hardware stubs in `robot:check` so a boot-killing definition-order error cannot ship.
- [x] C: correlated gestures and mixed 2–8 move routines. Every newly chosen sequence now
  preempts autonomous motion with its first beat immediately; only later repeats/routine steps
  stay queued between bounded beats. Each physical beat carries the caller id and step, so a late
  transition cannot be mistaken for a newer wish.
- [x] Fix story-with-movement and movement narration from the 2026-08-16 phone logs. Both tries
  became three assistant responses — an announcement plus spin, an announcement plus wiggle, then
  a tiny stage-direction story — because the model could only send one gesture at a time and every
  tool result prompted an unsteered continuation. The first gesture could also start late enough
  to be credited to the second action. `robot_routine` now submits the whole choreography once;
  tool follow-ups explicitly return to the shared topic; and the prompt treats ordinary body
  language/state as silent context instead of conversational material.
- [x] Replace duration guessing with ordered embodied performances. `robot_performance` returns the
  actual story as `say` steps interspersed with `move`, timed LED `light`, and locally synthesized
  8-bit-ish `sound` steps; iOS advances only when the preceding audio was heard. Laser blasts and
  spaceship flybys are first-class cues. Tool preambles are withheld from speech, so the
  story—not production narration—is what comes out of Rocky's mouth.
- [x] Give Rocky discretionary LED expression everywhere physical intent can appear. A standalone
  `robot_light` choice immediately overlays automatic state lighting for 0.2–10 seconds; the base
  color continues updating underneath and returns on expiry. Performances accept up to eight
  named-color cues that overlap the following speech/movement/effect. The shared persona treats
  color as occasional, silent emotional body language rather than a narrated codebook. Mood,
  light, gesture, routine, and story cues now all take effect immediately once Rocky chooses them.
- [x] Preserve interrupted performances. Pausing rewinds the current spoken/effect cue and holds
  the unheard steps; unpausing wakes the body and resumes them. A conversational interruption is
  projected privately and can later use `resume_robot_performance` without regenerating the story.
- [x] Restore voice interruption for Hume playback without a second capture device. The first
  muted-speech-listener attempt took capture ownership from WebRTC and made Rocky deaf. The final
  design injects one full-duplex `RTCAudioDevice`: WebRTC capture/playout, Hume, chords, and story
  effects share its VoiceProcessingIO mixer, so semantic VAD keeps receiving the real microphone
  while AEC has every sound Rocky makes as its reference. The live log then recorded four
  mid-response `speech_started` events; one stopped Hume playback 42ms later, with no ordinary
  self-trigger during the final uninterrupted reply. Keep the hardware full-duplex while ADM's
  transient record/play flags change, and never restart the graph merely after stopping an empty
  local player—the earlier churn produced 0Hz speaker formats and Core Audio `!pla` failures.
- [x] Tighten live story timing and expand physical storytelling. Movement cues now wait for the
  correlated board transition that says the wheels actually started (with a two-second anti-hang
  fallback), and the model authors explicit 100–4000ms pause beats after every move. Stories now
  default to embodied performances when the robot is present and can use forward, fast forward,
  backward, left, right, turn-around, spin, and wiggle beats.
- [x] Make a chosen directional move substantial and immediate. The 2026-08-16 live log showed
  two `backward` choices acknowledged in about 220ms but waiting 5.75s and 3.14s for autonomous
  exploration to yield; each then lasted only 450ms before forward motion reclaimed the motors.
  Single gestures now preempt the autonomous state in the observer pump, forward/backward last
  1.2s at 80 RPM, and tool follow-up cannot narrate waiting, momentum, or promised future motion.
- [x] Keep precautions out of Rocky's conversational identity. The constructed model prompt no
  longer contains `safe`, `safety`, or `unsafe`, stop is a silent two-word behavior rather than a
  theme, and directional story moves have no extra obstacle veto or special reverse-repeat cap.
  The explicitly requested boot/pause sensor-quiet `still` behavior remains.
- [x] Make voice pause a physical pause: iOS sends `still` before silencing voice, engaging the
  board's immediate motor stop and sensor interlock. Resume retains the deterministic
  `still → exploring` wake.
- [x] Let Rocky's will override Still without waking the reflexes. The latest live log proved that
  the board acknowledged every gesture in a story, then its next Still tick erased each one before
  the wheels started. Still now blocks sound/touch/proximity movement while allowing correlated
  Rocky gestures and routines to run; each chosen move returns to sensor-quiet Still afterward.
- [x] Repair malformed Realtime story-effect arguments locally. Two live dance stories put their
  final `chime` in the `move` field and omitted `sound` despite the strict function schema, causing
  iOS to reject the entire performance and Rocky to invent a “missing-data wormhole.” The decoder
  now normalizes that unambiguous slip, the schema descriptions reinforce the field distinction,
  and tool execution errors are written explicitly to the session log.
- [x] Remove support-assistant language from voice resume. The old one-off prompt supplied “back
  and listening” plus “left off,” which bled into Rocky asking what felt “off or confusing.” Resume
  now asks for one warm declarative continuation without retrying an interrupted greeting, asking
  a question, inviting a topic, describing readiness, or referring to the pause.
- [x] Remove operator/instruction framing exposed by the next live session. Rocky said “You guide,
  Rocky follows,” invited “just say the word,” and announced waking/movement before tool calls.
  Movement is now explicitly Rocky's autonomous alien body language; projected causes say “I chose
  to,” tools describe private choices rather than obedience, and follow-ups return to the shared
  relationship rather than a person's “request.” Safety stop remains immediate.
- [x] Wake the body deterministically when voice starts/resumes or finds a robot mid-session. The
  board still boots safely locked in `still`, but iOS—not an unreliable model tool choice—moves it
  to `exploring` before any conversational gesture. Other active moods are preserved.
- [x] Close the remaining capability-negotiation leak found in the same post-deploy log. An older
  “say you cannot steer” rule made Rocky contrast that with an offer of body language, then preview
  a routine. Movement now has no spoken negotiation or lead-in; spoken content must stand alone.
- [x] Fix the debug panel's stale “no robot found” race. A completed subnet sweep with an address
  is now shown as `found · connecting…`, not missing; the panel derives current status instead of
  preserving a one-shot line, and connected state always includes both behavior mode and mood.
- [x] Rebalance Rocky's verbal tics: “Understand.” is now an occasional beat instead of the default;
  signature connection phrases and rotating contextual easter eggs are encouraged more often, with
  spacing rules so one repeated habit is not simply replaced by another.
- [x] D: proactive narration of startle/bump, rate-limited and suppressed while already speaking.
- [x] **Test the slice on hardware.** Live iOS sessions have confirmed hello/snapshots, autonomous
  transitions, mood changes, gestures, the `still` boot interlock, and a complete four-beat mixed
  story routine on the real board.
- [ ] Measure tick rate before/after the observation layer. This loop's sampling *is* its pipeline
  (one `get_loudness()` per tick, no smoothing, startle is an edge trigger), so anything that slows
  the tick degrades startle detection without changing a single constant.
- [ ] Extend `SELF_NOISE` past 60 RPM with a fresh calibration run. It only covers 0-60, and
  `_sensed_level` correctly refuses to guess above that -- but every reaction state now runs above
  60 since `MAX_RPM` became 150, so escalate-while-moving is inert in most states today. This is
  the single highest-value missing measurement.
- [ ] Reseed the loudness floor on demand. It is seeded once at boot and never again; with a
  long-lived board the "re-push to reseed" escape hatch stops being acceptable. Only ever from
  `listening`, motors confirmed off, and only ever taking `min()` -- raising a floor from an
  unconfirmed-quiet sample is what caused the v6 regression.
- [x] **Settled: they never coexist, and there is only one agent now.** The commanded-motion
  payload is deprecated and frozen at `apps/robot/deprecated/motion_agent.py`; the autonomous loop
  is `apps/robot/device/rocky_agent.py` and is the only thing pushed. Two payloads that could never
  run at the same time, only one of which was being developed, cost a dual-port discovery sweep, a
  three-way body capability enum, a whole Swift client stack, five steering tools the live board
  cannot answer, and a standing "which one is on the board?" question before every deploy. Gone:
  `Robot.swift`, `RobotController.swift`, `RobotProtocol.swift`, `RobotTransport.swift`,
  `RobotDiscovery.swift`, `MotionWorldSource`, and the `drive_cm`/`rotate_degrees`/`read_distance`/
  `set_face`/`set_lights` tools. `apps/robot/src` (the TS SDK for that protocol) is marked
  deprecated in place rather than deleted -- it is the protocol's reference implementation and its
  tests are the wire-format record.
- [x] Found while collapsing them: the world model was promoting an accepted intention to
  `running`/`assumed` after 0.6s. That was right for the motion agent, which began immediately and
  never said so -- and exactly wrong for this board's correlated reporting. Rocky would have
  believed she was moving before the board said it began. Single gestures now begin immediately,
  but nothing is assumed to have started: the correlated transition remains the evidence.

## Embodiment: what voice knows about the robot (apps/ios/docs/embodiment.md)

Rocky now keeps an authoritative world model on the phone and projects a curated view of it into
the Realtime conversation, instead of the conversation being the only record of what her body did.
Design and scenario matrix are in [`apps/ios/docs/embodiment.md`](apps/ios/docs/embodiment.md);
the shape is WorldStore (what is true) → WorldProjector (what she is told) → SalienceJudge
(whether it is worth interrupting her for), with RealtimeVoiceSession as the only thing that talks
to OpenAI.

- [x] Realtime API mechanics verified against OpenAI's current docs rather than assumed. Three
  facts the design depends on: exactly one **in-band** response may exist at a time (a second
  `response.create` is rejected outright), out-of-band responses (`conversation: "none"`) may run
  concurrently and carry `metadata` echoed back on `response.created`, and conversation items can
  carry **client-assigned ids** and be deleted — which is what lets superseded state be removed
  from history rather than merely outranked.
- [x] Movement tool calls register an intent and return `{action_id, status: "accepted"}`. Fixed
  three faults that were all the same mistake — treating a physical act as a function call: voice
  went silent for the length of every movement; a drive longer than the flat 3s command timeout
  was reported to the model as a *failure* while the robot was still driving; and
  `{"success": true}` for an accepted command read as "I did it".
- [x] Action lifecycle with two axes: `status` (what we believe) and `evidence`
  (`confirmed`/`assumed`/`none` — why). `lost` is deliberately not `failed`: failure is something
  the body told us, lost is something we never found out, and they make different sentences true.
- [x] Two protocol additions carrying evidence the board already had but never sent. `started`
  (a drive/turn has begun, where `ack` only ever meant *finished*) and `pong` (a heartbeat reply,
  because an open TCP socket does not prove the interpreter is running on this hardware — see the
  board-freeze incident above, where the port answered SYN while nothing was ever serviced).
- [x] `rocky_agent.py` transitions carry their reason (`startled` → "loud noise" vs "came
  close", the obstacle turn vs the personality turn) and gestures echo the caller's own id, so a
  gesture's fate is correlated rather than inferred from timing. No tuned constant touched;
  `check-behavior-parity.mjs` still passes.
- [x] Salience in two tiers: deterministic rules fire instantly for safety and self-contradiction,
  and one *superseding* out-of-band judgment slot handles the ambiguous middle. Every judgment
  carries a ticket (`event_id`, `voice_response_id`, `world_seq`) and is discarded if it comes back
  referring to a response or a world that is no longer current.
- [x] Make audible playback, not Realtime text generation, define whether Rocky is mid-utterance.
  The 2026-08-16 log showed a startle 303ms after text generation ended but while roughly 14s of
  Hume speech remained; the surprise response queued behind it and “Whoa” arrived late. A salient
  reflex now stops local playback (while preserving a resumable story) before speaking, while a
  deliberately deferred body note is prompted as past memory and cannot use a fresh interjection.
- [x] The Body panel (one tap from the state chip) and `Documents/world.jsonl`, pulled by
  `apps/ios/scripts/pull-log.sh` alongside `session.log`. The Responses tab answers "what robot
  state did the model have available when this response began", written at `response.created`
  rather than reconstructed — by the time anyone asks, the superseded state is gone.
- [x] Robot discovery retries on app startup and every voice resume. Completed scans and failed
  connections are cleared so they cannot suppress later attempts; when the body returns, the live
  Realtime session regains its body instructions and tools through `session.update` without
  discarding the paused conversation.
- [x] OTA bootstrap ignores zero-byte connections. A read-only port probe during the 2026-08-16
  recovery exposed that `check_for_push()` previously wrote an empty `/flash/rocky_payload.py`;
  empty input now leaves the last known-good payload untouched.
- [ ] **Finish the real-hardware scenario matrix.** Startup discovery, hello/snapshots, body-state
  projection, mood changes, and single gestures are confirmed on the board. Still to verify: one
  mixed story routine with correlated steps, `pong`, and whether the out-of-band salience judgment
  returns before the sentence ends; if it consistently does not, drop that tier and widen the
  deterministic rules.
- [x] **The conversation is append-only; nothing is ever deleted from it.** Deleting superseded
  state snapshots was built, then taken out: prompt caching is exact-prefix, so removing an item
  the conversation has moved past invalidates the cache from its old position and re-charges full
  price for every audio token since — minutes of them, to remove eighty. The cache-aware version
  (delete only when free, defer otherwise, sweep in batches) worked but was three interacting
  mechanisms buying tidiness nobody looks at. Supersession travels by `seq` instead, which costs
  nothing: every snapshot is whole, so "highest seq wins" is a max and not a merge, and there is
  nothing for the model to accumulate either way. `VoiceChannel` has no removal method at all, so
  it is a property of the type rather than a discipline. Staleness is handled by *restating*
  before a response when the live snapshot has aged past 20s, not by removing anything.
- [ ] **Context summarisation**, once a long session's transcript actually gets uncomfortable.
  This is the right answer to growth, and the reason not to pay a cache miss for tidiness now.
  Worth measuring first: every response logs its cached share, so check whether Realtime's own
  context truncation is busting the prefix long before our appends matter.
- [ ] Tune the interruption cooldown (8s) and the projection coalescing window (700ms) against a
  real session rather than a guess. Both are first guesses in the same sense as every constant in
  `rocky_agent.py`, and both are the kind of thing that only reads wrong out loud.
- [ ] `VoiceMoment.claimsMotion` is a keyword match over the utterance so far. It decides whether a
  bump *contradicts* Rocky or merely happens near her, so it is load-bearing for the deterministic
  interrupt — worth revisiting once there are real transcripts to check it against.
- [ ] `audio_end_ms` for truncation is measured from `output_audio_buffer.started`, since WebRTC
  reports no exact playback position. Erring long deletes words she did say; erring short leaves a
  fragment she did not. Check against a real interruption whether the approximation is close
  enough to matter.
