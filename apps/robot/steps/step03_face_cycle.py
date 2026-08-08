# Pushed into bootstrap.py as a payload -- see apps/robot/PLAN.md Phase 5 ("Face + personality").
# Not a real step in the test sense; a small, safe (no motors) proof that the OTA loop can push
# something genuinely fun, not just a counter. Cycles through the same face states rocky_agent.py
# plans to drive from tool calls, so this is a preview of that with zero calibration risk.

import cyberpi
import utime

_faces = [
    ("idle", ". _ .", (60, 60, 60)),
    ("listening", "o _ o", (0, 150, 255)),
    ("thinking", ". ~ .", (255, 200, 0)),
    ("speaking", ". o .", (0, 255, 120)),
    ("happy", "^ _ ^", (255, 80, 200)),
]

_state = {"index": 0, "last_change": 0}


def tick():
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_change"]) < 900:
        return
    _state["last_change"] = now

    _name, label, color = _faces[_state["index"]]
    _state["index"] = (_state["index"] + 1) % len(_faces)

    cyberpi.display.clear()
    cyberpi.display.show_label(label, 32, 30, 50, 0)
    cyberpi.led.on(color[0], color[1], color[2], id="all")
