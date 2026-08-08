# Pushed into bootstrap.py as a payload. v7 of the loudness-driving experiment.
#
# Root cause of v6's "can't pick up speed even when talking loud continuously": its calibrate()
# blindly trusted whatever loudness it sampled *at that instant* as the new ambient floor. Forced
# recalibration during a sustained scream sampled the scream itself as "quiet," permanently
# raising the floor -- so the longer she screamed, the less sensitive it got. That's backwards.
#
# This drops the self-noise model entirely and goes back to listen/drive alternation (like
# step08), but tuned for the actual expected use: a scream lasting up to ~10-15s should hit max
# speed fast and stay there; quieter sustained "light moaning" afterward should track
# proportionally lower. Key fix: the floor can only ever be *lowered* by a genuinely quiet
# reading (min()), never raised by a loud one -- a scream can't corrupt it the way v6's
# calibrate() could. Listen windows are short (80ms, motors off, clean mic read) and drive windows
# are long (500ms) relative to them, so it's ~85% duty-cycle driving, not the stop-heavy feel of
# earlier versions -- each listen window re-measures fresh, so a sustained loud sound gets
# reconfirmed as loud (and stays at max rpm) every ~580ms cycle rather than decaying away.

import cyberpi
import mbot2
import utime

_state = {"phase": "listen", "phase_start": 0, "floor": None, "rpm": 0}

LISTEN_MS = 80
DRIVE_MS = 500
FLOOR_DRIFT_PER_LISTEN = 0.05
SENSITIVITY = 10  # external units above floor that count as "full speed" -- a scream should
                   # blow well past this fast; light moaning should sit partway up the range
MAX_RPM = 60
NOISE_FLOOR_LEVEL = 0.08


def tick():
    now = utime.ticks_ms()
    elapsed = utime.ticks_diff(now, _state["phase_start"])

    if _state["phase"] == "listen":
        loudness = cyberpi.get_loudness()
        if _state["floor"] is None:
            _state["floor"] = loudness
        else:
            _state["floor"] = min(loudness, _state["floor"] + FLOOR_DRIFT_PER_LISTEN)

        level = max(0.0, min(1.0, (loudness - _state["floor"]) / SENSITIVITY))
        _state["rpm"] = int(level * MAX_RPM) if level > NOISE_FLOOR_LEVEL else 0

        brightness = int(level * 255)
        cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
        cyberpi.display.clear()
        cyberpi.display.show_label(
            "loud:{} floor:{}".format(loudness, int(_state["floor"])), 10, 0, 10, 0
        )
        cyberpi.display.show_label("rpm:{}".format(_state["rpm"]), 10, 0, 30, 1)

        if elapsed >= LISTEN_MS:
            _state["phase"] = "drive"
            _state["phase_start"] = now
            if _state["rpm"] > 0:
                mbot2.drive_speed(_state["rpm"], -_state["rpm"])
            else:
                mbot2.drive_speed(0, 0)

    else:  # driving at the last-measured speed; no mic reads until this window ends
        if elapsed >= DRIVE_MS:
            mbot2.drive_speed(0, 0)  # brief stop for the next clean listen window
            _state["phase"] = "listen"
            _state["phase_start"] = now
