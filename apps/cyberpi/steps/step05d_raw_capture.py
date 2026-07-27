"""Step 5d - does cyberpi.mic_o.get_recording_data() return real audio?

Step 5c found that CyberOS exposes the raw I2S microphone driver in Python:

    cyberpi.mic_o  (type i2s_mic)
        init / deinit
        record_start / record_stop / record_with_time
        record_get_status / record_set_status
        get_recording_data      <-- this one
        play_recording
        get_loudness

None of this is in Makeblock's published API. If get_recording_data() hands
back a bytes-like object of plausible length, then raw microphone capture works
on unmodified CyberOS, the Stage-1 gate answers YES on its capture half, and
this project does not need custom firmware to hear you.

WHAT THIS RUN MEASURES
  - what type comes back, and how many bytes
  - the first 64 bytes, so we can see whether it looks like PCM rather than
    zeros or a header
  - bytes per second, which tells us the sample rate and width

SAFETY
  init() and deinit() are NOT called. Deinitialising the I2S peripheral could
  leave the microphone unusable for the rest of the session, or wedge CyberOS
  the way step 5 did. This step only reads, records through paths that already
  work, and reads back.

  Everything prints as it goes, most valuable first, because a crash truncates
  everything after it.
"""

import time

import cyberpi

RECORD_SECONDS = 2

try:
    import ubinascii
except ImportError:
    ubinascii = None


def preview(data, count=64):
    """First bytes as hex, so we can eyeball whether it is really audio."""
    chunk = data[:count]
    if ubinascii is not None:
        try:
            return ubinascii.hexlify(chunk).decode()
        except Exception:
            pass
    return str(chunk)[:200]


def describe(label, data, seconds=None):
    """Report type, size, shape, and the implied sample rate."""
    print("  " + label + ":")
    print("    type: " + type(data).__name__)

    try:
        size = len(data)
    except Exception as exc:
        print("    len() failed: " + type(exc).__name__ + ": " + str(exc))
        print("    repr: " + str(data)[:120])
        return 0

    print("    bytes: " + str(size))
    if size == 0:
        print("    (empty)")
        return 0

    print("    head: " + preview(data))

    if seconds:
        per_second = size / float(seconds)
        print("    bytes/sec: " + str(int(per_second)))
        # If these are 16-bit samples, this is the sample rate.
        print("    -> " + str(int(per_second / 2)) + " Hz if 16-bit mono")
        print("    -> " + str(int(per_second)) + " Hz if 8-bit mono")

    # All-zero data means the buffer exists but nothing was captured.
    try:
        nonzero = 0
        for byte in data[: min(size, 512)]:
            value = byte if isinstance(byte, int) else ord(byte)
            if value not in (0, 255):
                nonzero += 1
        print("    nonzero in first 512: " + str(nonzero))
        if nonzero == 0:
            print("    WARNING: looks like silence or an empty buffer")
    except Exception as exc:
        print("    scan failed: " + str(exc))
    return size


cyberpi.console.clear()
cyberpi.console.println("5d: raw capture?")
print("")
print("=== ROCKY STEP 5D: RAW CAPTURE ===")

mic = None
try:
    mic = cyberpi.mic_o
    print("cyberpi.mic_o type: " + type(mic).__name__)
except Exception as exc:
    print("cyberpi.mic_o unavailable: " + type(exc).__name__ + ": " + str(exc))

if mic is not None:
    # --- 1. status before anything, the safest possible call ---------------
    print("")
    print("--- 1. record_get_status() before recording ---")
    try:
        status = mic.record_get_status()
        print("  status: " + str(status) + " (type " + type(status).__name__ + ")")
    except Exception as exc:
        print("  failed: " + type(exc).__name__ + ": " + str(exc))

    # --- 2. read the buffer before recording, for a baseline ---------------
    print("")
    print("--- 2. get_recording_data() with nothing recorded ---")
    try:
        data = mic.get_recording_data()
        describe("empty-buffer read", data)
    except Exception as exc:
        print("  failed: " + type(exc).__name__ + ": " + str(exc))

    # --- 3. record through the KNOWN-GOOD path, then read the buffer -------
    # cyberpi.audio.record() is the documented API and step 3 proved it works,
    # so if the buffer fills here, the readout is what is new - not the record.
    print("")
    print("--- 3. audio.record() for " + str(RECORD_SECONDS) + "s, then get_recording_data() ---")
    cyberpi.console.println("SPEAK NOW")
    cyberpi.led.on(60, 0, 0)
    try:
        cyberpi.audio.record()
        time.sleep(RECORD_SECONDS)
        cyberpi.audio.stop_record()
        time.sleep(0.5)
        cyberpi.led.off()
        data = mic.get_recording_data()
        describe("after audio.record()", data, RECORD_SECONDS)
    except Exception as exc:
        cyberpi.led.off()
        print("  failed: " + type(exc).__name__ + ": " + str(exc))

    # --- 4. the driver's own timed recording -------------------------------
    print("")
    print("--- 4. record_with_time(" + str(RECORD_SECONDS) + ") ---")
    cyberpi.console.println("SPEAK AGAIN")
    cyberpi.led.on(60, 30, 0)
    try:
        result = mic.record_with_time(RECORD_SECONDS)
        print("  returned: " + str(result)[:80] + " (type " + type(result).__name__ + ")")
        time.sleep(RECORD_SECONDS + 1)
        cyberpi.led.off()
        data = mic.get_recording_data()
        describe("after record_with_time()", data, RECORD_SECONDS)
    except Exception as exc:
        cyberpi.led.off()
        print("  failed: " + type(exc).__name__ + ": " + str(exc))

    # --- 5. explicit start/stop, the shape a streaming loop would use ------
    print("")
    print("--- 5. record_start() / record_stop() ---")
    cyberpi.console.println("SPEAK ONCE MORE")
    cyberpi.led.on(0, 40, 60)
    try:
        mic.record_start()
        time.sleep(RECORD_SECONDS)
        mic.record_stop()
        time.sleep(0.3)
        cyberpi.led.off()
        data = mic.get_recording_data()
        describe("after record_start/stop", data, RECORD_SECONDS)
    except Exception as exc:
        cyberpi.led.off()
        print("  failed: " + type(exc).__name__ + ": " + str(exc))

    # --- 6. can we read WHILE recording? the streaming question ------------
    # If mid-recording reads return growing buffers, a streaming loop is
    # possible. If they return empty or the same thing each time, Rocky is
    # limited to fixed-length turns.
    print("")
    print("--- 6. reads DURING an active recording ---")
    cyberpi.led.on(60, 0, 60)
    try:
        mic.record_start()
        for index in range(4):
            time.sleep(0.5)
            try:
                chunk = mic.get_recording_data()
                size = len(chunk) if chunk is not None else -1
                print("  t+" + str((index + 1) * 500) + "ms: " + str(size) + " bytes")
            except Exception as exc:
                print("  t+" + str((index + 1) * 500) + "ms: failed - " + str(exc))
        mic.record_stop()
        cyberpi.led.off()
        print("  (growing sizes = streaming is possible)")
    except Exception as exc:
        cyberpi.led.off()
        print("  failed: " + type(exc).__name__ + ": " + str(exc))

print("")
print("=== END STEP 5D ===")
cyberpi.console.println("done - see console")
