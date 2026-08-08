# Pushed into bootstrap.py as a payload. v8 of the loudness-driving experiment -- the first one
# built on measured numbers instead of guessed constants. See
# docs/loudness-drive-problem-statement.md for why v1-v7 fell short; the short version:
#
#   - v3 fed back on its own motor noise -> keep v4/v7's listen/drive alternation (mic is only
#     read with motors off).
#   - v6 corrupted its floor by recalibrating mid-scream -> keep v7's leaky-min floor, which a
#     loud reading can never raise (only a genuinely quiet reading lowers it; upward drift is
#     capped at FLOOR_DRIFT_PER_LISTEN per cycle, ~1 unit over a 15s scream).
#   - v7 felt binary because its guessed SENSITIVITY made any real sound saturate -> the mapping
#     below is a piecewise-linear CURVE through anchors measured by
#     steps/step12_loudness_calibration.py, so "talking" and "screaming" land at genuinely
#     different speeds whether get_loudness() is linear or logarithmic.
#   - v7 read the mic 0ms after motor-stop (suspected ring-down contamination) -> SETTLE_MS,
#     measured by step12's ring-down probe, sits between motor-stop and the mic read.
#
# New in v8: attack/release smoothing between listen windows (a scream ramps to max within ~2
# cycles and decays smoothly instead of snapping), and live telemetry -- every listen window's
# numbers stream to scripts/telemetry.mjs if it's running, so tuning happens on logged data
# instead of squinting at the 128x128 screen. If the laptop isn't listening, it drives fine
# standalone.
#
import cyberpi
import mbot2
import utime

try:
    import usocket as socket
except ImportError:
    import socket

# ============================== CALIBRATED CONSTANTS =========================================
# Base values from a real calibration run (2026-08-08,
# local-data/robot-telemetry/2026-08-08T20-40-13-496Z.jsonl) via
# steps/step12_loudness_calibration.py + scripts/analyze-calibration.mjs -- not hand-tuned by
# feel, the v1-v7 mistake this file exists to end. The run surfaced something v1-v7 never
# measured: loud speech and screaming are bursty, not steady tones (words/breaths), so anchors
# are taken at each phase's 75th+ percentile -- "the level reached while actually making the
# sound" -- not the median, which lands in the gaps between bursts. See
# analyze-calibration.mjs's ANCHOR_PERCENTILES comment for why.
#
# The top two anchors were then retuned against a live real-time test (same day, watching
# telemetry while talking/driving): the calibration-only curve put loudness 40-50 at only
# ~0.5-0.6 speed, which felt too slow against the stated expectation that ~40-50 should drive
# "pretty fast and reliably forward." Correction after a second look: max speed should still be
# reserved for the *measured* "loud" level (delta 80, its 75th percentile -- see above), not
# handed out at 50. So 40 lands at "pretty fast but not maxed" (0.85) and true max (1.0) waits
# for 80, the real loud-talking anchor -- reconciling both pieces of live feedback instead of
# just the first. Deliberate, data-informed adjustments made while watching live numbers -- not
# blind guesses -- but if the feel drifts again, retune this pair against fresh telemetry rather
# than re-guessing from scratch.
SETTLE_MS = 180
CURVE = ((3.0, 0.0), (6.0, 0.35), (40.0, 0.85), (80.0, 1.0))  # (loudness above floor, level)
FLOOR_REF = 0.0  # calibration session's ambient median; only used for a startup sanity display
# ==============================================================================================

LAPTOP_HOST = "192.168.1.138"  # telemetry (optional); check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

DRIVE_MS = 500
FLOOR_DRIFT_PER_LISTEN = 0.05
MAX_RPM = 60
MIN_RPM = 10  # below this the encoder motors whine without really moving; snap to it or to 0
MIN_LEVEL = 0.05
ATTACK = 0.7  # smoothing per listen window when the sound got louder (fast: screams register)
RELEASE = 0.25  # ...and when it got quieter (slower: no snapping to zero between breaths)

_state = {
    "phase": "listen",
    "phase_start": 0,
    "floor": None,
    "level": 0.0,
    "rpm": 0,
    "sock": None,
    "sock_tried": False,
}


def _level_for(delta):
    """Piecewise-linear interpolation through the measured CURVE anchors."""
    if delta <= CURVE[0][0]:
        return 0.0
    for index in range(1, len(CURVE)):
        x0, y0 = CURVE[index - 1]
        x1, y1 = CURVE[index]
        if delta <= x1:
            return y0 + (y1 - y0) * (delta - x0) / (x1 - x0)
    return 1.0


def _connect_telemetry():
    """One attempt, bounded; driving must work with no laptop listening."""
    _state["sock_tried"] = True
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((LAPTOP_HOST, LAPTOP_PORT))
        sock.settimeout(2)
        _state["sock"] = sock
    except Exception:
        _state["sock"] = None


def _send_raw(line):
    if _state["sock"] is None:
        return
    try:
        _state["sock"].sendall((line + "\n").encode())
    except Exception:
        try:
            _state["sock"].close()
        except Exception:
            pass
        _state["sock"] = None  # laptop went away; keep driving standalone


def _send_telemetry(loudness):
    _send_raw(
        '{{"t":{},"phase":"live","loud":{},"floor":{},"level":{},"rpm":{}}}'.format(
            utime.ticks_ms(), loudness, _state["floor"], round(_state["level"], 3), _state["rpm"]
        )
    )


def _send_telemetry_event(fields_json):
    """fields_json: a JSON object literal (with braces) of event-specific fields; gets a
    timestamp merged in."""
    _send_raw('{{"t":{},{}'.format(utime.ticks_ms(), fields_json[1:]))


def _listen_once(now):
    loudness = cyberpi.get_loudness()

    if _state["floor"] is None:
        _state["floor"] = loudness
        # One-time sanity check: how far has ambient noise drifted from the calibration
        # session's floor? A big drift means CURVE's anchors (measured as deltas above THAT
        # session's floor) may need a fresh calibration run, not a code change.
        _send_telemetry_event(
            '{{"event":"floor_check","floor":{},"floor_ref":{},"drift":{}}}'.format(
                loudness, FLOOR_REF, round(loudness - FLOOR_REF, 1)
            )
        )
    else:
        _state["floor"] = min(loudness, _state["floor"] + FLOOR_DRIFT_PER_LISTEN)

    raw = _level_for(loudness - _state["floor"])
    alpha = ATTACK if raw > _state["level"] else RELEASE
    _state["level"] += alpha * (raw - _state["level"])
    _state["rpm"] = (
        max(MIN_RPM, int(_state["level"] * MAX_RPM)) if _state["level"] > MIN_LEVEL else 0
    )

    _send_telemetry(loudness)

    brightness = int(_state["level"] * 255)
    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label(
        "loud:{} floor:{}".format(loudness, int(_state["floor"])), 10, 0, 10, 0
    )
    cyberpi.display.show_label(
        "lvl:{} rpm:{}".format(round(_state["level"], 2), _state["rpm"]), 10, 0, 30, 1
    )

    _state["phase"] = "drive"
    _state["phase_start"] = now
    if _state["rpm"] > 0:
        mbot2.drive_speed(_state["rpm"], -_state["rpm"])  # forward, per the confirmed convention
    else:
        mbot2.drive_speed(0, 0)


def tick():
    if not _state["sock_tried"]:
        _connect_telemetry()

    now = utime.ticks_ms()
    elapsed = utime.ticks_diff(now, _state["phase_start"])

    try:
        if _state["phase"] == "listen":
            _listen_once(now)
        elif _state["phase"] == "drive":
            if elapsed >= DRIVE_MS:
                mbot2.drive_speed(0, 0)
                if _state["rpm"] > 0:
                    # Motors were actually spinning: wait out the measured ring-down first.
                    _state["phase"] = "settle"
                else:
                    _state["phase"] = "listen"  # nothing was moving; the mic is already clean
                _state["phase_start"] = now
        else:  # settle: motors off, waiting for mechanical ringing to die down
            if elapsed >= SETTLE_MS:
                _state["phase"] = "listen"
                _state["phase_start"] = now
    except Exception:
        mbot2.drive_speed(0, 0)  # never let bootstrap drop this payload with motors spinning
        raise
