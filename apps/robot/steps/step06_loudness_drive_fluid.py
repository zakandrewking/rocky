# Pushed into bootstrap.py as a payload. v2 of step05_loudness_drive.py: that one only drove in
# fixed-size bursts above a threshold, so it felt binary rather than volume-proportional. This
# sets speed continuously every tick instead of a burst+sleep+stop, so it scales smoothly with
# loudness and decays back to a stop within one tick of things going quiet -- no fixed-duration
# drive that could outlast the sound that triggered it.
#
# Direction confirmed from step05's run: drive_speed(+RPM, -RPM) moves it forward.

import cyberpi
import mbot2
import utime

_state = {"last_update": 0, "min_seen": 999, "max_seen": 0}

NOISE_FLOOR = 0.15  # below this fraction of the auto-ranged spread, treat as silence and stop
MAX_RPM = 50


def tick():
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_update"]) < 100:
        return
    _state["last_update"] = now

    loudness = cyberpi.get_loudness()
    _state["min_seen"] = min(_state["min_seen"], loudness)
    _state["max_seen"] = max(_state["max_seen"], loudness)
    spread = max(_state["max_seen"] - _state["min_seen"], 1)
    level = max(0.0, min(1.0, (loudness - _state["min_seen"]) / spread))

    brightness = int(level * 255)
    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label("loud: {}".format(loudness), 16, 10, 30, 0)

    if level > NOISE_FLOOR:
        rpm = int(level * MAX_RPM)
        cyberpi.display.show_label("rpm: {}".format(rpm), 16, 10, 60, 1)
        mbot2.drive_speed(rpm, -rpm)
    else:
        mbot2.drive_speed(0, 0)
