# Pushed into bootstrap.py as a payload. v6 of the loudness-driving experiment.
#
# v5 (step09) only recalibrates while stopped (rpm == 0), which has a real deadlock risk: if the
# self-noise model underestimates, "external" reads artificially high forever, rpm never drops to
# 0, and recalibration -- the only thing that could fix the bad model -- never gets to run. Real
# user sound also comes in bursts, not one continuous tone, so a burst-triggered drive could
# easily outlast the burst on a slightly-off model and never naturally stop on its own.
#
# Fix: force a stop after MAX_CONTINUOUS_DRIVE_MS of continuous driving regardless of what the
# (possibly wrong) external-level estimate says, then immediately recalibrate. This is a safety
# valve independent of the very quantity it's correcting for -- it can't get stuck the way a
# purely level-triggered stop can.

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
    "driving_since": None,
}

TEST_RPM = 20
PROBE_MS = 120
SENSITIVITY = 12
MAX_RPM = 50
NOISE_FLOOR_LEVEL = 0.1
RECALIBRATE_EVERY_MS = 8000
MAX_CONTINUOUS_DRIVE_MS = 1500


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


def stop():
    mbot2.drive_speed(0, 0)
    _state["rpm"] = 0
    _state["driving_since"] = None


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

    if _state["rpm"] > 0:
        if _state["driving_since"] is None:
            _state["driving_since"] = now
        elif utime.ticks_diff(now, _state["driving_since"]) > MAX_CONTINUOUS_DRIVE_MS:
            stop()
            calibrate()  # forced stop is exactly when a stale/wrong model most needs correcting
            return
    elif utime.ticks_diff(now, _state["last_calibration"]) > RECALIBRATE_EVERY_MS:
        calibrate()

    loudness = cyberpi.get_loudness()
    predicted_self_noise = _state["ambient_floor"] + _state["k"] * _state["rpm"]
    external = max(0.0, loudness - predicted_self_noise)

    level = max(0.0, min(1.0, external / SENSITIVITY))
    rpm = int(level * MAX_RPM) if level > NOISE_FLOOR_LEVEL else 0
    if rpm == 0:
        stop()
    else:
        _state["rpm"] = rpm
        mbot2.drive_speed(rpm, -rpm)

    brightness = int(level * 255)
    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label(
        "L:{} self:{} ext:{}".format(loudness, int(predicted_self_noise), int(external)),
        10, 0, 10, 0,
    )
    cyberpi.display.show_label("k100:{} rpm:{}".format(int(_state["k"] * 100), rpm), 10, 0, 30, 1)
