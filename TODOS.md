# Rocky TODOs

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
- [x] **Run `apps/robot/STEPS.md`'s hardware gate**: confirmed on real hardware — sockets work in
  both directions (board-as-client and board-as-server), no fallback to `apps/cyberpi`'s native
  firmware needed. Two real findings along the way: `network.WLAN(network.STA_IF).ifconfig()`
  never reports a real address on this firmware even when the connection is genuinely working
  (don't use it for IP discovery), and uploading a new program while a previous one's unbounded
  loop is still running can stall the transfer indefinitely — press the board's Home button before
  every re-upload. Both documented in `apps/robot/STEPS.md`.
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
