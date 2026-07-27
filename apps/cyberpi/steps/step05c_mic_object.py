"""Step 5c - what is cyberpi.mic?

Step 5 turned up three members that do not exist in Makeblock's published API
package, which is what docs/cyberos-api-surface.md was built from:

    cyberpi.mic
    cyberpi.microphone
    cyberpi.mic_o...      (truncated by the console - name unknown)
    cyberpi.audio.file_handle

The published package documents ~20 audio members. The firmware has 33. So the
documentation is a subset of reality, and the "no raw capture path" conclusion
that was about to send this project to Stage 2 rests on an incomplete source.

This step exists to find out what those objects actually are.

SAFE MODE
  This program calls nothing. It only reads attribute names and types.

  That is deliberate. In step 5 the board crashed immediately after
  record(path) and play(path) were attempted - play() died inside the speaker
  object with AttributeError: 'speaker' object has no attribute
  'music_playing_list' - and everything after that point was lost. Poking
  unknown audio internals can evidently wedge the firmware, so this step
  gathers information first and calls nothing.

ONE NAME PER LINE
  The console truncates long lines; that is how we lost the end of the suspect
  list. Everything here prints one short item per line.

WHAT TO LOOK FOR
  Any attribute on mic/microphone whose name suggests reading data:
  read, readinto, get, buffer, data, sample, stream, start, stop, init, deinit.
  Anything returning a bytes-like object is the whole ballgame.
"""

import gc
import sys

import cyberpi

cyberpi.console.clear()
cyberpi.console.println("step 5c: cyberpi.mic")

# Most valuable output first: step 5 proved this program may not reach its end.
print("")
print("=== ROCKY STEP 5C ===")
print("firmware: " + str(getattr(sys, "implementation", "unknown")))
print("")


def describe(label, obj):
    """Print every attribute of obj, one per line, with its type."""
    print("--- " + label + " ---")
    try:
        members = sorted([m for m in dir(obj) if not m.startswith("_")])
    except Exception as exc:
        print("  dir() failed: " + type(exc).__name__ + ": " + str(exc))
        return

    print("  count: " + str(len(members)))
    for member in members:
        # getattr can execute a property, so guard every single one.
        try:
            value = getattr(obj, member)
            kind = type(value).__name__
        except Exception as exc:
            kind = "ERR " + type(exc).__name__
        print("  " + member + " : " + kind)
    print("")


# --- 1. every cyberpi member matching mic/audio/sound, in full -------------
# The step 5 suspect line was cut off at "cyberpi.mic_o". Print one per line so
# nothing is lost this time.
print("--- cyberpi members matching mic/audio/sound/record ---")
matches = []
try:
    for member in sorted(dir(cyberpi)):
        if member.startswith("_"):
            continue
        lowered = member.lower()
        if "mic" in lowered or "audio" in lowered or "sound" in lowered or "record" in lowered:
            matches.append(member)
            print("  " + member)
except Exception as exc:
    print("  scan failed: " + str(exc))
print("  count: " + str(len(matches)))
print("")

# --- 2. the objects themselves --------------------------------------------
for name in ("mic", "microphone"):
    try:
        obj = getattr(cyberpi, name)
        describe("cyberpi." + name + "  (type " + type(obj).__name__ + ")", obj)
    except Exception as exc:
        print("--- cyberpi." + name + " ---")
        print("  unavailable: " + type(exc).__name__ + ": " + str(exc))
        print("")

# --- 3. whatever mic_o... turned out to be --------------------------------
for member in matches:
    if member in ("mic", "microphone"):
        continue
    if not member.lower().startswith("mic"):
        continue
    try:
        obj = getattr(cyberpi, member)
        describe("cyberpi." + member + "  (type " + type(obj).__name__ + ")", obj)
    except Exception as exc:
        print("--- cyberpi." + member + " ---")
        print("  unavailable: " + type(exc).__name__ + ": " + str(exc))
        print("")

# --- 4. the undocumented audio.file_handle --------------------------------
try:
    handle = cyberpi.audio.file_handle
    print("--- cyberpi.audio.file_handle ---")
    print("  type: " + type(handle).__name__)
    print("  repr: " + str(handle)[:60])
    describe("cyberpi.audio.file_handle members", handle)
except Exception as exc:
    print("--- cyberpi.audio.file_handle ---")
    print("  unavailable: " + type(exc).__name__ + ": " + str(exc))
    print("")

# --- 5. how much room is there for a buffer? ------------------------------
try:
    gc.collect()
    free = gc.mem_free() if hasattr(gc, "mem_free") else -1
    print("free heap: " + str(free) + " bytes")
    # 24 kHz mono 16-bit is 48000 bytes per second.
    print("  = " + str(round(free / 48000.0, 2)) + " s of 24k 16-bit mono PCM")
except Exception as exc:
    print("heap check failed: " + str(exc))

print("")
print("=== END STEP 5C ===")
cyberpi.console.println("done - see console")
cyberpi.console.println("matches: " + str(len(matches)))
