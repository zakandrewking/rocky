# Pushed into bootstrap.py as a payload. v3 of the loudness-driving experiment. v2
# (step06_loudness_drive_fluid.py) used a lifetime min/max to auto-range loudness -- the max only
# ever ratcheted upward, so one loud clap permanently raised the ceiling and made everything after
# it feel unresponsive ("not very sensitive").
#
# Fix: track a "leaky minimum" noise floor instead of a lifetime max. Loud sounds never affect it
# (min() with the current reading only pulls it down, never up), and it drifts back up slowly on
# its own if the room gets generally louder for a while, so it re-adapts instead of staying pinned.
# SENSITIVITY is a guess at how many loudness units above ambient counts as "full speed" -- report
# the "loud:N floor:N" numbers shown on screen for quiet vs. a clap if this still feels off, so it
# can be tuned from real numbers instead of guessed again.

import cyberpi
import mbot2
import utime

_state = {"last_update": 0, "floor": None}

SENSITIVITY = 15
FLOOR_DRIFT_PER_TICK = 0.3
MAX_RPM = 50


def tick():
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_update"]) < 100:
        return
    _state["last_update"] = now

    loudness = cyberpi.get_loudness()
    if _state["floor"] is None:
        _state["floor"] = loudness
    else:
        _state["floor"] = min(loudness, _state["floor"] + FLOOR_DRIFT_PER_TICK)

    level = max(0.0, min(1.0, (loudness - _state["floor"]) / SENSITIVITY))

    brightness = int(level * 255)
    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label(
        "loud:{} floor:{}".format(loudness, int(_state["floor"])), 12, 0, 20, 0
    )

    if level > 0.1:
        rpm = int(level * MAX_RPM)
        cyberpi.display.show_label("rpm: {}".format(rpm), 16, 10, 60, 1)
        mbot2.drive_speed(rpm, -rpm)
    else:
        mbot2.drive_speed(0, 0)
