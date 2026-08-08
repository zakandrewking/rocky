# Pushed into bootstrap.py as a payload. A different sense than step03's display/LED cycle:
# reacts to the microphone via cyberpi.get_loudness(), documented in
# apps/cyberpi/docs/cyberos-api-surface.md's audio table. Auto-ranges against the min/max seen so
# far rather than assuming a fixed scale, since the documented range isn't specified anywhere.

import cyberpi
import utime

_state = {"last_update": 0, "min_seen": 999, "max_seen": 0}


def tick():
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_update"]) < 80:
        return
    _state["last_update"] = now

    loudness = cyberpi.get_loudness()
    _state["min_seen"] = min(_state["min_seen"], loudness)
    _state["max_seen"] = max(_state["max_seen"], loudness)
    spread = max(_state["max_seen"] - _state["min_seen"], 1)
    level = (loudness - _state["min_seen"]) / spread  # 0..1, auto-ranged as louder sounds arrive
    brightness = int(level * 255)

    cyberpi.led.on(brightness, 0, 255 - brightness, id="all")
    cyberpi.display.clear()
    cyberpi.display.show_label("loud: {}".format(loudness), 16, 10, 50, 0)
