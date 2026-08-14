# Emergency payload remover -- upload via mBlock over USB (NOT via push.mjs, obviously: this
# exists for exactly the situation where the pushed payload is so broken the board wedges at
# boot and no push can land).
#
# Born from the 2026-08-13/14 incident: a payload whose _boot() called network.WLAN() hung the
# interpreter on the first tick after every power cycle, before any network client could get a
# word in. bootstrap.py exec()s /flash/rocky_payload.py from flash at startup, so power cycling
# alone can't clear a bad payload -- it just re-runs it. scripts/rescue.mjs can win the race to
# replace it (~coin flip per boot); this file is the guaranteed path when that fails.
#
# After this runs once (screen says "payload deleted"), press Home, then re-upload
# device/bootstrap.py via mBlock as usual -- it will boot with no payload, sit at
# "Ready. Push :8766", and a normal push.mjs delivers the fixed rocky_agent.py.

import os

import cyberpi

PAYLOAD_PATH = "/flash/rocky_payload.py"

cyberpi.display.clear()
cyberpi.led.on(255, 165, 0, id="all")

try:
    os.remove(PAYLOAD_PATH)
    cyberpi.display.show_label("payload deleted", 16, 0, 20, 0)
    cyberpi.led.on(0, 255, 0, id="all")
except OSError as error:
    # ENOENT means it was already gone -- also fine, the goal state is "no payload on flash."
    cyberpi.display.show_label("nothing to delete", 16, 0, 20, 0)
    cyberpi.display.show_label(str(error), 10, 0, 44, 1)
    cyberpi.led.on(0, 0, 255, id="all")

cyberpi.display.show_label("press Home, re-upload", 10, 0, 70, 2)
cyberpi.display.show_label("bootstrap via mBlock", 10, 0, 84, 3)

while True:
    pass  # keep the message on screen; Home button exits, per STEPS.md's upload discipline
