# Pushed into bootstrap.py as a payload. v4 of the loudness-driving experiment.
#
# v3 (step07) got "locked in" at max speed: its own motor noise is loud enough for the microphone
# to pick up, so once it started driving, it heard itself as "loud" and kept driving -- a real
# acoustic feedback loop, not a math bug. The floor-drift fix from v3 was solving a different
# problem (a lifetime-max ceiling) and doesn't help here, because the elevated reading during
# driving is real, not stale.
#
# Fix: never sample the microphone while the motors are running. Alternate short listen and drive
# phases so they never overlap in time -- listen (mic only, motors off), decide, drive briefly
# (motors only, no mic reads), stop, listen again.

import cyberpi
import mbot2
import utime

_state = {"phase": "listen", "phase_start": 0, "floor": None}

LISTEN_MS = 300
DRIVE_MS = 200
SENSITIVITY = 15
FLOOR_DRIFT_PER_TICK = 0.3
MAX_RPM = 50
NOISE_FLOOR_LEVEL = 0.1


def tick():
    now = utime.ticks_ms()
    elapsed = utime.ticks_diff(now, _state["phase_start"])

    if _state["phase"] == "listen":
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

        if elapsed >= LISTEN_MS:
            if level > NOISE_FLOOR_LEVEL:
                rpm = int(level * MAX_RPM)
                cyberpi.display.show_label("rpm: {}".format(rpm), 16, 10, 60, 1)
                mbot2.drive_speed(rpm, -rpm)
                _state["phase"] = "drive"
            _state["phase_start"] = now  # restart the listen window either way

    else:  # driving -- motors only, no mic reads until this phase ends
        if elapsed >= DRIVE_MS:
            mbot2.drive_speed(0, 0)
            _state["phase"] = "listen"
            _state["phase_start"] = now
