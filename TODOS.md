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
- [ ] Camera semantic layer: detect a person, estimate bearing, turn to face them. The iPhone's
  own camera is the sensor for this (better than the laptop webcam the original design assumed)
  but still isn't on/near the robot until it's physically mounted — decide explicitly whether to
  bring that forward instead of waiting.
- [ ] Add an explicit, visible on/off for the camera layer and no persistent recording by default;
  a camera on a family device is a bigger privacy step than audio alone.
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
loud startled me") and control travels as *intentions* honoured at the loop's natural seams --
never as "what are you doing right now" and "do this now". Stop is the one real imperative.

- [x] A: observation. Ring buffer on `_enter` (the single transition choke point), TCP event
  stream on 8768, UDP beacon under a different service name so the motion-agent discovery ignores
  it.
- [x] B: awake moods as multipliers over the tuned constants at their point of use, never rewriting
  them. `still` is a hard interlock above the state handlers: the board boots still, reasserts zero
  motor speed every tick, suppresses loudness/floor/proximity reflexes and gestures, and only moves
  after Rocky wakes it by choosing an awake mood.
- [x] Finish the disposition lifecycle: rename ambiguous `normal` to `exploring` end-to-end, let
  temporary `excitable` decay to `calm` after 45 seconds, and execute payload module-level code
  under hardware stubs in `robot:check` so a boot-killing definition-order error cannot ship.
- [x] C: queued gestures (spin, wiggle) with a TTL, consumed only in `listening` so a reflex can
  never be interrupted by an intention. Mixed 2–8 move routines are one correlated action; each
  physical beat carries the caller id and step, so a late transition cannot be mistaken for a
  newer wish.
- [x] Fix story-with-movement and movement narration from the 2026-08-16 phone logs. Both tries
  became three assistant responses — an announcement plus spin, an announcement plus wiggle, then
  a tiny stage-direction story — because the model could only send one gesture at a time and every
  tool result prompted an unsteered continuation. The first gesture could also start late enough
  to be credited to the second action. `robot_routine` now submits the whole choreography once;
  tool follow-ups explicitly return to the person's request; and the prompt treats ordinary body
  language/state as silent context instead of conversational material.
- [x] D: proactive narration of startle/bump, rate-limited and suppressed while already speaking.
- [x] **Test the slice on hardware.** Live iOS sessions have confirmed hello/snapshots, autonomous
  transitions, mood changes, gestures, and the `still` boot interlock on the real board. The mixed
  routine added later still needs its own live story run.
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
  never said so -- and exactly wrong for this board, which deliberately waits for a safe seam and
  *tells you* when it starts. Rocky would have believed she was spinning during the one window the
  board was telling her she was not. Nothing is assumed to have started any more.

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
