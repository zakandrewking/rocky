# Pushed into bootstrap.py as a payload. v10 of the loudness-driving experiment, built on v9's
# (step14) continuous self-noise-subtracted engine.
#
# Live UX direction (2026-08-08), restated as a small state machine on top of what step14 already
# does well (quiet -> still, quiet talk -> slow proportional creep, self-noise-only -> stop,
# anything louder than self-noise -> speed up -- all already true of step14's continuous mapping,
# unchanged here):
#
#   - Drive forward continuously for as long as it's louder than self-noise (step14's job).
#   - If it's been driving forward continuously for DRIVE_TIMEOUT_MS (~8s), stop and spin ~180
#     degrees, then require a fresh sound to move again -- so it doesn't just drive off forever
#     in one direction. New "turning" mode below.
#   - A sudden, very loud spike (not a scream that built up gradually -- a BANG) should look
#     startled: a quick reverse jolt ("jump" -- the mBot2 has no legs, so this is the closest
#     physical analog), then keep retreating for a bit ("runs away"). New "startled" mode below.
#
# What's measured vs. guessed, stated plainly (same discipline as step13/step14): CURVE and
# SELF_NOISE are still from the real 2026-08-08 calibration run. TURN_RPM/TURN_MS and the startle
# thresholds below are NOT measured -- turning speed/duration has no real deg/s calibration yet
# (STEPS.md step 9 is still open), and there's no dedicated "sudden loud bang" calibration phase
# (step12 only captured sustained talk/loud/scream). Both are best-guess starting points, flagged
# exactly like v1-v7's window sizes were, meant to be tuned against live telemetry rather than
# trusted as-is.
#
# One more approximation worth naming: SELF_NOISE was measured while spinning in place
# (step12's motor calibration phases used drive_speed(rpm, rpm), the same motion "turning" uses
# here) but is reused for straight forward/backward driving too (drive_speed(rpm, -rpm)) in
# "listening" and "startled" mode, where the mechanical load likely isn't identical. Untested;
# a future dedicated forward-drive self-noise calibration would settle it.

import cyberpi
import mbot2
import utime

try:
    import usocket as socket
except ImportError:
    import socket

# ============================== CALIBRATED CONSTANTS (measured) ==============================
CURVE = ((3.0, 0.0), (6.0, 0.35), (40.0, 0.85), (80.0, 1.0))  # (loudness above floor, level)
SELF_NOISE = ((0.0, 0.0), (20.0, 42.0), (40.0, 65.0), (60.0, 83.0))  # (rpm, loudness above floor)
SETTLE_MS = 180  # measured ring-down (step12); used once at boot before seeding the floor
# ==============================================================================================

# ============================== GUESSED CONSTANTS (untested -- tune live) ====================
DRIVE_TIMEOUT_MS = 8000  # how long continuous forward driving runs before the 180 turn
TURN_RPM = 45
TURN_MS = 1100  # paired guess with TURN_RPM for "about 180 degrees" -- no deg/s data exists yet
STARTLE_ABS_THRESHOLD = 85.0  # external loudness must be at least this high...
STARTLE_JUMP_THRESHOLD = 55.0  # ...AND this far above the recent baseline, to count as a sudden
BASELINE_ALPHA = 0.03  # bang rather than a scream that built up gradually over ~1s+
JUMP_RPM = 55
JUMP_MS = 300  # the startled "flinch" -- reverse hard, briefly
FLEE_RPM = 45
FLEE_MS = 2500  # then keep retreating before returning to normal listening
# ==============================================================================================

LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP -- check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

MAX_RPM = 60
MIN_RPM = 10  # below this the encoder motors whine without really moving; snap to it or to 0
MIN_LEVEL = 0.05
ATTACK = 0.35  # per-tick smoothing at this payload's fast (~15-20Hz) continuous tick rate
RELEASE = 0.08

FLOOR_SEED_SAMPLES = 8
FLOOR_SEED_INTERVAL_MS = 25

# level threshold, face key, label, LED color -- highest threshold <= level wins. idle/listening/
# happy are device/rocky_agent.py's existing vocabulary; "alert" is new here (see step14).
FACES = (
    (0.0, "idle", ". _ .", (40, 40, 60)),
    (0.15, "listening", "o _ o", (0, 150, 255)),
    (0.5, "alert", "> < ", (255, 150, 0)),
    (0.85, "happy", "^ _ ^", (255, 30, 130)),
)
FACE_MIN_DWELL_MS = 200

_state = {
    "booted": False,
    "floor": None,
    "level": 0.0,
    "rpm": 0,
    "baseline": 0.0,
    "driving_since": None,
    "mode": "listening",  # "listening" | "turning" | "startled"
    "mode_start": 0,
    "face": None,
    "face_since": 0,
    "sock": None,
    "sock_tried": False,
}


def _interp(table, x):
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


def _send_telemetry(extra):
    if _state["sock"] is None:
        return
    try:
        _state["sock"].sendall(
            '{{"t":{},"phase":"live","mode":"{}","level":{},"rpm":{}{}}}\n'.format(
                utime.ticks_ms(), _state["mode"], round(_state["level"], 3), _state["rpm"], extra
            ).encode()
        )
    except Exception:
        try:
            _state["sock"].close()
        except Exception:
            pass
        _state["sock"] = None


def _show_face(label, color):
    cyberpi.display.clear()
    cyberpi.display.show_label(label, 32, 30, 50, 0)
    cyberpi.led.on(color[0], color[1], color[2], id="all")


def _update_listening_face(now):
    face = FACES[0]
    for candidate in FACES:
        if _state["level"] >= candidate[0]:
            face = candidate
    if face[1] == _state["face"] or utime.ticks_diff(now, _state["face_since"]) < FACE_MIN_DWELL_MS:
        return
    _state["face"] = face[1]
    _state["face_since"] = now
    brightness = min(1.0, _state["level"] / 0.85)
    color = tuple(int(component * brightness + 20) for component in face[3])
    _show_face(face[2], color)


def _boot():
    mbot2.drive_speed(0, 0)  # guarantee motors are physically stopped before seeding the floor,
    # in case a mid-drive payload was just replaced by this push
    utime.sleep_ms(SETTLE_MS)
    samples = []
    for _ in range(FLOOR_SEED_SAMPLES):
        samples.append(cyberpi.get_loudness())
        utime.sleep_ms(FLOOR_SEED_INTERVAL_MS)
    _state["floor"] = min(samples)
    _state["booted"] = True
    _connect_telemetry()
    _show_face(". _ .", (40, 40, 60))


def _enter(mode, now):
    _state["mode"] = mode
    _state["mode_start"] = now
    _state["driving_since"] = None


def _tick_listening(now):
    loudness = cyberpi.get_loudness()
    self_noise = _interp(SELF_NOISE, _state["rpm"])
    external = max(0.0, loudness - _state["floor"] - self_noise)
    _state["baseline"] += BASELINE_ALPHA * (external - _state["baseline"])

    if external >= STARTLE_ABS_THRESHOLD and (external - _state["baseline"]) >= STARTLE_JUMP_THRESHOLD:
        _enter("startled", now)
        _show_face("O   O", (255, 255, 255))
        return

    raw_level = _interp(CURVE, external)
    alpha = ATTACK if raw_level > _state["level"] else RELEASE
    _state["level"] += alpha * (raw_level - _state["level"])

    # Hysteresis at the quiet threshold: without this, sensor noise hovering right around
    # MIN_LEVEL would flip rpm between 0 and MIN_RPM every tick -- a literal stutter, just a
    # faster one than v1-v7's stop/listen cycle instead of the cycle itself. Only actually stop
    # once level has stayed below MIN_LEVEL for STOP_DWELL_MS straight.
    if _state["level"] > MIN_LEVEL:
        _state["below_min_since"] = None
        _state["rpm"] = max(MIN_RPM, int(_state["level"] * MAX_RPM))
    elif _state["below_min_since"] is None:
        _state["below_min_since"] = now
        _state["rpm"] = MIN_RPM
    elif utime.ticks_diff(now, _state["below_min_since"]) < STOP_DWELL_MS:
        _state["rpm"] = MIN_RPM
    else:
        _state["rpm"] = 0

    if _state["rpm"] > 0:
        mbot2.drive_speed(_state["rpm"], -_state["rpm"])
        if _state["driving_since"] is None:
            _state["driving_since"] = now
        elif utime.ticks_diff(now, _state["driving_since"]) >= DRIVE_TIMEOUT_MS:
            mbot2.drive_speed(0, 0)
            _enter("turning", now)
            _show_face("O   O", (255, 150, 0))
            return
    else:
        mbot2.drive_speed(0, 0)
        _state["driving_since"] = None

    _update_listening_face(now)
    _send_telemetry(
        ',"loud":{},"floor":{},"external":{}'.format(
            loudness, _state["floor"], round(external, 1)
        )
    )


def _tick_turning(now):
    elapsed = utime.ticks_diff(now, _state["mode_start"])
    if elapsed < TURN_MS:
        mbot2.drive_speed(TURN_RPM, TURN_RPM)  # spin in place -- guessed ~180 degrees, see header
    else:
        mbot2.drive_speed(0, 0)
        _state["level"] = 0.0
        _state["rpm"] = 0
        _enter("listening", now)
        _show_face(". _ .", (40, 40, 60))
    _send_telemetry("")


def _tick_startled(now):
    elapsed = utime.ticks_diff(now, _state["mode_start"])
    if elapsed < JUMP_MS:
        mbot2.drive_speed(-JUMP_RPM, JUMP_RPM)  # sharp reverse jolt -- the closest analog to a
        # "jump" the mBot2 has, given it has no legs
    elif elapsed < JUMP_MS + FLEE_MS:
        mbot2.drive_speed(-FLEE_RPM, FLEE_RPM)  # keep retreating
    else:
        mbot2.drive_speed(0, 0)
        _state["level"] = 0.0
        _state["rpm"] = 0
        _state["baseline"] = 0.0
        _enter("listening", now)
        _show_face(". _ .", (40, 40, 60))
    _send_telemetry("")


def tick():
    if not _state["booted"]:
        _boot()
        return

    now = utime.ticks_ms()
    try:
        if _state["mode"] == "listening":
            _tick_listening(now)
        elif _state["mode"] == "turning":
            _tick_turning(now)
        else:
            _tick_startled(now)
    except Exception:
        mbot2.drive_speed(0, 0)  # never let bootstrap drop this payload with motors spinning
        raise
