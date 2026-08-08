# Pushed into bootstrap.py as a payload. The deliberate calibration pass that
# docs/loudness-drive-problem-statement.md said must happen before any more mapping guesses:
# seven live payload versions (step05-step11) all picked sensitivity constants by feel, because
# nobody had ever seen a real get_loudness() number for quiet vs. talk vs. scream. This gathers
# those numbers on purpose and streams every sample to the laptop, where
# scripts/telemetry.mjs logs them and scripts/analyze-calibration.mjs turns them into constants.
#
# Run order (LED color tells the person what to do even if the screen is too small to read):
#   1. Voice phases, robot stationary  -- ORANGE = get ready (3s), RED = recording (6s):
#        ambient (stay quiet), talk (normal voice), loud (loud voice), scream (scream)
#   2. Motor phases, person stays QUIET -- for each of a few RPMs: 3s warning, then 5s of the
#      robot spinning in place while sampling its own self-noise. Spinning (drive_speed(r, r)),
#      not driving forward (drive_speed(r, -r)): the motors turn at the same speed either way so
#      the self-noise should match, and a robot that stays put can't hit a wall during an
#      unattended 5s run.
#   3. After each motor phase: stop, then a tight ~1.2s ring-down probe sampling every ~10ms --
#      this answers the open question of how long after motor-stop a mic reading can be trusted
#      (v7 read the mic 0ms after stopping; mechanical ringing was a suspected but untested
#      contaminator).
#   GREEN = done.
#
# Safety properties, learned the hard way across v1-v7:
#   - Every socket op has a timeout, so a dead/absent laptop listener degrades to an on-screen
#     error instead of blocking tick() forever (which would freeze bootstrap.py's push listener --
#     the one thing that must never happen, per PLAN.md's OTA design).
#   - Any unexpected exception stops the motors before re-raising, because bootstrap.py drops a
#     crashing payload without knowing it left motors spinning.
#
# Before pushing: set LAPTOP_HOST to this Mac's LAN IP and start the listener first:
#   node apps/robot/scripts/telemetry.mjs
#   node apps/robot/scripts/push.mjs <board-ip> apps/robot/steps/step12_loudness_calibration.py

import cyberpi
import mbot2
import utime

try:
    import usocket as socket
except ImportError:
    import socket

LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP -- check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

PROMPT_MS = 3000
VOICE_MS = 6000
MOTOR_MS = 5000
SETTLE_SAMPLES = 120
SETTLE_INTERVAL_MS = 10
MOTOR_RPMS = (20, 40, 60)

VOICE_PHASES = (
    ("ambient", "QUIET please"),
    ("talk", "TALK normally"),
    ("loud", "Be LOUD"),
    ("scream", "SCREAM!"),
)


def _build_schedule():
    schedule = []
    for label, text in VOICE_PHASES:
        schedule.append({"kind": "prompt", "label": label, "text": text})
        schedule.append({"kind": "voice", "label": label})
    for rpm in MOTOR_RPMS:
        schedule.append(
            {"kind": "prompt", "label": "motor{}".format(rpm), "text": "QUIET, motors on"}
        )
        schedule.append({"kind": "motor", "label": "motor{}".format(rpm), "rpm": rpm})
        schedule.append({"kind": "settle", "label": "settle{}".format(rpm), "rpm": rpm})
    schedule.append({"kind": "done"})
    return schedule


_state = {
    "sock": None,
    "schedule": _build_schedule(),
    "index": -1,  # -1 = not connected yet; advance() moves to 0
    "item_start": 0,
    "failed": False,
}


def _send_line(line):
    """Send one newline-terminated telemetry line; on failure, fail the whole run safely."""
    if _state["sock"] is None:
        return
    try:
        _state["sock"].sendall((line + "\n").encode())
    except Exception:
        _fail("telemetry send failed")


def _send_sample(label, loudness, rpm, extra=""):
    _send_line(
        '{{"t":{},"phase":"{}","loud":{},"rpm":{}{}}}'.format(
            utime.ticks_ms(), label, loudness, rpm, extra
        )
    )


def _fail(message):
    mbot2.drive_speed(0, 0)
    _state["failed"] = True
    if _state["sock"] is not None:
        try:
            _state["sock"].close()
        except Exception:
            pass
        _state["sock"] = None
    cyberpi.display.clear()
    cyberpi.led.on(255, 0, 0, id="all")
    cyberpi.display.show_label("CALIBRATION FAILED", 12, 0, 20, 1)
    cyberpi.display.show_label(message, 12, 0, 40, 2)


def _connect():
    cyberpi.display.clear()
    cyberpi.led.on(255, 165, 0, id="all")
    cyberpi.display.show_label("Calibration", 12, 0, 0, 0)
    cyberpi.display.show_label("-> {}:{}".format(LAPTOP_HOST, LAPTOP_PORT), 12, 0, 20, 1)
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect((LAPTOP_HOST, LAPTOP_PORT))
        _state["sock"] = sock
    except Exception:
        _fail("laptop unreachable")
        return False
    _send_line('{{"event":"start","t":{}}}'.format(utime.ticks_ms()))
    return True


def _advance(now):
    _state["index"] += 1
    _state["item_start"] = now
    item = _state["schedule"][_state["index"]]

    cyberpi.display.clear()
    if item["kind"] == "prompt":
        cyberpi.led.on(255, 165, 0, id="all")
        cyberpi.display.show_label("GET READY:", 12, 0, 0, 0)
        cyberpi.display.show_label(item["text"], 16, 0, 30, 2)
    elif item["kind"] == "voice":
        cyberpi.led.on(255, 0, 0, id="all")
        cyberpi.display.show_label("RECORDING", 16, 0, 0, 0)
        cyberpi.display.show_label(item["label"], 16, 0, 30, 2)
    elif item["kind"] == "motor":
        cyberpi.led.on(255, 0, 255, id="all")
        cyberpi.display.show_label("MOTORS - stay quiet", 12, 0, 0, 0)
        cyberpi.display.show_label("rpm {}".format(item["rpm"]), 16, 0, 30, 2)
        mbot2.drive_speed(item["rpm"], item["rpm"])  # spin in place, see header
    elif item["kind"] == "settle":
        cyberpi.display.show_label("ring-down probe", 12, 0, 0, 0)
    elif item["kind"] == "done":
        mbot2.drive_speed(0, 0)
        _send_line('{{"event":"done","t":{}}}'.format(utime.ticks_ms()))
        if _state["sock"] is not None:
            try:
                _state["sock"].close()
            except Exception:
                pass
            _state["sock"] = None
        cyberpi.led.on(0, 255, 0, id="all")
        cyberpi.display.show_label("CALIBRATION DONE", 12, 0, 20, 1)
        cyberpi.display.show_label("see laptop log", 12, 0, 40, 2)


def _run_settle_probe(item):
    """Stop the motors, then sample every ~10ms for ~1.2s to catch mechanical ring-down.

    Blocking on purpose (a bounded ~1.2s): the 10ms cadence matters here, and tick()'s normal
    ~20Hz call rate (set by bootstrap.py's 50ms accept timeout) is too coarse. Samples are
    buffered and sent afterwards so socket latency can't stretch the cadence.
    """
    mbot2.drive_speed(0, 0)
    stop_at = utime.ticks_ms()
    samples = []
    for _ in range(SETTLE_SAMPLES):
        samples.append((utime.ticks_diff(utime.ticks_ms(), stop_at), cyberpi.get_loudness()))
        utime.sleep_ms(SETTLE_INTERVAL_MS)
    for since_stop, loudness in samples:
        _send_sample(item["label"], loudness, item["rpm"], ',"since_stop":{}'.format(since_stop))


def tick():
    if _state["failed"]:
        return
    now = utime.ticks_ms()

    if _state["index"] < 0:
        if _connect():
            _advance(now)
        return

    item = _state["schedule"][_state["index"]]
    elapsed = utime.ticks_diff(now, _state["item_start"])

    try:
        if item["kind"] == "prompt":
            if elapsed >= PROMPT_MS:
                _advance(now)
        elif item["kind"] == "voice":
            _send_sample(item["label"], cyberpi.get_loudness(), 0)
            if elapsed >= VOICE_MS:
                _advance(now)
        elif item["kind"] == "motor":
            _send_sample(item["label"], cyberpi.get_loudness(), item["rpm"])
            if elapsed >= MOTOR_MS:
                _advance(now)
        elif item["kind"] == "settle":
            _run_settle_probe(item)
            _advance(utime.ticks_ms())
        # "done": nothing to do; stay idle so the next payload can be pushed
    except Exception:
        mbot2.drive_speed(0, 0)  # never let bootstrap drop this payload with motors spinning
        raise
