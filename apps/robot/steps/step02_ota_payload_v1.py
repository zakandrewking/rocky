# apps/robot STEPS.md, step 6 (bootstrap.py's payload protocol, v1).
#
# Not run standalone -- pushed into a running bootstrap.py via apps/robot/scripts/push.mjs, which
# writes it to bootstrap.py's PAYLOAD_PATH and reloads it. Proves the reload cycle end to end
# before trusting anything more complex: bootstrap calls tick() once per loop iteration, so this
# just counts ticks and shows the count, with a visible "v1" marker so a second push (step 3,
# v2) is distinguishable on screen without any doubt about whether the new code actually took.

import cyberpi
import utime

_state = {"count": 0, "last_shown": 0}


def tick():
    # bootstrap.py's loop has no built-in delay (it's busy-polling the push socket), so this
    # throttles the display update itself rather than assuming the caller paces tick() calls.
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _state["last_shown"]) < 500:
        return
    _state["last_shown"] = now
    _state["count"] += 1
    cyberpi.display.show_label("payload v1: {}".format(_state["count"]), 12, 0, 40, 2)
