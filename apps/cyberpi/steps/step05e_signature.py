"""Step 5e - what argument does get_recording_data() want?

Step 5d called it with no arguments and got:

    TypeError: function takes 2 positional arguments but 1 were given

That is a signature, not a refusal. A bound method counts `self` as the first
positional, so it wants exactly **one** explicit argument. Same for
record_start(). Meanwhile record_get_status() returned 0 and
record_with_time(2) returned None, so the driver is alive and recording works.

So the raw capture path is probably there. We just have to call it correctly.

TWO TECHNIQUES

1. **Arity by TypeError.** MicroPython checks argument count *before* running
   the function body, so calling a method with no arguments and reading the
   error is a side-effect-free way to learn its signature. Methods that really
   do take zero arguments will execute - harmless for status readers and
   getters, which is why init/deinit are still excluded.

2. **Argument guessing.** For a method named get_recording_data taking one
   argument, the realistic candidates are a length, an offset, or a buffer to
   fill (MicroPython's readinto pattern). Try each, report what comes back.

WHAT SUCCESS LOOKS LIKE
  - a bytes/bytearray return with a plausible length, or
  - an int return alongside a bytearray argument that came back non-zero
    (that is readinto: it filled our buffer and told us how many bytes)
"""

import time

import cyberpi

RECORD_SECONDS = 2

try:
    import ubinascii
except ImportError:
    ubinascii = None

# init/deinit excluded: a zero-argument call would actually run them, and
# deinitialising the I2S peripheral could kill the microphone for the session.
ARITY_PROBE = (
    "get_recording_data",
    "record_start",
    "record_stop",
    "record_get_status",
    "record_set_status",
    "record_with_time",
    "play_recording",
    "get_loudness",
)


def head(data, count=48):
    try:
        chunk = bytes(data[:count])
    except Exception:
        return str(data)[:120]
    if ubinascii is not None:
        try:
            return ubinascii.hexlify(chunk).decode()
        except Exception:
            pass
    return str(chunk)[:120]


def nonzero_count(buffer, limit=512):
    total = 0
    try:
        for byte in buffer[:limit]:
            value = byte if isinstance(byte, int) else ord(byte)
            if value not in (0, 255):
                total += 1
    except Exception:
        return -1
    return total


cyberpi.console.clear()
cyberpi.console.println("5e: signatures")
print("")
print("=== ROCKY STEP 5E: SIGNATURES ===")

mic = cyberpi.mic_o
print("mic_o type: " + type(mic).__name__)

# --- 1. read every signature off the TypeErrors ----------------------------
print("")
print("--- 1. arity (0-arg call; TypeError is raised before the body runs) ---")
for name in ARITY_PROBE:
    try:
        method = getattr(mic, name)
    except Exception as exc:
        print("  " + name + ": missing (" + str(exc) + ")")
        continue
    try:
        result = method()
        # No TypeError means it genuinely takes no arguments, and just ran.
        print("  " + name + "(): takes 0 args, returned " + str(result)[:40] + " (" + type(result).__name__ + ")")
    except TypeError as exc:
        # "takes N positional arguments" counts self, so wants N-1 from us.
        print("  " + name + "(): " + str(exc))
    except Exception as exc:
        print("  " + name + "(): " + type(exc).__name__ + ": " + str(exc))

# --- 2. record something, so there is data to fetch ------------------------
print("")
print("--- 2. recording " + str(RECORD_SECONDS) + "s via record_with_time ---")
cyberpi.console.println("SPEAK NOW")
cyberpi.led.on(60, 0, 0)
try:
    mic.record_with_time(RECORD_SECONDS)
    time.sleep(RECORD_SECONDS + 1)
    print("  recorded; status now: " + str(mic.record_get_status()))
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))
cyberpi.led.off()

# --- 3. guess the argument -------------------------------------------------
print("")
print("--- 3. get_recording_data(<one argument>) ---")


def trial(label, argument, is_buffer=False):
    print("  " + label + ":")
    try:
        result = mic.get_recording_data(argument)
    except Exception as exc:
        print("    " + type(exc).__name__ + ": " + str(exc))
        return

    print("    returned type: " + type(result).__name__)
    try:
        print("    returned len: " + str(len(result)))
    except Exception:
        print("    returned value: " + str(result)[:60])

    # readinto pattern: we passed a buffer, it filled it and returned a count.
    if is_buffer:
        filled = nonzero_count(argument)
        print("    buffer nonzero (first 512): " + str(filled))
        print("    buffer head: " + head(argument))
        if filled > 0:
            print("    *** THE BUFFER WAS FILLED - this is raw capture ***")
    else:
        try:
            if len(result) > 0:
                print("    head: " + head(result))
                print("    nonzero (first 512): " + str(nonzero_count(result)))
                print("    *** GOT DATA BACK ***")
        except Exception:
            pass


for size in (0, 1, 512, 4096):
    trial("int " + str(size), size)

for size in (512, 4096):
    trial("bytearray(" + str(size) + ")", bytearray(size), True)

print("")
print("=== END STEP 5E ===")
cyberpi.console.println("done - see console")
