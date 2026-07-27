"""Step 2 - does the speaker work, and how much control do we have?

Proves: audio output exists, volume is settable, and synthesized tones play.

This is the easy half of audio. It says nothing yet about whether *arbitrary*
audio (bytes we generate on a server) can reach the speaker - that is step 10.
What it does establish is a working baseline, so a failure in step 10 can be
blamed on the API rather than on a dead speaker.

EXPECTED
  - a rising tone sweep, clearly audible
  - a preset Makeblock sound ("hello")
  - the same sweep again, quieter, proving set_vol works

IF IT FAILS
  - silence at every volume: check the board is not muted by a previous program
  - tones play but the preset does not: note which preset names your firmware
    has; they vary by CyberOS version. Record the working name in STEPS.md.
"""

import time

import cyberpi

cyberpi.console.clear()
cyberpi.console.println("Rocky step 2: speaker")
print("Rocky step 2: speaker")

cyberpi.audio.set_vol(80)
cyberpi.console.println("volume: " + str(cyberpi.audio.get_vol()))

# Synthesized tones: the most primitive output the API offers.
cyberpi.console.println("tone sweep, loud")
for frequency in (262, 330, 392, 523):
    cyberpi.audio.play_tone(frequency, 0.25)
    time.sleep(0.05)

time.sleep(0.5)

# A preset file, the only file-based playback the documented API exposes.
cyberpi.console.println("preset: hello")
try:
    cyberpi.audio.play_until("hello")
    print("preset 'hello' played")
except Exception as exc:
    print("preset 'hello' failed: " + str(exc))
    cyberpi.console.println("preset FAILED")

time.sleep(0.5)

cyberpi.audio.set_vol(25)
cyberpi.console.println("tone sweep, quiet")
for frequency in (262, 330, 392, 523):
    cyberpi.audio.play_tone(frequency, 0.25)
    time.sleep(0.05)

cyberpi.audio.set_vol(80)
cyberpi.console.println("PASS if you heard 3 things")
print("PASS if you heard: loud sweep, preset, quiet sweep")
