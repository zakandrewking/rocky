"""Step 1 - does the toolchain work at all?

Proves: mBlock can upload a program, it runs standalone on the CyberPi, the
screen draws, the LEDs light, and the serial console is readable.

Nothing else in this directory is worth trying until this passes.

HOW TO RUN
  1. Connect the CyberPi over USB and open mBlock 5.
  2. Switch the editor to Python, and switch the mode toggle to **Upload**.
  3. Paste this file in, click Upload, and watch the board.

EXPECTED
  - screen shows "Rocky step 1" and a counter climbing 1..5
  - the 5 LEDs turn green
  - the serial console prints the same counter

IF IT FAILS
  - nothing on screen: the board is in Live mode, not Upload mode
  - upload button greyed out: no board selected, or the USB cable is charge-only
  - board resets mid-run: low battery, or the mBot2 shield is drawing power
"""

import time

import cyberpi

cyberpi.console.clear()
cyberpi.display.set_brush(0, 255, 0)
cyberpi.console.println("Rocky step 1")
print("Rocky step 1: toolchain check")

cyberpi.led.on(0, 60, 0)

for count in range(1, 6):
    cyberpi.console.println("tick " + str(count))
    print("tick " + str(count))
    time.sleep(1)

cyberpi.console.println("PASS - toolchain works")
print("PASS - toolchain works")
cyberpi.led.on(0, 0, 60)
