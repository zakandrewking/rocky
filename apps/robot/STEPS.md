# apps/robot test order

> **Note (2026-08-16):** `device/rocky_agent.py` now means the *autonomous* agent — the one and
> only payload. What this document calls the motion agent (commanded drive/turn over TCP on 8765)
> is deprecated and frozen at [`deprecated/motion_agent.py`](deprecated/motion_agent.py). The
> history below is left as written; see [`README.md`](README.md) for what runs today.

Same discipline as [`apps/cyberpi/STEPS.md`](../cyberpi/STEPS.md): small, standalone, one thing
proven at a time. Hardware rows are marked only after a physical run; a blank result remains
pending rather than inheriting confidence from an adjacent test.

| # | What | Needs hardware? | Result |
| --- | --- | --- | --- |
| 1 | `protocol.ts` unit tests: command bounding, newline framing, message parsing | No | **PASS** — 12 tests |
| 2 | `robot.ts` unit tests against `MockTransport`: acks, timeouts, heartbeats, error replies, disconnect | No | **PASS** — 8 tests |
| 3 | `transport.ts` `TcpTransport` against a real local TCP server (loopback, no board) | No | **PASS** — 5 tests |
| 4 | **Gate:** upload a trivial standalone program to a real CyberPi and confirm a real TCP socket can be opened from it | Yes | **PASS**, both directions — `steps/step01_socket_gate.py` (inbound) and `steps/step01b_socket_gate_outbound.py` (outbound + inbound in one run). See "What actually happened" below |
| 4b | **OTA bootstrap:** upload `device/bootstrap.py` once via mBlock, confirm it loads a pushed payload (`steps/step02_ota_payload_v1.py`) via `apps/robot/scripts/push.mjs`, and that a second push reloads it live with no further mBlock/USB interaction | Yes | **PASS** — pushed three times total, counter reset and climbed again each time, including with the USB cable fully unplugged. Confirmed wireless, not just mBlock-free |
| 5 | `rocky_agent.py` accepts a TCP connection from a laptop running `TcpTransport`, and a `stop` command round-trips to an `ack` | Yes | |
| 6 | Heartbeat watchdog: start a slow drive, then kill the laptop-side connection mid-motion, confirm the agent stops on its own within one watchdog interval | Yes | |
| 7 | Confirm whether `mbot2.straight()`/`mbot2.turn()` block the interpreter until the maneuver finishes. Decides whether `rocky_agent.py`'s `drive_speed`-based interruptible loop is necessary, or whether the simpler blocking calls are safe after all | Yes | |
| 8 | Single motor sanity: `mbot2.drive_speed(em1, em2)`'s sign convention moves the correct physical wheel in the expected direction for each argument — settles the em1/em2-to-wheel mapping `rocky_agent.py` currently assumes | Yes | |
| 9 | Calibrate: measured cm/s and deg/s at a few `drive_speed` RPM values, over a few repeated runs, to size `rocky_agent.py`'s in-burst distance tracking (only needed because of the interruptible-loop design in step 7; moot if `straight`/`turn` turn out to be safe to use directly) | Yes | |
| 10 | Ultrasonic sanity: `Ultrasonic.get_distance()` against a tape-measured object at a few distances | Yes | |
| 11 | Rotate-and-ping scan: full 360° sweep at 15° increments against a real room; compare the resulting polar plot to the actual layout by eye | Yes | |
| 12 | Multi-position stitching: merge scans from 2-3 spots into one occupancy grid using odometry + gyro heading; check how far it's drifted from the real room | Yes | |
| 13 | Obstacle-avoidance reflex: place an object in the ultrasonic's path mid-drive, confirm the agent stops locally without waiting on the laptop | Yes | |
| 14 | Laptop-side frontier navigation: given the occupancy grid, drive toward the nearest open area without a person there to prompt it | Yes | |
| 15 | Camera: detect a person in a webcam frame and estimate bearing; verify the robot turns to face them (needs the camera on/near the robot — see `PLAN.md`'s Phase 6 note) | Yes | |
| 16 | Find/follow: combine 14+15 — approach a person and hold a set distance as they move a little | Yes | |
| 17 | **North-star run**: navigate, find a person, approach, and hand off to the existing desktop Rocky voice conversation, without crashing, run repeatedly | Yes | |
| 18 | **Navigation sensor qualification:** run `step19_navigation_sensor_qualification.py` with the phone mounted; measure stationary yaw drift, yaw delta against physical turns, repeatability of short `drive_speed` pulses against tape-measured displacement, and ultrasonic behavior against broad/narrow/soft/angled targets | Yes | Harness built; hardware run pending |

## What "gate" means here (step 4)

If stock CyberOS turns out not to have `socket` in an uploaded program, everything from step 5
onward in this list needs a different transport or a different firmware entirely — most likely
porting the motion agent onto `apps/cyberpi`'s existing native ESP-IDF firmware and OTA plumbing,
since that's already proven to have real networking. That's a real fork in the road, not a detail;
see `PLAN.md`'s answer to "can we do OTA?" for the reasoning. Don't build steps 5+ against an
assumption this step hasn't checked yet.

## What actually happened running step 4 (2026-08-08)

Sockets work in both directions — the gate passes cleanly. Getting there surfaced two real,
board-specific findings worth keeping:

- **`network.WLAN(network.STA_IF).ifconfig()` does not reflect the board's real connection
  state on this firmware.** It returned `"0.0.0.0"` even after a 10-second retry loop, on a run
  where the board's networking was later confirmed fully working (outbound connect succeeded).
  `cyberpi.wifi.is_connect()` apparently tracks a real, working connection internally that this
  standard-MicroPython API just doesn't expose correctly here. Don't rely on it for IP discovery;
  a real device would need to display its address some other way, or a discovery mechanism that
  doesn't depend on the board self-reporting.
- **A stuck upload required a power cycle.** Every step here ends in an unbounded `while True`
  loop, and mBlock's upload protocol needs to interrupt whatever's currently running before it can
  write a new program. Uploading directly on top of a still-running loop produced a stuck transfer
  (mBlock's REPL prep commands succeeded, then the file write stalled indefinitely — confirmed by
  decoding the raw serial trace). Fixed by pressing the board's Home button before every re-upload,
  not by anything in the code; see the note above "Running a step."

Once the board was in a good state (post power-cycle), both directions worked without further
issues: outbound connect-and-send succeeded twice in a row, and one inbound accept-and-reply
succeeded, confirmed from the laptop side both by a targeted port scan finding the board's real
address and by watching the expected message arrive on a listening socket.

## What actually happened running step 4b (2026-08-08)

Passed cleanly, no surprises this time — `device/bootstrap.py` was uploaded once via mBlock
(pressing Home first, per the step-4 lesson above), came up showing `Ready. Push :8766`, and
`scripts/push.mjs` against the board's address (found the same way as step 4, a port scan) wrote
and reloaded `step02_ota_payload_v1.py` three times in a row — each push's on-screen counter reset
to 1 and climbed again. The third push was with the USB cable physically disconnected, confirming
this is genuinely wireless iteration, not merely mBlock-free. `PLAN.md`'s OTA answer is updated
accordingly: scripted push-based iteration is real on stock CyberOS, not just mBlock's manual
Wi-Fi upload mode.

## Running a step

Same mechanics as `apps/cyberpi`: mBlock 5, Python editor, mode set to **Upload** (not Live).
`rocky_agent.py` is a single self-contained file, same reason as the cyberpi steps — mBlock
uploads one program at a time.

**Press the Home button on the board before every re-upload.** Every step here ends in an
unbounded `while True` loop (a socket server has to keep running) with no code path back to
CyberOS's own "ready for a new program" state — only a hard reset or a Home-button exit does that.
Uploading directly on top of a still-running loop produced a real stuck upload once (mBlock's REPL
commands succeeded, then the file write stalled indefinitely, needing a power cycle to recover —
see the git history around 2026-08-08 for the decoded serial trace). Pressing Home first, per
[`apps/cyberpi/docs/first-upload.md`](../cyberpi/docs/first-upload.md#getting-your-board-back-to-normal),
avoids it.

## Step 18: earn each sensor's role

This is intentionally before occupancy-grid or route-planning work. The published component specs
are permission to measure, not evidence that the assembled robot localizes. The harness also does
not claim wheel deltas: no readable encoder-position primitive is published in the stock CyberOS
`mbot2` API. It measures the repeatability of actual chassis movement produced by short
encoder-regulated `drive_speed` pulses instead.

Push the disposable payload and start the guided recorder:

```bash
pnpm robot:push <board-ip> apps/robot/steps/step19_navigation_sensor_qualification.py
pnpm robot:qualify <board-ip>
pnpm robot:qualify:analyze local-data/robot-navigation-qualification/<run>.jsonl
```

Run with the actual iPhone mount and normal battery load. Capture at minimum:

- stationary yaw runs of 60 seconds, 5 minutes, and 10 minutes, repeated after a power cycle;
- 20 physical turns in each direction, including 45°, 90°, and 180°, measured independently;
- 20 identical drive pulses on hard floor and 20 on carpet, then repeat at another battery level;
- ultrasonic samples at 10, 20, 35, 50, 100, and 200 cm against a perpendicular wall, chair leg,
  fabric, and a 45° surface, plus no-target readings;
- dynamic approaches at every speed autonomy might use. A person remains beside the robot with a
  physical stop path during these trials.

Provisional gates, chosen before seeing the data:

- **Yaw may correct one short turn** only if physical-turn absolute error has p95 <=10°, no outlier
  exceeds 20°, and stationary drift stays below 2°/minute. It never becomes global heading; vision
  must re-anchor between route legs.
- **Timed encoder-regulated motion may estimate one short displacement** only if identical-pulse
  coefficient of variation is <=15% per surface/load and no pulse produces zero or reversed
  movement. It never becomes accumulated house-scale position.
- **Ultrasonic may veto forward motion** only if it has zero missed detections inside the chosen
  stopping envelope across the adversarial target set. False positives cost progress; a false
  negative costs the safety role. Even a pass does not promote it to map geometry.

Failing a gate is a useful result: remove that observation from the navigator rather than tuning a
model until the failure is hidden.
