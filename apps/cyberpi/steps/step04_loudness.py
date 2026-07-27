"""Step 4 - how fast can we read the microphone envelope?

get_loudness() is the only continuously readable microphone value CyberOS
offers. It is a single scalar, not samples, so it can never carry speech. But
its polling rate decides two real things:

  - **Voice activity detection.** Knowing when someone starts and stops talking
    needs maybe 20-50 readings per second. If we get that, Rocky can at least
    take turns without a button.
  - **Mouth animation.** The plan's "animate mouth from playback amplitude"
    needs roughly the same rate.

It also tells us about the scheduler. If a tight Python loop only manages a
handful of reads per second, the runtime is far too slow for anything realtime,
and that finding matters more than the loudness number itself.

EXPECTED
  - a sample rate printed in Hz
  - a live bar that tracks your voice for 10 seconds

IF IT FAILS
  - under 20 Hz: VAD is not viable, Rocky needs a push-to-talk button
  - the value never changes: get_loudness may need a different mode string;
    try "maximum" and "average" and record which one moves
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


cyberpi.console.clear()
cyberpi.console.println("Rocky step 4: loudness")
print("Rocky step 4: loudness polling rate")

# --- how many reads per second can we get? --------------------------------
for mode in ("average", "maximum"):
    samples = []
    started = ticks_ms()
    while elapsed_since(started) < 1000:
        samples.append(cyberpi.get_loudness(mode))
    duration = max(elapsed_since(started), 1)

    rate = len(samples) * 1000.0 / duration
    low = min(samples) if samples else 0
    high = max(samples) if samples else 0

    line = mode + ": " + str(int(rate)) + " Hz " + str(low) + "-" + str(high)
    cyberpi.console.println(line)
    print(line)
    # 20 Hz is the rough floor for turn detection that does not feel laggy.
    print("  VAD viable: " + ("yes" if rate >= 20 else "NO - too slow"))

# --- live level meter, so you can see it respond to your voice -------------
cyberpi.console.println("talk for 10s...")
started = ticks_ms()
while elapsed_since(started) < 10000:
    level = cyberpi.get_loudness("average")
    bars = int(min(max(level, 0), 100) / 5)
    cyberpi.console.println(("#" * bars) + " " + str(level))
    time.sleep(0.2)

cyberpi.console.println("done")
print("Record the Hz values in apps/cyberpi/STEPS.md")
