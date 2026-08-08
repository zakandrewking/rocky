# Pushed into bootstrap.py as a payload. v11 of the loudness-driving experiment -- a real
# architecture change from v9/v10 (step14/step15), not just a tuning pass.
#
# Live UX direction (2026-08-08): while stopped, a single clean mic reading is trustworthy (no
# self-noise at all, motors are off) -- so treat that one good reading as decisive ("sticky"):
# commit to a sustained drive at the level it implies.
#
# Correction after live testing: committing and then going fully deaf until the sustain window
# ends meant a louder sound *while already driving* (e.g. starting soft then raising your voice)
# had no way to register until the current commitment happened to expire. Fixed by reading the
# mic during "driving" too, using the measured per-RPM SELF_NOISE table to tell "louder than my
# own motor" from "just my own motor" -- but only to ESCALATE: a reading that maps to a higher
# CURVE level than the current commitment bumps rpm up (and refreshes the sustain timer) right
# away, while a quieter-or-equal reading is ignored so the commitment still holds steady rather
# than decaying or jittering. This is a narrower, safer use of self-noise subtraction than v9's
# (step14) full continuous control loop: an approximation error here just shifts when an
# escalation fires, not the moment-to-moment speed itself.
#
# This does NOT reintroduce v1-v7's "stutter step." The difference is frequency and cause: v7
# forced a stop every ~700ms purely to sample, regardless of what was happening -- a mechanical,
# rhythmic hiccup. Here, a stop only happens at the natural end of a multi-second commitment (or
# after a turn/startle reaction), so pauses are infrequent and read as "taking a breath to listen
# again," not a hiccup while trying to move. Within a commitment, the motors run continuously
# every tick with no forced interruption -- see step14/step15's history for why continuous
# driving (vs. v4/v7/v8's per-cycle alternation) was the first fix for "little bursts."
#
# Behavior, mapped onto the existing measured pieces:
#   - Quiet -> stays still (a "listening" mode where rpm is always 0).
#   - One qualifying reading while listening -> commit: drive continuously at that level for a
#     sustain window sized by how loud it was (louder = longer, see SUSTAIN_* below), satisfying
#     both "quiet talk drives slowly for a few seconds" and "a scream should reach and hold max
#     speed" from docs/loudness-drive-problem-statement.md's original expected-usage section.
#   - A commitment that's been driving continuously for DRIVE_TIMEOUT_MS (~8s) gets interrupted
#     by a stop + ~180 degree turn, so sustained loud input doesn't just drive off in one
#     direction forever -- then goes back to listening, so if the sound is still going it can
#     commit again facing a new direction.
#   - A sudden, very loud spike while listening (not a scream that built up gradually) looks
#     startled: a quick reverse jolt ("jump" -- the mBot2 has no legs, so this is the closest
#     physical analog) then a few seconds retreating ("runs away").
#
# What's measured vs. guessed (same discipline as every prior version): CURVE is still from the
# real 2026-08-08 calibration run. SUSTAIN_MIN/MAX_MS, DRIVE_TIMEOUT_MS, TURN_RPM/TURN_MS, and the
# startle thresholds are NOT measured -- flagged exactly like v1-v7's window sizes were, meant to
# be tuned against live telemetry. SELF_NOISE is kept below purely as calibration data for
# reference (and because a future hybrid design might want it); this file's control loop no
# longer uses it at all, for the reason explained above.

import cyberpi
import mbot2
import utime

try:
    import usocket as socket
except ImportError:
    import socket

# ============================== CALIBRATED CONSTANTS (measured) ==============================
# Live feedback: the original (3,0)->(6,0.35) jump was too coarse -- almost all of a real "talk"
# phase's dynamic range (measured 0-18 above floor) fell inside that single 3-unit step, so soft
# vs. louder talking barely differed in speed. Two extra anchors (12, 25) spread resolution across
# that same measured range instead of jumping straight to "moderately fast."
CURVE = ((3.0, 0.0), (6.0, 0.15), (12.0, 0.35), (25.0, 0.6), (40.0, 0.85), (80.0, 1.0))
SELF_NOISE = ((0.0, 0.0), (20.0, 42.0), (40.0, 65.0), (60.0, 83.0))  # used only during
# "driving" (see header) to detect an escalation; NOT used in "listening", where motors are
# already off and subtraction isn't needed. Caveat carried from v10: measured while spinning in
# place (step12), reused here as an approximation for straight driving.
SETTLE_MS = 180  # measured motor-stop ring-down (step12); the pause before any clean read
# ==============================================================================================

# ============================== GUESSED CONSTANTS (untested -- tune live) ====================
SUSTAIN_MIN_MS = 1200  # a bare-qualifying quiet reading sustains this long -- lowered from an
# initial 3000 per live feedback ("faster"): the dominant source of felt latency in this design
# is how long a commitment holds before the next clean listen, not per-tick smoothing (there is
# none -- see header, this design holds a single locked-in reading rather than reacting per tick).
SUSTAIN_MAX_MS = 9000  # a max-level reading would sustain this long, but DRIVE_TIMEOUT_MS below
# is deliberately smaller, so a max-level commitment always gets interrupted by a turn instead of
# quietly completing its own sustain window.
DRIVE_TIMEOUT_MS = 8000
TURN_RPM = 45
TURN_MS = 1100  # paired guess with TURN_RPM for "about 180 degrees" -- no deg/s data exists yet

# THE dial for "startle and flee" vs. "just drive forward fast": a clean (motors-off) reading at
# or above STARTLE_CUTOFF is a candidate flee trigger; below it, the same loudness just drives
# forward per CURVE (whose own top anchor, 80, sits just under this on purpose -- see CURVE's
# comment). Raise this to make the robot harder to startle, lower it to make it jumpier.
STARTLE_CUTOFF = 85.0
# Secondary refinement, not the main dial above: the reading must ALSO have jumped at least this
# far above the recent baseline, so a scream that gradually climbs past STARTLE_CUTOFF drives
# fast (as intended) instead of "fleeing" every time it's simply loud. Without this, sustained
# loud screaming would trigger flee repeatedly rather than the fast-forward behavior it should.
STARTLE_JUMP_THRESHOLD = 55.0
BASELINE_ALPHA = 0.03  # how fast the recent-baseline estimate tracks ambient loudness
JUMP_RPM = 55
JUMP_MS = 300  # the startled "flinch" -- reverse hard, briefly, fixed duration regardless of how
# loud the trigger was (a flinch reads as reflexive, not proportional)
FLEE_RPM = 45
SENSOR_MAX = 100.0  # measured: real calibration readings (loud/scream bursts) topped out here
FLEE_MS_MIN = 1500  # how long the retreat lasts scales with how startling the sound was: a
FLEE_MS_MAX = 4000  # reading right at the threshold flees briefly, one at the sensor's ceiling
# flees for much longer -- "the louder the surprise, the farther it drives without slowing down."
# Speed (FLEE_RPM) stays constant either way; only distance/duration scales.

WOBBLE_RPM = 30  # a quick glance, gentler than a real TURN_RPM turn
# After fleeing, spin back around to face the direction it just ran toward (so it isn't left
# facing backward), then a few decaying alternating glances -- "did something just happen?"
# before settling back into listening. (duration_ms, spin_rpm, face_label, led_color); spin_rpm
# feeds both wheels the same signed value (drive_speed(rpm, rpm) spins in place), so its sign
# picks direction and magnitude picks speed.
RECOVER_SCHEDULE = (
    (TURN_MS, TURN_RPM, "O   O", (255, 200, 120)),  # the real ~180 -- now facing where it fled
    (220, WOBBLE_RPM, "o     .", (255, 230, 160)),  # glance right
    (220, -WOBBLE_RPM, ".     o", (255, 230, 160)),  # glance left
    (160, WOBBLE_RPM, "o     .", (255, 230, 160)),
    (160, -WOBBLE_RPM, ".     o", (255, 230, 160)),
    (120, WOBBLE_RPM, "o     .", (255, 230, 160)),  # settle, still a little rattled
)
# ==============================================================================================

LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP -- check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

MAX_RPM = 60
MIN_RPM = 10  # below this the encoder motors whine without really moving
MIN_LEVEL = 0.05  # minimum CURVE level while listening that counts as "a clear reading"

FLOOR_SEED_SAMPLES = 8
FLOOR_SEED_INTERVAL_MS = 25

# level threshold, face key, label, LED color -- highest threshold <= level wins, set once at
# commit time (not re-evaluated per tick -- there's nothing to react to mid-commitment).
# idle/listening/happy are device/rocky_agent.py's existing face vocabulary; "alert" is new.
FACES = (
    (0.0, "idle", ". _ .", (40, 40, 60)),
    (0.15, "listening", "o _ o", (0, 150, 255)),
    (0.5, "alert", "> < ", (255, 150, 0)),
    (0.85, "happy", "^ _ ^", (255, 30, 130)),
)

_state = {
    "booted": False,
    "floor": None,
    # "listening" | "driving" | "settling" | "turning" | "startled" | "recovering"
    "mode": "listening",
    "mode_start": 0,
    "return_to": "listening",  # where "settling" goes next
    "level": 0.0,
    "rpm": 0,
    "sustain_ms": 0,
    "drive_started": None,  # start of the current unbroken run of commitments, for the 8s cap
    "baseline": 0.0,
    "flee_ms": FLEE_MS_MIN,
    "recover_index": 0,
    "recover_seg_start": 0,
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


def _face_for_level(level):
    face = FACES[0]
    for candidate in FACES:
        if level >= candidate[0]:
            face = candidate
    return face


def _enter(mode, now):
    _state["mode"] = mode
    _state["mode_start"] = now


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
    _enter("listening", utime.ticks_ms())
    _show_face("o _ o", (0, 150, 255))


def _tick_listening(now):
    loudness = cyberpi.get_loudness()  # motors are off in this mode -- a clean read, no self
    external = max(0.0, loudness - _state["floor"])  # noise term needed at all
    _state["baseline"] += BASELINE_ALPHA * (external - _state["baseline"])

    startled = external >= STARTLE_CUTOFF
    startled = startled and (external - _state["baseline"]) >= STARTLE_JUMP_THRESHOLD
    if startled:
        # Surprise magnitude, 0 at the startle threshold to 1 at the sensor's observed ceiling
        # (real calibration readings topped out at 100) -- scales how far the flee goes.
        headroom = SENSOR_MAX - STARTLE_CUTOFF
        surprise = min(1.0, max(0.0, (external - STARTLE_CUTOFF) / headroom))
        _state["flee_ms"] = int(FLEE_MS_MIN + surprise * (FLEE_MS_MAX - FLEE_MS_MIN))
        _enter("startled", now)
        _show_face("O   O", (255, 255, 255))
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, round(external, 1)))
        return

    level = _interp(CURVE, external)
    if level > MIN_LEVEL:
        _state["level"] = level
        _state["rpm"] = max(MIN_RPM, int(level * MAX_RPM))
        _state["sustain_ms"] = int(SUSTAIN_MIN_MS + level * (SUSTAIN_MAX_MS - SUSTAIN_MIN_MS))
        if _state["drive_started"] is None:
            _state["drive_started"] = now
        _enter("driving", now)
        mbot2.drive_speed(_state["rpm"], -_state["rpm"])
        _show_face(*_face_for_level(level)[2:])

    _send_telemetry(',"loud":{},"external":{}'.format(loudness, round(external, 1)))


def _tick_driving(now):
    if utime.ticks_diff(now, _state["drive_started"]) >= DRIVE_TIMEOUT_MS:
        mbot2.drive_speed(0, 0)
        _state["return_to"] = "turning"
        _enter("settling", now)
        return

    loudness = cyberpi.get_loudness()
    self_noise = _interp(SELF_NOISE, _state["rpm"])
    external = max(0.0, loudness - _state["floor"] - self_noise)
    candidate_level = _interp(CURVE, external)
    if candidate_level > _state["level"]:  # louder than the current commitment -- escalate
        _state["level"] = candidate_level
        _state["rpm"] = max(MIN_RPM, int(candidate_level * MAX_RPM))
        _state["sustain_ms"] = int(
            SUSTAIN_MIN_MS + candidate_level * (SUSTAIN_MAX_MS - SUSTAIN_MIN_MS)
        )
        _state["mode_start"] = now  # escalating refreshes how long this commitment holds
        _show_face(*_face_for_level(candidate_level)[2:])
    # A quieter-or-equal reading is ignored on purpose -- the commitment holds steady rather than
    # decaying or jittering with every tick's noise.

    if utime.ticks_diff(now, _state["mode_start"]) >= _state["sustain_ms"]:
        mbot2.drive_speed(0, 0)
        _state["return_to"] = "listening"
        _state["drive_started"] = None
        _enter("settling", now)
        return
    mbot2.drive_speed(_state["rpm"], -_state["rpm"])
    _send_telemetry(',"loud":{},"external":{}'.format(loudness, round(external, 1)))


def _tick_settling(now):
    if utime.ticks_diff(now, _state["mode_start"]) < SETTLE_MS:
        _send_telemetry("")
        return
    if _state["return_to"] == "turning":
        _enter("turning", now)
        _show_face("O   O", (255, 150, 0))
    else:
        _state["level"] = 0.0
        _state["rpm"] = 0
        _enter("listening", now)
        _show_face("o _ o", (0, 150, 255))


def _tick_turning(now):
    elapsed = utime.ticks_diff(now, _state["mode_start"])
    if elapsed < TURN_MS:
        mbot2.drive_speed(TURN_RPM, TURN_RPM)  # spin in place -- guessed ~180 degrees, see header
        _send_telemetry("")
    else:
        mbot2.drive_speed(0, 0)
        _state["drive_started"] = None
        _state["return_to"] = "listening"
        _enter("settling", now)


def _tick_startled(now):
    elapsed = utime.ticks_diff(now, _state["mode_start"])
    if elapsed < JUMP_MS:
        mbot2.drive_speed(-JUMP_RPM, JUMP_RPM)  # sharp reverse jolt -- the closest analog to a
        # "jump" the mBot2 has, given it has no legs
        _send_telemetry("")
    elif elapsed < JUMP_MS + _state["flee_ms"]:
        mbot2.drive_speed(-FLEE_RPM, FLEE_RPM)  # keep retreating, at a fixed speed for the whole
        _send_telemetry("")  # duration -- "without slowing down" -- only the duration scales
    else:
        _state["baseline"] = 0.0
        _enter_recovering(now)


def _enter_recovering(now):
    _state["recover_index"] = 0
    _state["recover_seg_start"] = now
    _enter("recovering", now)
    _, _, label, color = RECOVER_SCHEDULE[0]
    _show_face(label, color)


def _tick_recovering(now):
    idx = _state["recover_index"]
    duration, rpm, _, _ = RECOVER_SCHEDULE[idx]
    if utime.ticks_diff(now, _state["recover_seg_start"]) >= duration:
        idx += 1
        if idx >= len(RECOVER_SCHEDULE):
            mbot2.drive_speed(0, 0)
            _state["return_to"] = "listening"
            _enter("settling", now)
            return
        _state["recover_index"] = idx
        _state["recover_seg_start"] = now
        duration, rpm, label, color = RECOVER_SCHEDULE[idx]
        _show_face(label, color)
    mbot2.drive_speed(rpm, rpm)  # spin in place -- sign picks direction, see RECOVER_SCHEDULE
    _send_telemetry("")


_TICKS = {
    "listening": _tick_listening,
    "driving": _tick_driving,
    "settling": _tick_settling,
    "turning": _tick_turning,
    "startled": _tick_startled,
    "recovering": _tick_recovering,
}


def tick():
    if not _state["booted"]:
        _boot()
        return

    now = utime.ticks_ms()
    try:
        _TICKS[_state["mode"]](now)
    except Exception:
        mbot2.drive_speed(0, 0)  # never let bootstrap drop this payload with motors spinning
        raise
