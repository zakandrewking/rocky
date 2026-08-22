# Rocky as a networked robot body (apps/robot)

> **Note (2026-08-16):** `device/rocky_agent.py` now means the *autonomous* agent — the one and
> only payload. What this document calls the motion agent (commanded drive/turn over TCP on 8765)
> is deprecated and frozen at [`deprecated/motion_agent.py`](deprecated/motion_agent.py). The
> history below is left as written; see [`README.md`](README.md) for what runs today.

## North star

**Rocky navigates a room, finds a person, follows them, and talks to them — without crashing.**

Everything in this plan earns its place by moving toward that sentence. Mapping exists so Rocky
knows where "around the room" is. The camera layer exists so Rocky can tell a person from a
chair. The obstacle-avoidance reflex exists so "without crashing" holds even when the plan or the
network is wrong. Talking is the one part that's already solved — see below.

## Relationship to apps/cyberpi

This is a second, independent track from [`apps/cyberpi`](../cyberpi/PLAN.md), not a replacement
for it. They're solving different problems:

- **`apps/cyberpi`** asks whether the CyberPi itself can carry a realtime *voice* conversation,
  and answered "not on stock firmware" — it's building native ESP32 firmware to drive the audio
  codec directly, because the product bar is ~10 ms buffering and barge-in.
- **`apps/robot`** doesn't need that answer at all. **Update: the brain moved from the laptop to
  an iPhone** (see [`apps/ios`](../ios/README.md)) — an iPhone mounted on or near the robot is
  Rocky's mic, speaker, camera, and face, using its own built-in audio hardware/AEC to meet the
  same realtime bar the desktop app meets over WebRTC, without needing `apps/cyberpi`'s native
  firmware at all. The CyberPi's job here is unchanged: motion and telemetry only — drive, sense,
  don't crash. "Talk to them" in the north star is the iOS app's own Realtime voice pipeline; once
  the robot is near a person, nothing on the CyberPi has to know or care that it's happening.

Once a laptop or the iPhone is physically mounted on the robot (Phase 6 below), all of this is
running on the same physical object, but as separable concerns: `apps/cyberpi`'s native firmware
would own audio I/O only if it's ever needed *on the CyberPi itself* (unlikely now that the phone
carries audio); `apps/robot`'s CyberOS agent owns the shield either way. Nothing here blocks or is
blocked by `apps/cyberpi`'s progress.

## Architecture

```text
iPhone (Rocky's brain — apps/ios)
  ├─ Rocky iOS app — voice, personality, memory (Realtime API, ported from apps/desktop)
  ├─ camera — semantic layer (Phase 5+)
  ├─ occupancy grid + semantic map (Phase 3+)
  ├─ route planning (Phase 4+) — lives here, not on the CyberPi
  └─ Robot SDK (Swift port of apps/robot/src) — drive/turn/stop/telemetry, bounded before it
     hits the wire, same protocol.ts spec a laptop CLI can also speak for testing/OTA
          │
          │ Wi-Fi, newline-delimited JSON over TCP (see docs/mbuild-api-surface.md
          │ for why not WebSocket/MQTT: unconfirmed whether stock CyberOS has sockets at all)
          ▼
CyberPi running stock CyberOS (apps/robot/device/rocky_agent.py)
  ├─ protocol server — the only thing that talks to the laptop
  ├─ heartbeat watchdog — stops motors if the link goes quiet
  ├─ obstacle-avoidance reflex — vetoes a commanded drive locally, no round trip to the laptop
  ├─ face/lights — cyberpi.display + cyberpi.led (already proven in apps/cyberpi Stage 1)
  └─ mbuild shield API (EncoderMotor, Ultrasonic, Color)
          │
          ▼
mBot2 Shield — motors, encoders, ultrasonic, line/color sensor
```

Rocky never gets direct low-level motor access: every command from an LLM tool call passes
through `protocol.ts`'s `boundCommand`, which clamps distance/angle/speed before anything reaches
the network. This is already implemented and tested (`apps/robot/src/protocol.ts`).

## The three original open questions, answered

### Can we do OTA?

**Not the way the plan originally assumed, and not for free.** The cited evidence
(`github.com/PerfecXX/mBot2` "demonstrating Wi-Fi filesystem upload") turned out, on actually
reading the source, to be a Wi-Fi pub/sub messaging primitive between two already-running
programs — not a way to push a new program onto the device. See
[`docs/mbuild-api-surface.md`](docs/mbuild-api-surface.md) for the full accounting.

What's real: mBlock's own GUI supports pushing one whole compiled program over Wi-Fi (alongside
USB/Bluetooth) in Upload mode. That's a genuine no-USB iteration path for `rocky_agent.py`, but
it's manual (through the mBlock app), all-or-nothing, and has no rollback story.

`apps/cyberpi` already solved OTA properly — `pnpm cyberpi:ota`, atomic `ota_0`/`ota_1`
partitions, no USB, verified on real hardware — but that's on **custom ESP-IDF firmware**, a
different world from the MicroPython program this plan runs under stock CyberOS.

**Update, once the socket gate (STEPS.md step 4) actually passed on real hardware**: scripted OTA
turned out to be buildable ourselves, without mBlock and without custom firmware. The gate proved
both a real bidirectional TCP socket *and* working file I/O (`os.listdir`/`stat`/etc. were already
in use elsewhere) are available in an uploaded stock-CyberOS program — which are exactly the two
primitives a scripted push needs.

The design: `device/bootstrap.py` is a small, rarely-changing loader, installed once via mBlock —
matching the original plan's "install the bootstrap manually through mBlock once." From then on,
`scripts/push.mjs` sends new code over the network; the loader writes it to a payload file and
reloads it, no mBlock or USB involved again. The one thing that matters for safety: the loader
owns its push-listener unconditionally, calling the payload's `tick()` once per loop iteration
rather than handing off control — so a payload that throws gets dropped without ever stopping the
loader's own ability to receive the next (fixed) push. Losing that would mean a single bad push
bricks remote recovery, right back to a USB cable.

This is not the atomic-partition, rollback-capable OTA `apps/cyberpi` has — there's no A/B
payload slot, no version reporting, no rollback if a push itself is malformed enough to fail
writing cleanly. If that ever matters, the fallback is still porting the motion agent onto
`apps/cyberpi`'s existing native-firmware OTA plumbing. But for iteration speed during
development, this closes the actual gap: `apps/robot/STEPS.md`'s step 4b is where this got proven
on real hardware.

**Reused for iOS→CyberPi too.** `bootstrap.py`'s wire format (write bytes, half-close, read a
reply) doesn't know or care what kind of client sent them — `scripts/push.mjs` is ~40 lines of
socket handling, small enough that `apps/ios` ports it directly to Swift rather than needing the
laptop in the loop for every CyberPi push. Laptop→iPhone OTA is a different mechanism entirely
(Xcode/`devicectl` wireless install, a real rebuild-and-reinstall, not a live patch) — see
`apps/ios/README.md`.

### AI goals × mBot2 Shield obstacle avoidance — how do they integrate?

There's no firmware-level "avoid obstacles" toggle to integrate with (confirmed absent from the
`mbuild` API surface — see the doc above). So this isn't wiring two existing systems together;
it's building one small one. The design:

- The **iPhone** plans: given the occupancy grid and a goal ("go toward the couch"), it issues
  `drive`/`turn` commands.
- The **CyberPi agent** runs a cheap local reflex on every control cycle, independent of what the
  laptop asked for: poll `Ultrasonic.get_distance()`, and if it drops under a safety threshold
  mid-drive, call `EncoderMotor.stop()` immediately and report `distance` telemetry back. The
  laptop sees the early stop via telemetry and replans; it does not have to be fast enough to
  prevent the collision itself, because the reflex already did.
- This mirrors the heartbeat watchdog that's already built into `rocky_agent.py`'s design: safety
  lives on the device, at the timescale the device can actually guarantee, and the laptop reacts
  to reports rather than being trusted to arrive in time. Same principle both times — a dropped
  Wi-Fi packet and an unseen coffee table are the same class of failure.

### Where does route-planning live?

**On the iPhone**, next to the LLM tool-call layer and the occupancy grid, not on the CyberPi.
This matches `apps/cyberpi/PLAN.md`'s own principle for the audio track ("the robot remains a
thin embodied client") — same reasoning applies to motion. The CyberPi has no map, no goal, and
no memory of the room; it only knows the command it was just given and whether its own ultrasonic
sensor currently disagrees with that command.

## Spatial mapping: rotate-and-ping, not SLAM

Discussed and agreed: build a **crude occupancy grid**, not precise metric SLAM — the hardware
doesn't support the latter well. The mBot2 has a single fixed, wide-beam ultrasonic sensor, and
wheel-encoder odometry that drifts with slip; there's no LIDAR or depth camera, and no way to
close a loop and correct that drift. That combination is fine for "is the space ahead roughly
open," not for a nav-stack-grade map — a real upgrade path is a LIDAR or depth camera, deliberately
deferred rather than attempted now.

The technique: rotate the whole robot in place in fixed angle increments (say 15°), take an
ultrasonic reading at each, and you get a low-resolution 360° polar scan — a poor-man's LIDAR
sweep built entirely from primitives Phase 1-2 already needs (`turn`, `readDistance`). Convert
each polar scan to world-frame points using the robot's estimated pose (odometry + the CyberPi's
onboard gyro for heading), and merge scans taken from a few different spots in the room into one
occupancy grid on the laptop. Good enough to tell Rocky "the doorway is roughly northeast of
here"; not good enough to trust down to the centimeter.

## Camera: a second, semantic layer

The ultrasonic/odometry layer answers *where is space free*. It cannot answer *what is that* or
*is that a person*. The iPhone's camera fills that gap — a meaningfully better sensor for this
than a laptop webcam would have been — and does so as a genuinely different kind of sensor, not a
redundant one: monocular vision gives identity and bearing (this is a person, and they're roughly
20° to my left) but not reliable depth — so it composes with the occupancy grid rather than
replacing it. "Find/follow a person" in the north star is this layer plus the occupancy grid
together — bearing from vision, safe approach distance from ultrasonic.

**Update (2026-08-21): built as a second model, not the Realtime session.** The original plan here
was to reuse the same vision-capable model already reasoning for Rocky's voice, to avoid a second
CV pipeline. Built instead: `apps/ios/Rocky/Sources/PersonCamera.swift` samples the **front**
camera (same side as the screen showing Rocky's face) roughly every 2.5s and `PersonVision.swift`
sends each frame to **Gemini Robotics-ER** (`gemini-robotics-er-2-streaming-preview`) — a model
purpose-built for embodied/spatial reasoning, and deliberately a separate model and provider from
the OpenAI Realtime voice session, so a slow or stuck vision call can never stall the one
continuous session that has to keep talking. That model is only exposed via Gemini's Live API (a
stateful WebSocket, not one-shot REST), so `PersonVision` holds a session open for the camera's
whole run rather than reconnecting per frame. See `apps/ios/README.md`'s "Seeing a person, with a
second model" for the detail. What exists today is person-presence and bearing only, running
standalone and gated behind an explicit on/off in the camera panel (per the privacy note below) —
not yet tagged onto the occupancy grid or wired into
`drive`/`turn`, which is real Phase 9→10 work still ahead once Phase 6 (physical mount) and Phases
3-4 (occupancy grid) exist to wire it into.

Two things to hold onto before building this:

- **The camera isn't on the robot until it's physically mounted** (Phase 6). Don't block Phase 5
  on Phase 6 without deciding that explicitly.
- **Privacy**: a camera on a family device is a materially bigger deal than audio alone (this
  project's existing rule is already careful about audio memory — see root `TODOS.md`). Default
  to no persistent recording, and give it an explicit, visible on/off — not bundled silently into
  "the robot is on."

## Repo shape

```text
apps/robot/
├── PLAN.md                    — this file
├── STEPS.md                   — ordered test list, software-only steps first
├── README.md
├── docs/
│   └── mbuild-api-surface.md  — the mBot2 Shield API research, and the OTA claim checked
├── src/                       — SDK (@rocky/robot), the protocol spec any client ports against
│   ├── protocol.ts            — wire format, command bounding
│   ├── transport.ts           — TcpTransport (real) + MockTransport (tests, no hardware)
│   ├── robot.ts                — Robot: drive/turn/stop/setFace/setLights/readDistance/...
│   └── index.ts
├── scripts/
│   └── push.mjs                — pushes a payload file to a running bootstrap.py over Wi-Fi
└── device/
    ├── bootstrap.py            — OTA loader, uploaded once via mBlock, owns Wi-Fi + the push port
    └── rocky_agent.py          — the motion-control payload, pushed over the network from here on

apps/ios/                       — Rocky's brain: voice, personality, camera, face (see its README)
```

## Movement primitives: confirmed, and one real risk

Checking `github.com/PerfecXX/mBot2`'s actual device examples (not just the generated PyPI
package) upgraded this plan materially — see `docs/mbuild-api-surface.md` for the full accounting:

- `mbot2.straight(cm)` and `mbot2.turn(degrees)` are real, confirmed calls that take exactly the
  units `drive`/`turn` need — no calibration guesswork for distance/angle.
- `cyberpi.get_yaw()` gives heading directly from the onboard gyro — no accessory IMU needed for
  the rotate-and-ping scan's pose tracking.
- But `straight`/`turn` appear to **block until the maneuver finishes**, based on how the examples
  call them back-to-back with no polling in between. If true, they're unusable for the
  obstacle-avoidance reflex: a reflex that can only check the ultrasonic sensor *between* blocking
  calls, after several blind seconds of `straight(200)`, doesn't hold up the north star's "without
  crashing." So `rocky_agent.py` is built on `mbot2.drive_speed(em1, em2)` instead — not time- or
  distance-boxed, so the agent's own loop can drive in short bursts, poll the ultrasonic between
  them, and cut power immediately on its own schedule. Whether `straight`/`turn` truly block is
  unconfirmed and worth settling on hardware (STEPS.md) — if they don't, they're less code to get
  wrong and worth switching to.

## Build order toward the north star

Software-first, hardware steps clearly separated and deferred until there's physical access to
the board (none in this environment right now). Full detail in `STEPS.md`; summary here:

1. **Protocol + SDK, hardware-free.** Done: `boundCommand`, newline-JSON framing, `Robot` against
   `MockTransport`, a loopback `TcpTransport` test against a real local TCP server. 25 tests
   passing.
2. **The one hardware fact that decides everything else**: can an uploaded (standalone) CyberOS
   program open a real TCP socket? A real device example (`extension/02-mqtt/01-mqtt_publish.py`)
   connects to a public MQTT broker from an uploaded program, which is strong circumstantial
   evidence this works — but it hasn't been run by this project yet. If it turns out not to, the
   fallback is porting the motion agent onto `apps/cyberpi`'s native firmware instead.
3. Single motor + heartbeat watchdog on real hardware: drive briefly, then kill the connection and
   confirm the agent stops on its own.
4. Confirm whether `mbot2.straight`/`turn` actually block the interpreter, which decides whether
   `rocky_agent.py`'s `drive_speed`-based interruptible control loop is necessary or whether the
   simpler blocking calls are safe to use after all.
5. Ultrasonic rotate-and-ping: verify a real scan produces a plausible point cloud against a known
   room layout.
6. Stitch scans from 2-3 spots into one occupancy grid on the iPhone; eyeball it against the real
   room.
7. Obstacle-avoidance reflex: verify the agent stops a commanded drive on its own when something
   is placed in the ultrasonic's path, independent of the client.
8. iPhone-side planning against the occupancy grid: drive toward an open frontier.
9. Camera semantic layer: detect a person in frame, estimate bearing, turn to face them.
10. Find/follow: combine occupancy-grid navigation with person bearing to approach and hold a
    comfortable distance.
11. Talk: hand off to the iOS app's own Realtime voice conversation once close (see
    `apps/ios/README.md`) — no new work on the CyberPi side.
12. **North-star run**: navigate the room, find a person, approach, talk, without crashing. Run it
    repeatedly; tune reflex thresholds and planning behavior against what actually happens, not
    what was assumed here.

## Docking and power (future — not being built yet)

Deferred design, captured here so it isn't lost: a dock that recharges **both** the mBot2 and the
iPhone from one external connection, without merging their power domains. Worth revisiting once
Phase 6 (physical mount) is actually being built, not before.

- **Two independent battery systems, one dock.** The mBot2 keeps its own ~2500 mAh battery and
  Makeblock's existing USB-C charging circuitry untouched (their own guidance keeps that input
  under 6 V — don't build a custom charger for it). The iPhone keeps charging itself over a
  permanently-attached Lightning cable, wired rather than MagSafe (avoids inductive conversion
  loss/heat for no benefit on a robot). The dock is a **power distribution board**, not a USB hub —
  a 12 V input feeds two independent DC-DC converters (12V→5V for the CyberPi's USB-C, 12V→USB-PD
  for the iPhone), so no USB data line is ever involved in charging.
- **Roomba-style contacts, not a USB plug the robot has to align.** Large spring-loaded copper
  pads on the dock meet large pads on the robot's underside/rear — several millimeters of
  tolerance, unlike pogo pins. Angled guide rails on the dock do the final centimeter of mechanical
  alignment so software only has to get close, not exact.
- **Sizing:** roughly 12 V × 4 A (48 W) dock output, well above the combined real draw (mBot2
  charging is inferred, not spec'd, at roughly ≤10 W from its battery capacity and Makeblock's
  advertised charge time; iPhone mini wired charging tapers well under 20 W) — cheap headroom
  rather than a tight budget.
- **Self-docking sequence:** the iPhone's own camera finds an AprilTag on the dock (no extra camera
  or compute needed — the phone already carries the vision layer per this plan's Phase 5), steers
  toward it, and hands off to the CyberPi's line/distance sensors for the final approach and
  backing onto the contacts. A third dock contact (or just detecting that the iPhone started
  charging) gives an unambiguous `DOCKED` state.
- **Why this is worth it later:** it removes the need for any separate robot power bank entirely —
  added mass is roughly the phone itself plus ~50-100 g of converters/contacts/mount, and the two
  batteries stay electrically independent while roaming (mBot battery → motors + CyberPi; iPhone
  battery → the entire "head") and both recharge from the same dock when parked.
