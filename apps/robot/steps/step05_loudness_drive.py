# Pushed into bootstrap.py as a payload. First motor test in apps/robot -- doubles as an
# unplanned but real data point for STEPS.md step 8 (drive_speed sign convention), since nobody
# has calibrated direction yet. Kept deliberately short/slow/self-limiting: each loud moment
# drives one brief low-speed burst, never a sustained drive, so whichever way it actually goes
# it's a small nudge, not a runaway.

import cyberpi
import mbot2
import utime

_state = {"last_update": 0, "min_seen": 999, "max_seen": 0}

LOUD_THRESHOLD = 0.55  # fraction of the auto-ranged min..max loudness spread
DRIVE_RPM = 30
DRIVE_BURST_MS = 150


def tick():
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_update"]) < 150:
        return
    _state["last_update"] = now

    loudness = cyberpi.get_loudness()
    _state["min_seen"] = min(_state["min_seen"], loudness)
    _state["max_seen"] = max(_state["max_seen"], loudness)
    spread = max(_state["max_seen"] - _state["min_seen"], 1)
    level = (loudness - _state["min_seen"]) / spread

    brightness = int(max(0, min(1, level)) * 255)
    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label("loud: {}".format(loudness), 16, 10, 30, 0)

    if level > LOUD_THRESHOLD:
        cyberpi.display.show_label("DRIVE!", 16, 10, 60, 1)
        mbot2.drive_speed(DRIVE_RPM, -DRIVE_RPM)
        utime.sleep_ms(DRIVE_BURST_MS)
        mbot2.drive_speed(0, 0)
