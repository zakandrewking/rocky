# Pushed into bootstrap.py as a payload. v9 of the loudness-driving experiment.
#
# Live feedback on v8 (step13): the mapping curve felt right, but the listen(80ms)/drive(500ms)/
# settle(180ms) cycle it inherited from v4/v7 means the motors fully stop for ~260ms of every
# ~760ms cycle (~34% of the time) so the mic can get a clean, feedback-free reading. That reads as
# "little bursts," not the "consistent driving, responding to my voice" the live test asked for.
#
# The fix: stop alternating motors-off/motors-on and drive continuously, subtracting each
# instant's *predicted* self-noise for the currently-commanded RPM instead of avoiding self-noise
# by going silent. This is exactly the architecture option
# docs/loudness-drive-problem-statement.md left open ("return to self-noise subtraction... but
# only if the per-RPM self-noise constants come from the deliberate calibration pass"). v5/v6
# tried this and got burned by *live* recalibration (v6's forced recalibration sampled a scream
# as "quiet" and corrupted the model forever). The difference here: SELF_NOISE below is fixed at
# push time from the same real calibration run as v8's CURVE
# (local-data/robot-telemetry/2026-08-08T20-40-13-496Z.jsonl) -- it is never updated live, so
# there is no corruption vector to reintroduce. The ambient floor is seeded once at boot (motors
# confirmed stopped, then the measured ring-down SETTLE_MS elapses, then several samples are
# taken and the minimum kept) and then also held fixed for the session. Trade-off, stated
# plainly: unlike v7's per-cycle leaky-min floor, this can't track ambient drift *during* a
# session (e.g. someone turns on music later) -- if that turns out to matter, the fix is
# re-pushing (which reboots and reseeds), not a code change.
#
# "Personality": reuses the exact face vocabulary device/rocky_agent.py's set_face() already
# established (idle/listening/happy from PLAN.md Phase 5), rather than inventing a new one, plus
# one new "alert" state for the mid-range. LED color still tracks level continuously underneath
# the discrete face, so it feels alive at every level, not just at the four checkpoints.

import cyberpi
import mbot2
import utime

try:
    import usocket as socket
except ImportError:
    import socket

# ============================== CALIBRATED CONSTANTS =========================================
# Same source and methodology as step13's CURVE (see that file's header) -- piecewise-linear
# anchors, not a guessed constant. Top two anchors live-tuned the same day: 40 should feel
# "pretty fast" without being maxed, and true max is reserved for 80, the measured loud-talking
# level (its 75th percentile -- see analyze-calibration.mjs's ANCHOR_PERCENTILES comment).
CURVE = ((3.0, 0.0), (6.0, 0.35), (40.0, 0.85), (80.0, 1.0))  # (loudness above floor, level)

# Self-noise while driving quietly at a given RPM, measured directly (motor20/40/60 phases,
# same calibration run). Interpolated the same way as CURVE -- no assumption about whether
# self-noise is linear in RPM (analyze-calibration.mjs's delta/rpm output showed it isn't quite:
# 2.1, 1.6, 1.4 -- sublinear, plausibly a fixed mechanical-noise floor plus a smaller
# speed-dependent term).
SELF_NOISE = ((0.0, 0.0), (20.0, 42.0), (40.0, 65.0), (60.0, 83.0))  # (rpm, loudness above floor)

SETTLE_MS = 180  # measured ring-down (step12); used once at boot before seeding the floor
# ==============================================================================================

LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP -- check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

MAX_RPM = 60
MIN_RPM = 10  # below this the encoder motors whine without really moving; snap to it or to 0
MIN_LEVEL = 0.05
ATTACK = 0.35  # per-tick smoothing, tuned for this payload's fast (~15-20Hz) continuous tick
RELEASE = 0.08  # rate -- much smaller than v8's per-listen-window values, which fired ~1.3Hz

FLOOR_SEED_SAMPLES = 8
FLOOR_SEED_INTERVAL_MS = 25

FACES = (
    # (level threshold, face key, label, LED color) -- highest threshold <= level wins.
    # idle/listening/happy are device/rocky_agent.py's existing vocabulary; "alert" is new here.
    (0.0, "idle", ". _ .", (40, 40, 60)),
    (0.15, "listening", "o _ o", (0, 150, 255)),
    (0.5, "alert", "> < ", (255, 150, 0)),
    (0.85, "happy", "^ _ ^", (255, 30, 130)),
)
FACE_MIN_DWELL_MS = 200  # debounce so noisy readings near a threshold don't flicker the face

_state = {
    "booted": False,
    "floor": None,
    "level": 0.0,
    "rpm": 0,
    "face": None,
    "face_since": 0,
    "sock": None,
    "sock_tried": False,
}


def _interp(table, x):
    """Piecewise-linear lookup through (x, y) anchors, shared by CURVE and SELF_NOISE."""
    if x <= table[0][0]:
        return table[0][1]
    for index in range(1, len(table)):
        x0, y0 = table[index - 1]
        x1, y1 = table[index]
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return table[-1][1]


def _connect_telemetry():
    _state["sock_tried"] = True
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((LAPTOP_HOST, LAPTOP_PORT))
        sock.settimeout(2)
        _state["sock"] = sock
    except Exception:
        _state["sock"] = None  # driving must work with no laptop listening


def _send_telemetry(loudness, external, self_noise):
    if _state["sock"] is None:
        return
    try:
        _state["sock"].sendall(
            '{{"t":{},"phase":"live","loud":{},"floor":{},"self_noise":{},"external":{},'
            '"level":{},"rpm":{}}}\n'.format(
                utime.ticks_ms(),
                loudness,
                _state["floor"],
                round(self_noise, 1),
                round(external, 1),
                round(_state["level"], 3),
                _state["rpm"],
            ).encode()
        )
    except Exception:
        try:
            _state["sock"].close()
        except Exception:
            pass
        _state["sock"] = None


def _update_face(now):
    face = FACES[0]
    for candidate in FACES:
        if _state["level"] >= candidate[0]:
            face = candidate
    if face[1] == _state["face"]:
        return
    if utime.ticks_diff(now, _state["face_since"]) < FACE_MIN_DWELL_MS:
        return
    _state["face"] = face[1]
    _state["face_since"] = now
    cyberpi.display.clear()
    cyberpi.display.show_label(face[2], 32, 30, 50, 0)


def _boot():
    """One-time, motors-confirmed-off floor seed. See header for why this is safe (unlike
    v5/v6) and why it only happens once (unlike v7)."""
    mbot2.drive_speed(0, 0)  # guarantee motors are physically stopped, even if a payload that
    # was mid-drive just got replaced by this push
    utime.sleep_ms(SETTLE_MS)
    samples = []
    for _ in range(FLOOR_SEED_SAMPLES):
        samples.append(cyberpi.get_loudness())
        utime.sleep_ms(FLOOR_SEED_INTERVAL_MS)
    _state["floor"] = min(samples)
    _state["booted"] = True
    _connect_telemetry()
    cyberpi.display.clear()
    cyberpi.display.show_label("floor:{}".format(_state["floor"]), 12, 0, 0, 0)


def tick():
    if not _state["booted"]:
        _boot()
        return

    now = utime.ticks_ms()
    loudness = cyberpi.get_loudness()
    self_noise = _interp(SELF_NOISE, _state["rpm"])
    external = max(0.0, loudness - _state["floor"] - self_noise)

    raw_level = _interp(CURVE, external)
    alpha = ATTACK if raw_level > _state["level"] else RELEASE
    _state["level"] += alpha * (raw_level - _state["level"])

    try:
        _state["rpm"] = (
            max(MIN_RPM, int(_state["level"] * MAX_RPM)) if _state["level"] > MIN_LEVEL else 0
        )
        if _state["rpm"] > 0:
            mbot2.drive_speed(_state["rpm"], -_state["rpm"])  # forward, confirmed convention
        else:
            mbot2.drive_speed(0, 0)

        _update_face(now)
        brightness_scale = min(1.0, _state["level"] / 0.85)
        base_color = next(f[3] for f in FACES if f[1] == _state["face"])
        cyberpi.led.on(
            int(base_color[0] * brightness_scale + 20),
            int(base_color[1] * brightness_scale + 20),
            int(base_color[2] * brightness_scale + 20),
            id="all",
        )
        _send_telemetry(loudness, external, self_noise)
    except Exception:
        mbot2.drive_speed(0, 0)  # never let bootstrap drop this payload with motors spinning
        raise
