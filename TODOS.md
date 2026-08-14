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
- [ ] IP discovery beacon (`rocky_agent.py`'s `_beacon_discovery`, `RobotDiscovery.swift`) still
  unconfirmed — a UDP broadcast sent from the board never arrived at a listener on the laptop
  across several checks. Made more robust without live confirmation (robot was powered off):
  sends to both the limited (255.255.255.255) and computed subnet-directed broadcast address, and
  shows the board's own detected IP directly on screen as a fallback either way. Needs a live
  check next time the robot's on — read the beacon counter/IP off the screen.
- [x] Auto-connect (not just auto-fill) the moment discovery finds the robot, so the only manual
  step left is tapping "Start Listening" — untested pending the beacon issue above.
- [ ] Add real OpenAI Realtime voice to `apps/ios`, replacing the fixed command-word vocabulary,
  reusing `services/device-api`'s ephemeral-secret pattern and desktop Rocky's persona.
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
