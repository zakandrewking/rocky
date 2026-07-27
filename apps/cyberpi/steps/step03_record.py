"""Step 3 - does the microphone work, and how does recording actually behave?

Proves: cyberpi.audio.record() / stop_record() / play_record() do what the docs
say, and measures how long the round trip takes.

Watch for two things beyond "did I hear myself":

  1. **Timing.** The gap between stop_record() and audible playback is the floor
     on any turn-based Rocky. If it is already half a second, add network and
     model time on top and the conversation will feel slow.
  2. **The second recording.** The API has one internal slot. This step records
     twice to confirm the second overwrites the first, which is what makes
     streaming impossible: you cannot hold audio while capturing more.

EXPECTED
  - "speak now" appears, you talk for 3 seconds, you hear yourself back
  - the second recording plays back, and the first is gone

IF IT FAILS
  - playback is silent: the mic may need a louder source; try again close up
  - play_record raises: note the exact error in STEPS.md, it tells us how the
    slot is implemented
"""

import time

import cyberpi


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


RECORD_SECONDS = 3

cyberpi.console.clear()
cyberpi.console.println("Rocky step 3: microphone")
print("Rocky step 3: microphone")
cyberpi.audio.set_vol(80)

# --- first recording -------------------------------------------------------
cyberpi.led.on(60, 0, 0)
cyberpi.console.println("SPEAK NOW (say 'one')")
cyberpi.audio.record()
time.sleep(RECORD_SECONDS)
cyberpi.audio.stop_record()
cyberpi.led.off()

stopped_at = ticks_ms()
cyberpi.console.println("playing back...")
cyberpi.audio.play_record_until()
playback_ms = elapsed_since(stopped_at)

print("first playback took " + str(playback_ms) + " ms for a " + str(RECORD_SECONDS) + " s recording")
cyberpi.console.println("took " + str(playback_ms) + " ms")

time.sleep(1)

# --- second recording, to see whether the slot is reusable -----------------
cyberpi.led.on(60, 0, 0)
cyberpi.console.println("SPEAK NOW (say 'two')")
cyberpi.audio.record()
time.sleep(RECORD_SECONDS)
cyberpi.audio.stop_record()
cyberpi.led.off()

cyberpi.console.println("playing back #2...")
cyberpi.audio.play_record_until()

cyberpi.console.println("did you hear 'two'?")
print("If the second playback said 'two', the slot is single-buffered:")
print("recording again destroys the previous audio. That rules out streaming.")
