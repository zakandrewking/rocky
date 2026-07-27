"""Step 5l - now that raw playback works, what shape is it?

Step 5k answered the gate: play_raw_data(data, rate) makes a sound. Both halves
of Stage 1 are possible on stock CyberOS.

Its tests 2 and 3 failed for a silly reason - once the fallback found the
two-argument form, the later tests still used the one-argument version - so
three real questions went unanswered. This step asks them properly.

MEASURED SO FAR
    init()                      takes no arguments, returns True
    play_raw_data(data, rate)   works
    get_status()                0 = STOPPED, 1 = PLAYING,
                                2 = TO_STOPP, 3 = PLAYING_CONTINUE
    set_volume(v), stop(), pause(), resume(), run()   all exist
    PLAYER_MODE_RAW = 2, PLAYER_MODE_MP3 = 1

WHAT THIS ANSWERS
  A. Does an echo of the microphone play? Same format both directions, so this
     confirms Rocky can replay exactly what it captured.
  B. Can the player be fed twice without re-initialising?
  C. Is play_raw_data blocking or asynchronous? Status sampled immediately
     after the call tells us - and that decides whether the display can animate
     while Rocky talks.
  D. **Can audio be fed in chunks as it arrives?** This is the important one.
     If a reply can start playing before it has fully downloaded, Rocky feels
     responsive; if not, every answer waits for a complete file. That is the
     difference between a conversation and a voicemail system.
     PLAY_STATUS_PLAYING_CONTINUE existing at all suggests this is intended.

RECOVERY
  If audio gets stuck, power-cycle the CyberPi. Nothing here persists.
"""

import math
import time

import cyberpi

SAMPLE_RATE = 16000
VOLUME = 70
CHUNK_MS = 250


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


def make_tone(seconds, frequency, rate=SAMPLE_RATE):
    """8-bit unsigned PCM centred on 128 - the microphone's own format."""
    count = int(seconds * rate)
    buffer = bytearray(count)
    for index in range(count):
        buffer[index] = 128 + int(100 * math.sin(2 * math.pi * frequency * index / rate))
    return bytes(buffer)


def payload_of(result):
    best = None
    try:
        for index in range(len(result)):
            item = result[index]
            try:
                len(item)
            except Exception:
                continue
            if best is None or len(item) > len(best):
                best = item
    except Exception:
        return None
    return best


def status_name(value):
    return {0: "STOPPED", 1: "PLAYING", 2: "TO_STOPP", 3: "PLAYING_CONTINUE"}.get(value, str(value))


cyberpi.console.clear()
cyberpi.console.println("5l: playback shape")
print("")
print("=== ROCKY STEP 5L: PLAYBACK SHAPE ===")

player = cyberpi.mp3_music_o

try:
    print("init(): " + str(player.init()))
    player.set_volume(VOLUME)
    print("volume: " + str(player.get_volume()))
except Exception as exc:
    print("setup failed: " + type(exc).__name__ + ": " + str(exc))

# ---------------------------------------------------------------------------
# C. blocking or asynchronous?
# ---------------------------------------------------------------------------
print("")
print("--- C. is play_raw_data blocking? ---")
cyberpi.console.println("tone 1")
tone = make_tone(1, 440)
try:
    started = ticks_ms()
    player.play_raw_data(tone, SAMPLE_RATE)
    call_took = elapsed_since(started)
    immediate = player.get_status()
    print("  call returned in " + str(call_took) + " ms for 1000 ms of audio")
    print("  status immediately after: " + status_name(immediate))
    if call_took < 500:
        print("  -> ASYNCHRONOUS: the screen can animate while Rocky speaks")
    else:
        print("  -> BLOCKING: playback ties up the interpreter")

    # Watch it drain.
    for index in range(4):
        time.sleep(0.3)
        print("    +" + str((index + 1) * 300) + "ms status: " + status_name(player.get_status()))
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

time.sleep(0.5)

# ---------------------------------------------------------------------------
# B. a second buffer with no re-init
# ---------------------------------------------------------------------------
print("")
print("--- B. second buffer, no re-init ---")
cyberpi.console.println("tone 2 (higher)")
try:
    player.play_raw_data(make_tone(1, 660), SAMPLE_RATE)
    print("  accepted - repeated feeding works without re-init")
    print("  *** did you hear a SECOND, HIGHER tone? ***")
    time.sleep(2)
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))
    print("  a re-init is needed between buffers")
    try:
        player.init()
        player.play_raw_data(make_tone(1, 660), SAMPLE_RATE)
        print("  worked after re-init")
        time.sleep(2)
    except Exception as exc2:
        print("  still failed after re-init: " + str(exc2))

# ---------------------------------------------------------------------------
# D. chunked feeding - the latency question
# ---------------------------------------------------------------------------
print("")
print("--- D. feeding in " + str(CHUNK_MS) + " ms chunks ---")
print("  if this plays continuously, Rocky can start talking before the")
print("  whole reply has downloaded")
cyberpi.console.println("8 chunks...")
try:
    chunk_samples = int(SAMPLE_RATE * CHUNK_MS / 1000)
    gaps = []
    for index in range(8):
        # Rising pitch per chunk, so a gap or reordering is audible.
        chunk = make_tone(CHUNK_MS / 1000.0, 330 + index * 40)
        started = ticks_ms()
        player.play_raw_data(chunk, SAMPLE_RATE)
        gaps.append(elapsed_since(started))
        status = player.get_status()
        print("  chunk " + str(index + 1) + ": call " + str(gaps[-1]) + " ms, status " + status_name(status))
    print("")
    print("  call times: " + str(gaps))
    print("  *** did it sound like ONE rising sweep, or 8 broken beeps? ***")
    print("  smooth = streaming playback works; gappy = whole clips only")
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

time.sleep(1)

# ---------------------------------------------------------------------------
# A. echo the microphone
# ---------------------------------------------------------------------------
print("")
print("--- A. echo a real recording ---")
cyberpi.console.println("SPEAK (2s)")
cyberpi.led.on(60, 0, 0)
try:
    cyberpi.mic_o.record_with_time(2)
    time.sleep(3)
    cyberpi.led.off()

    recorded = payload_of(cyberpi.mic_o.get_recording_data(0))
    if recorded is None or len(recorded) == 0:
        print("  nothing recorded")
    else:
        print("  recorded " + str(len(recorded)) + " bytes; playing back")
        cyberpi.console.println("hear yourself?")
        player.play_raw_data(recorded, SAMPLE_RATE)
        time.sleep(3)
        print("  *** DID YOU HEAR YOURSELF? ***")
        print("  if yes: capture and playback share a format, and the")
        print("  full local audio loop works on stock firmware")
except Exception as exc:
    cyberpi.led.off()
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

print("")
print("=== END STEP 5L ===")
cyberpi.console.println("done")
