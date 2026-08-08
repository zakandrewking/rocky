# apps/robot test order

Same discipline as [`apps/cyberpi/STEPS.md`](../cyberpi/STEPS.md): small, standalone, one thing
proven at a time. This project has no board attached in the environment these steps were written
in, so 1-3 are the only ones actually run so far. Fill in the Result column as the rest happen.

| # | What | Needs hardware? | Result |
| --- | --- | --- | --- |
| 1 | `protocol.ts` unit tests: command bounding, newline framing, message parsing | No | **PASS** — 12 tests |
| 2 | `robot.ts` unit tests against `MockTransport`: acks, timeouts, heartbeats, error replies, disconnect | No | **PASS** — 8 tests |
| 3 | `transport.ts` `TcpTransport` against a real local TCP server (loopback, no board) | No | **PASS** — 5 tests |
| 4 | **Gate:** upload a trivial standalone program to a real CyberPi and confirm a real TCP socket can be opened from it. `docs/mbuild-api-surface.md` has circumstantial evidence this works (an MQTT example connects to a public broker), but it hasn't been run by this project | Yes | |
| 5 | If 4 passes: `rocky_agent.py` accepts a TCP connection from a laptop running `TcpTransport`, and a `stop` command round-trips to an `ack` | Yes | |
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

## What "gate" means here (step 4)

If stock CyberOS turns out not to have `socket` in an uploaded program, everything from step 5
onward in this list needs a different transport or a different firmware entirely — most likely
porting the motion agent onto `apps/cyberpi`'s existing native ESP-IDF firmware and OTA plumbing,
since that's already proven to have real networking. That's a real fork in the road, not a detail;
see `PLAN.md`'s answer to "can we do OTA?" for the reasoning. Don't build steps 5+ against an
assumption this step hasn't checked yet.

## Running a step

Same mechanics as `apps/cyberpi`: mBlock 5, Python editor, mode set to **Upload** (not Live).
`rocky_agent.py` is a single self-contained file, same reason as the cyberpi steps — mBlock
uploads one program at a time.
