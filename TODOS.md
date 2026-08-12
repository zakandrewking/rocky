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
  the existing `scripts/push.mjs`, no mBlock/USB needed. Command-handling logic itself is still
  queued for a live hardware run past `STEPS.md` step 5.
- [x] Scaffold `apps/ios`: a minimal SwiftUI app (XcodeGen-generated, since there's no way to
  drive Xcode's project GUI here) with on-device Speech-framework command words (forward/back/
  left/right/stop) over a Swift port of `apps/robot/src`'s protocol, and a Swift port of
  `push.mjs` for iPhone→CyberPi OTA. Verified for real: builds and passes all 11 unit tests on
  the iOS Simulator; a real build targeting a paired physical iPhone gets all the way to install,
  blocked only by the phone's Developer Mode toggle (one-time manual step, documented in
  `apps/ios/README.md`, not a build problem). Signing pinned to a specific personal Apple
  Developer team so this never lands on a work/org account's App Store Connect.
- [ ] Actually install and run `apps/ios` on a real iPhone (Developer Mode toggle is the only
  remaining blocker) and confirm command words drive the real robot end to end.
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
