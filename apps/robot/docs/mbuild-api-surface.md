# mBot2 Shield API surface (`mbuild`), and the OTA claim, checked

> **Note (2026-08-16):** `device/rocky_agent.py` now means the *autonomous* agent — the one and
> only payload. What this document calls the motion agent (commanded drive/turn over TCP on 8765)
> is deprecated and frozen at [`deprecated/motion_agent.py`](../deprecated/motion_agent.py). The
> history below is left as written; see [`README.md`](../README.md) for what runs today.

Desk research for `apps/robot`, done the way [`CLAUDE.md`](../../../CLAUDE.md) asks: check for
published source before probing hardware. Same evidence-tier discipline as
[`apps/cyberpi/docs/cyberos-api-surface.md`](../../cyberpi/docs/cyberos-api-surface.md) — a
generated PyPI package is real evidence, but weaker than firmware source or a `dir()` on a real
board, because Stage 1 already caught this exact package understating what the CyberPi board
actually exposes for audio.

## Where these names come from

```bash
pip download makeblock --no-deps -d /tmp/mb && unzip -o /tmp/mb/*.whl -d /tmp/mb_x
```

`makeblock` 0.1.8. The mBot2 Shield's motion/sensor API is **not** under `cyberpi` — that
namespace is the CyberPi board itself (audio, display, wifi, cloud; see the cyberpi doc above).
It lives in a separate top-level module: `makeblock/modules/mbuild/modules.py`. Both share the
same generated-online-mode-glue caveat: real names, unconfirmed semantics until hardware says
otherwise.

## Motion and sensing: two tiers of evidence

### Confirmed from real device examples — `github.com/PerfecXX/mBot2`, `example/micropython/`

Stronger evidence than the generated package below: these are example programs the repo presents
as running on real mBot2/CyberPi hardware, not generated online-mode glue. Fetched directly via
`raw.githubusercontent.com`.

| Call | Confirmed from | Notes |
| --- | --- | --- |
| `mbot2.straight(cm)` | `01-mBot2 Chassis/02-go_straight.py` | Distance **in centimeters**, signed (negative = backward). Comment `"Forward 100 cm"` next to `mbot2.straight(100)` confirms the unit directly — no calibration guesswork needed for distance. |
| `mbot2.turn(degrees)` | `01-mBot2 Chassis/03-rotation.py` | Degrees, signed (`turn(-90)` labeled "Turn Left 90", `turn(90)` labeled "Turn Right 90"). |
| `mbot2.forward(rpm, seconds)` / `.backward(rpm, seconds)` / `.turn_left(rpm, seconds)` / `.turn_right(rpm, seconds)` | `01-basic_movement.py` | Time-boxed convenience wrappers; not used here since `straight`/`turn` already give distance/angle directly. |
| `mbot2.drive_speed(em1, em2)` | `04-encoder_speed.py` | Raw differential-drive RPM, one argument per encoder motor, **not time-boxed** — runs until called again. `drive_speed(0, 0)` stops. This is the one `rocky_agent.py` actually uses for driving (see "blocking calls and why they're a safety problem" below), not `straight`/`turn`. |
| `mbot2.motor_set(power, "all")` | `02-DC Motor/01-test_dc.py` | Extension-port DC motor, not the drive motors — not used here. |
| `mbot2.led_on(r, g, b, index, port)` / `.led_off(index, port)` | `03-LED Stripes/01-set_led.py` | Extension-port LED *strip* (RJ25 port `S1`/`S2`), a separate accessory from the CyberPi's own onboard LEDs (`cyberpi.led`) or screen (`cyberpi.display`). `rocky_agent.py` uses the onboard ones, confirmed present on every board without an accessory. |
| `cyberpi.get_yaw()` / `.get_pitch()` / `.get_roll()` | `cyberpi/05-Motion Sensing/05-get_yaw_pitch_roll.py` | The CyberPi's onboard gyro, directly callable — no `mbuild` accessory needed for heading. This is what the rotate-and-ping scan (`PLAN.md`) uses for pose, not a guessed `mbuild` IMU module. |

### S1–S4 accessory servos

The CyberOS call is `mbot2.servo_set(angle, port)`, where `angle` is 0–180 and the port is a
string such as `"S3"` or `"S4"`. This exact shape is independently demonstrated in the
[MakeBlock mBot2 Python booklet](https://robocoast.tech/wp-content/uploads/2023/05/MakeBlock-mBot2-Python-Booklet-v4-1.pdf)
(`servo_set(servo3, 'S3')` / `servo_set(servo4, 'S4')`) and a
[published CyberPi curriculum](https://wro.hu/wp-content/uploads/2025/10/Kreativ_robotika_CyberPi.pdf)
(`servo_set(0, "s1")`, followed by `servo_get("s1")`). A captured mBlock Smart World example
also uses `servo_set(90, "all")`, then S3/S4 individually. This is stronger than inferring the
call from a generic servo class, though still not published CyberOS firmware source.

`device/rocky_agent.py` therefore accepts only S3/S4, clamps again on the board, and invokes the
API only after an explicit phone command — never during boot. Each invocation gets a correlated
success/failure acknowledgement. Phone-side calibration maps a logical centered slider onto a
persistent, potentially asymmetric minimum/center/maximum range and can reverse a mirrored horn.
No endpoint calibration is assumed safe for an attached mechanism; defaults are simply the
servo API's full documented 0°/90°/180° range.

**Blocking calls and why they're a safety problem.** `straight`/`turn`/`forward`/etc. all appear
to run to completion before the next line executes (`02-go_straight.py` calls `straight(100)`
then immediately `straight(-100)`, with no polling in between). If that's really synchronous,
**the obstacle-avoidance reflex in `PLAN.md` cannot use them** — a reflex that only gets to check
the ultrasonic sensor *between* calls, after a multi-second blind `straight(200)`, is not a
reflex. `rocky_agent.py` is written against `drive_speed()` instead: it isn't time- or
distance-boxed, so the agent's own control loop can interleave short bursts of driving with
ultrasonic polling and call `drive_speed(0, 0)` the moment something is too close, on its own
timescale rather than whatever `straight()`'s internal one is. **Unconfirmed: whether `straight`/
`turn` truly block the interpreter or just look that way in a single-threaded example** — worth
settling on hardware since if they don't block, they're a simpler, less code to get wrong. Not
assumed away; see `STEPS.md`.

**`drive_speed(em1, em2)`'s real RPM ceiling** (found 2026-08-08, while tuning
`steps/step16_loudness_drive_sticky.py`'s top speed against live feedback: "can we go faster?"):
Makeblock's own product page for the mBot2's drive motor — the 180 Optical Encoder Motor
(`makeblock.com/products/180-optical-encoder-motor-for-mbot2`) — states **rated load speed 178
RPM ±10%**, no-load speed 350 RPM, reduction ratio 39.6:1. `drive_speed`'s em1/em2 arguments are
real RPM (confirmed above from `04-encoder_speed.py`), so this is the actual hardware ceiling for
them under load, not a value to guess at. STEPS.md step 9 (measured cm/s and deg/s per RPM) is
still open, so what a given RPM actually *feels like* on the ground remains untested — this only
answers "how high can the number go," not "what does it mean."

### Weaker tier: the generated `makeblock` PyPI package (0.1.8), `mbuild` module

No example in `PerfecXX/mBot2` demonstrates the mBot2's onboard ultrasonic or quad-color sensor
(the repo's `mBot2/` examples cover chassis and extension-port accessories only), so these two
still come from the generated package — the same weaker tier of evidence Stage 1 caught being
wrong about CyberPi audio.

| Class | Members | Notes |
| --- | --- | --- |
| `Ultrasonic` | `get_distance(idx)`, `.read(idx)` | Single-beam distance. Wide, imprecise cone (this is desk research; the beam angle itself is not in the package) — good for a coarse rotate-and-ping scan, not a laser point. |
| `Color` | `get_color()`, `get_intensity()`, `get_reflect()` | This **is** the line-follower surface — there is no separate `LineFollower` class. `get_reflect()` is what a line-following loop would poll. |

Also present in the package, not used by Phase 1: `EncoderMotor` (superseded by the confirmed
`mbot2` module above), `DCMotor`, `ExtDCMotor`, `SmartServo`, `Joystick`, `Button`, `Servo`,
`GPIO`, `PowerManager`, `Infrarer`, and various mbuild accessory sensors (Temperature, Humiture,
Slider, MQ2 gas, Light, SoilMoisture, Sound, Touch, LaserRanging, Flame, PIRMotion, Magnetic,
Angle, Motion/IMU — this last one is moot now that `cyberpi.get_yaw()` is confirmed directly).

**`Color.get_reflect()` does not actually exist** (found 2026-08-08, live on real hardware, while
wiring up bump detection for `steps/step16_loudness_drive_sticky.py`): the weak-tier evidence
above was simply wrong about this one method name. `dir(quad_rgb_sensor)` on the real device has
no `get_reflect` at all. Confirmed real replacement, found by probing candidate calls live rather
than guessing a second name from the same weak source: `get_all_data()` returns a 13-element list
whose first 4 elements are the per-channel readings (`quad` is literal — 4 channels, not 2);
`get_intensity(1)` independently returned the same value as `get_all_data()[0]`, cross-confirming
it. `device/rocky_agent.py`'s `read_line_sensors()` carried the same wrong assumption (it was
never run on hardware either) and has been fixed to match.

## No built-in obstacle-avoidance or line-following toggle

Grepped the whole `makeblock` package tree for `avoid`, `line_follow`, `autopilot`, `auto_drive`:
zero hits. Makeblock's own curricula teach "avoid" and "line-follow" as example *programs* — a
loop that reads `Ultrasonic`/`Color` and calls `EncoderMotor` itself — not a firmware behavior
mode callable from Python. (Confirmed for the Python surface; the two source PDFs found by web
search were not text-extractable, so this is inferred from absence, not from a firmware source
that says so outright.)

## The OTA claim, checked against the actual source

The original plan cited `github.com/PerfecXX/mBot2` as showing "Wi-Fi filesystem upload/download
under CyberOS." Having actually opened it: **that's not what it shows.**

- The repo is a collection of example programs (MicroPython + Arduino/PlatformIO), not firmware.
  Its own README states that flashing the Arduino examples overwrites CyberOS entirely.
- `example/micropython/extension/01-upload_broadcast/01-broadcast.py` uses
  `cyberpi.upload_broadcast.set(topic, message)` — backed by `upload_broadcast_c` in
  `makeblock/modules/cyberpi/api_cyberpi_api.py`, alongside sibling `wifi_broadcast`,
  `mesh_broadcast`, `cloud_broadcast` classes. **This is a Wi-Fi pub/sub message primitive
  between two already-running standalone programs — not a way to push a new program onto the
  device.** The name looked like OTA; it isn't.

What's actually real: Makeblock's own support docs ("How to Upload Programs to CyberPi or
mBot2") describe switching mBlock 5 to **Upload mode** and configuring **Wi-Fi** as a transport
alongside USB and Bluetooth (confirmed via a search-result snippet; `support.makeblock.com`
itself returns HTTP 403 in this environment, so the full article couldn't be re-fetched directly).
That is a real wireless deployment path — but it pushes **one whole compiled program through
mBlock's own GUI flow**, with no filesystem access, no partial update, no scripted `rockyctl push`,
and no rollback. `apps/cyberpi`'s native-firmware OTA (`pnpm cyberpi:ota`, atomic
`ota_0`/`ota_1` partitions, no USB required) already has all of that, on custom firmware. Stock
CyberOS does not have an equivalent — see `PLAN.md`'s answer to "can we do OTA?" for what this
means for `apps/robot`.

## Networking: better evidence now, still not proof

Grepped the generated `makeblock` package for `socket`, `ssl`, `ftp`, `http`: no direct
`socket`/`ssl` usage anywhere — every call there goes through Makeblock's own broker methods
(`cyberpi.wifi`, `*_broadcast`), not raw sockets. Taken alone, that would leave this fully open.

But `PerfecXX/mBot2`'s `example/micropython/extension/02-mqtt/01-mqtt_publish.py` is a real,
presented-as-working example that does `from mqtt import MQTTClient` and connects to
**`test.mosquitto.org`** — a public broker with no Makeblock involvement — from an uploaded
CyberOS program. MicroPython's standard MQTT client libraries (`umqtt.simple` and its relatives)
are themselves thin wrappers over `usocket`/`socket`; there would be no way to reach an arbitrary
external host over MQTT without a working general-purpose socket layer underneath. **This is
strong circumstantial evidence that stock CyberOS's uploaded-program environment has real TCP
networking, not just Makeblock's own broadcast/cloud primitives** — a meaningfully better
starting point than "completely unknown."

It is still not the same as running `import socket; socket.socket(...)` ourselves and watching it
work on this specific board/firmware version, which is why it stays the first hardware step in
`STEPS.md` rather than something taken on faith. If it fails despite this evidence, the fallback
in `PLAN.md` (porting the motion agent onto `apps/cyberpi`'s native firmware) still applies.
