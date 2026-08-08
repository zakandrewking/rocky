# Pushed into bootstrap.py as a payload. v5 of the loudness-driving experiment.
#
# v4 (step08) avoided the self-noise feedback loop by never listening while driving, but that
# means the mic and the motors are always time-sliced apart -- stuttery, and it can't react while
# actually moving. This instead models self-noise directly: assume it's roughly proportional to
# RPM (louder wheels at higher speed), learn the proportionality constant K from one brief,
# low-speed probe (not a full-speed run -- the probe itself is quiet), and subtract the predicted
# self-noise for whatever RPM is currently commanded from every live loudness reading. What's left
# is (an estimate of) real external sound, usable while the motors are running.

import cyberpi
import mbot2
import utime

_state = {
    "last_update": 0,
    "ambient_floor": None,
    "k": 0.0,
    "calibrated": False,
    "last_calibration": 0,
    "rpm": 0,
}

TEST_RPM = 20  # a brief, quiet probe speed -- just enough to measure a slope, not "fast"
PROBE_MS = 120
SENSITIVITY = 12
MAX_RPM = 50
NOISE_FLOOR_LEVEL = 0.1
RECALIBRATE_EVERY_MS = 8000


def calibrate():
    quiet = cyberpi.get_loudness()
    mbot2.drive_speed(TEST_RPM, -TEST_RPM)
    utime.sleep_ms(PROBE_MS)
    loud_while_driving = cyberpi.get_loudness()
    mbot2.drive_speed(0, 0)

    _state["ambient_floor"] = quiet
    _state["k"] = max(0, loud_while_driving - quiet) / TEST_RPM
    _state["calibrated"] = True
    _state["last_calibration"] = utime.ticks_ms()


def tick():
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_update"]) < 100:
        return
    _state["last_update"] = now

    if not _state["calibrated"]:
        cyberpi.display.clear()
        cyberpi.display.show_label("calibrating...", 12, 0, 0, 0)
        calibrate()
        return

    # Only ever re-probe while already stopped, so calibration never interrupts real driving.
    if _state["rpm"] == 0 and utime.ticks_diff(now, _state["last_calibration"]) > RECALIBRATE_EVERY_MS:
        calibrate()

    loudness = cyberpi.get_loudness()
    predicted_self_noise = _state["ambient_floor"] + _state["k"] * _state["rpm"]
    external = max(0.0, loudness - predicted_self_noise)

    level = max(0.0, min(1.0, external / SENSITIVITY))
    rpm = int(level * MAX_RPM) if level > NOISE_FLOOR_LEVEL else 0
    _state["rpm"] = rpm
    mbot2.drive_speed(rpm, -rpm)

    brightness = int(level * 255)
    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label(
        "L:{} self:{} ext:{}".format(loudness, int(predicted_self_noise), int(external)), 10, 0, 10, 0
    )
    cyberpi.display.show_label("k100:{} rpm:{}".format(int(_state["k"] * 100), rpm), 10, 0, 30, 1)
