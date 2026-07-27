"""Step 5 - is there ANY way to get raw microphone audio out of CyberOS?

This is one of the two checks that decide Stage 1.

The documented API says no: record() writes to an opaque internal slot and
returns nothing, and nothing accepts a buffer or a path. See
docs/cyberos-api-surface.md. But generated API docs omit things, so this step
goes looking on the actual firmware:

  1. every member of cyberpi.audio and every audio-ish member of cyberpi
  2. whether record() or play() secretly accept a path argument
  3. the filesystem, in case the recording lands somewhere readable
  4. free heap, which bounds any buffer we could ever hold

A "FAIL" here is the expected result, and it is not a bug in this script - it
is the answer to the gate question. What matters is that it is measured rather
than assumed.

EXPECTED (if CyberOS is as documented)
  - no member name containing pcm/buffer/stream/raw/sample/i2s
  - record() rejects a path with TypeError
  - no .wav on the filesystem after recording

WHAT WOULD CHANGE EVERYTHING
  - any member that returns bytes
  - a .wav or .pcm file appearing after a recording
  - record() accepting a filename
Copy anything surprising into STEPS.md verbatim.
"""

import gc
import os
import sys
import time

import cyberpi

# If an undocumented raw-audio path exists, it almost certainly contains one of
# these substrings.
HINTS = (
    "record_file",
    "record_to",
    "get_record",
    "read_record",
    "record_data",
    "raw",
    "pcm",
    "buffer",
    "stream",
    "sample",
    "wav",
    "i2s",
    "codec",
    "mic",
)

cyberpi.console.clear()
cyberpi.console.println("Rocky step 5: raw audio?")
print("Rocky step 5: hunting for a raw audio path")
print("")

# --- 1. what is actually on the audio object? ------------------------------
audio_members = sorted([m for m in dir(cyberpi.audio) if not m.startswith("_")])
print("cyberpi.audio members (" + str(len(audio_members)) + "):")
for member in audio_members:
    print("  " + member)

cyberpi_audio = sorted(
    [m for m in dir(cyberpi) if not m.startswith("_") and ("audio" in m or "record" in m or "sound" in m or "loud" in m)]
)
print("")
print("cyberpi audio-ish members: " + (", ".join(cyberpi_audio) or "(none)"))

# --- 2. anything that smells like raw samples? -----------------------------
suspects = []
for holder_name, holder in (("cyberpi", cyberpi), ("cyberpi.audio", cyberpi.audio)):
    for member in dir(holder):
        if member.startswith("_"):
            continue
        lowered = member.lower()
        for hint in HINTS:
            if hint in lowered:
                suspects.append(holder_name + "." + member)
                break

print("")
if suspects:
    print("*** SUSPECTS FOUND - investigate these: " + ", ".join(suspects))
    cyberpi.console.println("suspects: " + str(len(suspects)))
else:
    print("no raw-audio member found (expected - this is the gate failing)")
    cyberpi.console.println("no raw path (expected)")

# --- 3. do record/play take a path after all? ------------------------------
print("")
try:
    cyberpi.audio.record("/rocky_step5.wav")
    cyberpi.audio.stop_record()
    print("*** record() ACCEPTED a path argument - huge, chase this")
except TypeError as exc:
    print("record() takes no path: " + str(exc))
except Exception as exc:
    print("record(path) raised " + type(exc).__name__ + ": " + str(exc))

try:
    cyberpi.audio.play("/rocky_step5_missing.wav")
    print("*** play() accepted a path without raising - chase this too")
except Exception as exc:
    print("play(path) rejected: " + type(exc).__name__ + ": " + str(exc))

# --- 4. record for real, then look at the filesystem -----------------------
print("")
print("recording 2s, then listing the filesystem...")
cyberpi.console.println("speak briefly...")
cyberpi.audio.record()
time.sleep(2)
cyberpi.audio.stop_record()
time.sleep(0.5)


def walk(path, depth):
    if depth > 2:
        return
    try:
        names = os.listdir(path)
    except Exception:
        return
    for name in names:
        full = path.rstrip("/") + "/" + name
        try:
            stat = os.stat(full)
            size = stat[6]
            is_dir = bool(stat[0] & 0x4000)
        except Exception:
            size, is_dir = -1, False
        print("  " + full + ("/" if is_dir else "  " + str(size) + " bytes"))
        if is_dir:
            walk(full, depth + 1)


print("filesystem:")
walk("/", 0)

# --- 5. how much room would a buffer have? ---------------------------------
gc.collect()
free = gc.mem_free() if hasattr(gc, "mem_free") else -1
print("")
print("free heap: " + str(free) + " bytes")
# 24 kHz mono 16-bit is 48 KB per second of audio.
print("  = " + str(round(free / 48000.0, 2)) + " seconds of 24 kHz 16-bit mono PCM")
print("platform: " + str(sys.platform))
print("implementation: " + str(getattr(sys, "implementation", "unknown")))

cyberpi.console.println("see serial console")
print("")
print("Record the member list and any suspects in apps/cyberpi/STEPS.md")
