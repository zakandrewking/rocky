"""Step 5f - how much audio is behind that WAV header?

Step 5e got real data back:

    get_recording_data(x) -> [b'RIFF\\x00\\x00\\x00\\x00WAVEfmt \\x10...', <something>]

A list of two, whose first element is a RIFF/WAVE stream with 0x3e80 = 16000
sitting where a WAV header keeps the sample rate. Raw capture is evidently
there.

But step 5e's formatter assumed bytes and got a list, so the length was never
printed - and a 44-byte header with no audio behind it would look identical
from where we are standing. This step answers:

  1. how long is the byte string, really
  2. what is the second list element (length? remaining? a status flag?)
  3. what the WAV header actually declares - rate, channels, width, data size
  4. whether repeated calls return more data, which is what streaming needs
  5. whether the argument selects an offset or chunk after all

WHAT SUCCESS LOOKS LIKE
  A 2-second recording at 16 kHz 16-bit mono is about 64 KB. Anything in that
  neighbourhood means we have Rocky's ears on stock firmware.

  If it comes back as 44 bytes, we have a header and nothing else, and the real
  audio lives somewhere we have not looked yet.
"""

import time

import cyberpi

RECORD_SECONDS = 2

try:
    import ubinascii
except ImportError:
    ubinascii = None


def hex_head(data, count=64):
    chunk = bytes(data[:count])
    if ubinascii is not None:
        try:
            return ubinascii.hexlify(chunk).decode()
        except Exception:
            pass
    return str(chunk)


def u16(data, offset):
    return data[offset] | (data[offset + 1] << 8)


def u32(data, offset):
    return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)


def parse_wav(data):
    """Report what the header claims. Offsets are the standard RIFF layout."""
    print("    --- WAV header ---")
    try:
        print("    riff tag:    " + str(bytes(data[0:4])))
        print("    riff size:   " + str(u32(data, 4)))
        print("    wave tag:    " + str(bytes(data[8:12])))
        print("    fmt tag:     " + str(bytes(data[12:16])))
        print("    fmt size:    " + str(u32(data, 16)))
        print("    format code: " + str(u16(data, 20)) + "  (1=PCM, 3=float)")
        print("    channels:    " + str(u16(data, 22)))
        print("    sample rate: " + str(u32(data, 24)))
        print("    byte rate:   " + str(u32(data, 28)))
        print("    block align: " + str(u16(data, 32)))
        print("    bits/sample: " + str(u16(data, 34)))
    except Exception as exc:
        print("    header parse failed: " + type(exc).__name__ + ": " + str(exc))

    # The data chunk is usually at 36, but only usually - go and find it.
    try:
        limit = min(len(data) - 4, 256)
        for offset in range(12, limit):
            if bytes(data[offset : offset + 4]) == b"data":
                print("    'data' chunk at offset " + str(offset))
                print("    declared data size: " + str(u32(data, offset + 4)))
                print("    audio bytes after header: " + str(len(data) - (offset + 8)))
                return
        print("    no 'data' chunk found in the first " + str(limit) + " bytes")
    except Exception as exc:
        print("    data-chunk scan failed: " + str(exc))


def report(result, seconds=None):
    print("    type: " + type(result).__name__)
    try:
        count = len(result)
    except Exception:
        print("    value: " + str(result)[:80])
        return None
    print("    elements: " + str(count))

    payload = None
    for index in range(count):
        item = result[index]
        kind = type(item).__name__
        try:
            size = len(item)
            print("    [" + str(index) + "] " + kind + ", len " + str(size))
            if size and payload is None and kind in ("bytes", "bytearray", "memoryview"):
                payload = item
        except Exception:
            # No len() means a scalar - and its value is the interesting part.
            print("    [" + str(index) + "] " + kind + " = " + str(item))

    if payload is None:
        return None

    print("    payload bytes: " + str(len(payload)))
    print("    head: " + hex_head(payload))
    parse_wav(payload)

    if seconds:
        per_second = len(payload) / float(seconds)
        print("    measured: " + str(int(per_second)) + " bytes/sec")
        print("      = " + str(int(per_second / 2)) + " Hz if 16-bit mono")
    return payload


cyberpi.console.clear()
cyberpi.console.println("5f: unpack")
print("")
print("=== ROCKY STEP 5F: UNPACK ===")

mic = cyberpi.mic_o

# --- record something real -------------------------------------------------
print("")
print("--- recording " + str(RECORD_SECONDS) + "s ---")
cyberpi.console.println("SPEAK NOW")
cyberpi.led.on(60, 0, 0)
try:
    mic.record_with_time(RECORD_SECONDS)
    time.sleep(RECORD_SECONDS + 1)
    print("  status after record: " + str(mic.record_get_status()))
except Exception as exc:
    print("  record failed: " + type(exc).__name__ + ": " + str(exc))
cyberpi.led.off()

# --- the main event --------------------------------------------------------
print("")
print("--- get_recording_data(0) ---")
try:
    first = mic.get_recording_data(0)
    report(first, RECORD_SECONDS)
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

# --- does calling again give us MORE, or the same thing again? ------------
# This is the streaming question. Growing or advancing data means Rocky can
# send audio while still recording; identical data means fixed-size turns.
print("")
print("--- repeated calls (streaming check) ---")
for attempt in range(4):
    try:
        result = mic.get_recording_data(0)
        payload = None
        for index in range(len(result)):
            item = result[index]
            try:
                if len(item) and type(item).__name__ in ("bytes", "bytearray", "memoryview"):
                    payload = item
            except Exception:
                pass
        size = len(payload) if payload is not None else -1
        others = []
        for index in range(len(result)):
            try:
                len(result[index])
            except Exception:
                others.append(str(result[index]))
        starts_riff = bool(payload) and bytes(payload[:4]) == b"RIFF"
        print(
            "  call "
            + str(attempt + 1)
            + ": payload "
            + str(size)
            + " bytes, scalars "
            + str(others)
            + ", starts RIFF: "
            + str(starts_riff)
        )
    except Exception as exc:
        print("  call " + str(attempt + 1) + ": " + type(exc).__name__ + ": " + str(exc))
    time.sleep(0.2)

# --- does the argument select an offset or chunk? -------------------------
print("")
print("--- argument sweep ---")
for argument in (0, 1, 2, 100):
    try:
        result = mic.get_recording_data(argument)
        sizes = []
        for index in range(len(result)):
            try:
                sizes.append(len(result[index]))
            except Exception:
                sizes.append(str(result[index]))
        print("  arg " + str(argument) + ": " + str(sizes))
    except Exception as exc:
        print("  arg " + str(argument) + ": " + type(exc).__name__ + ": " + str(exc))

print("")
print("=== END STEP 5F ===")
cyberpi.console.println("done - see console")
