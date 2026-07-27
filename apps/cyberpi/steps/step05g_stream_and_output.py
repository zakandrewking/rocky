"""Step 5g - can we read audio WHILE recording, and is there a raw output path?

Capture is settled (step 5f):

    get_recording_data(x) -> [48-byte header, PCM bytes]
    2 s -> 32000 bytes = 16000 B/s; header says 16000 Hz, 8 bits/sample
    => 16 kHz 8-bit mono, 128 kbps

Two things are still open, and they are the last two questions in the way of
the Stage-1 decision.

PART 1 - STREAMING
  Repeated calls after a recording ends return the same buffer, so there is no
  read cursor. But nobody has yet called get_recording_data() *during* an
  active record_start(). If the payload grows as we poll, Rocky can ship audio
  while the person is still talking, and the conversation can feel live. If it
  stays flat or empty, Rocky is limited to fixed turns: press, talk, wait.

  That is the difference between a conversation and a walkie-talkie.

PART 2 - OUTPUT
  Capture is proven; playback is now the binding constraint on the whole
  project. cyberpi.mic_o was found by dumping dir(cyberpi) and noticing an
  undocumented name, so this does the same thing again, unfiltered, looking for
  the speaker's equivalent.

  We already know a 'speaker' type exists: step 5 got
  "AttributeError: 'speaker' object has no attribute 'music_playing_list'"
  out of cyberpi.audio.play(). So cyberpi.audio is a speaker instance, and the
  question is whether an i2s-level sibling exists the way mic_o does for the
  microphone.

SAFETY
  Reads and dir() only, plus record_start/record_stop which are already proven.
  Nothing is played, nothing is deinitialised.
"""

import time

import cyberpi

POLL_MS = 250
POLL_COUNT = 8

# Names to notice on the output side, by analogy with mic/mic_o/microphone.
OUTPUT_HINTS = ("spk", "speaker", "audio", "i2s", "dac", "play", "sound", "codec", "es82", "amp")


def payload_of(result):
    """get_recording_data returns [header, data]; return the data element."""
    try:
        best = None
        for index in range(len(result)):
            item = result[index]
            try:
                size = len(item)
            except Exception:
                continue
            if best is None or size > len(best):
                best = item
        return best
    except Exception:
        return None


cyberpi.console.clear()
cyberpi.console.println("5g: stream + output")
print("")
print("=== ROCKY STEP 5G ===")

mic = cyberpi.mic_o

# ---------------------------------------------------------------------------
# PART 1 - does the buffer grow while recording?
# ---------------------------------------------------------------------------
print("")
print("--- 1. polling get_recording_data() DURING record_start() ---")
print("  16000 B/s expected, so ~4000 bytes per 250 ms if it streams")
cyberpi.console.println("KEEP TALKING")
cyberpi.led.on(60, 0, 0)

sizes = []
try:
    mic.record_start()
    for index in range(POLL_COUNT):
        time.sleep(POLL_MS / 1000.0)
        try:
            data = payload_of(mic.get_recording_data(0))
            size = len(data) if data is not None else -1
        except Exception as exc:
            size = -1
            print("    poll " + str(index + 1) + " failed: " + type(exc).__name__ + ": " + str(exc))
        sizes.append(size)
        print("    t+" + str((index + 1) * POLL_MS) + "ms: " + str(size) + " bytes")
    mic.record_stop()
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))
cyberpi.led.off()

# Read once more now that recording has stopped, for comparison.
try:
    final = payload_of(mic.get_recording_data(0))
    final_size = len(final) if final is not None else -1
    print("    after stop: " + str(final_size) + " bytes")
except Exception as exc:
    final_size = -1
    print("    after stop failed: " + str(exc))

growing = len([s for s in sizes if s > 0]) >= 2 and sizes[-1] > sizes[0]
print("")
if growing:
    print("  *** BUFFER GREW WHILE RECORDING - streaming is possible ***")
    cyberpi.console.println("STREAMS!")
else:
    print("  buffer did not grow: fixed-turn audio only")
    print("  (sizes: " + str(sizes) + ")")
    cyberpi.console.println("no streaming")

# ---------------------------------------------------------------------------
# PART 2 - hunt for the output equivalent of mic_o
# ---------------------------------------------------------------------------
print("")
print("--- 2. every cyberpi member (unfiltered, one per line) ---")
# mic_o was found exactly this way. Print them all rather than filtering, since
# the last filter's blind spot is what hid the interesting name.
try:
    names = sorted([m for m in dir(cyberpi) if not m.startswith("_")])
    print("  count: " + str(len(names)))
    for name in names:
        print("  " + name)
except Exception as exc:
    print("  dir(cyberpi) failed: " + str(exc))
    names = []

print("")
print("--- 3. output-side candidates ---")
candidates = []
for name in names:
    lowered = name.lower()
    for hint in OUTPUT_HINTS:
        if hint in lowered:
            candidates.append(name)
            break
print("  " + (", ".join(candidates) or "(none)"))

for name in candidates:
    try:
        obj = getattr(cyberpi, name)
    except Exception as exc:
        print("  cyberpi." + name + ": unavailable (" + str(exc) + ")")
        continue

    kind = type(obj).__name__
    print("")
    print("  --- cyberpi." + name + "  (type " + kind + ") ---")
    try:
        members = sorted([m for m in dir(obj) if not m.startswith("_")])
        print("    count: " + str(len(members)))
        for member in members:
            try:
                value = getattr(obj, member)
                print("    " + member + " : " + type(value).__name__)
            except Exception as exc:
                print("    " + member + " : ERR " + type(exc).__name__)
    except Exception as exc:
        print("    dir() failed: " + str(exc))

print("")
print("=== END STEP 5G ===")
cyberpi.console.println("done - see console")
