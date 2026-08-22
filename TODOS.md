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
- [ ] Find/follow: combine occupancy-grid navigation with person bearing to approach and hold a
    comfortable distance.
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
