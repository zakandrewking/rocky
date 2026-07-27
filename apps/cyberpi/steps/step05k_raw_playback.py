"""Step 5k - THE GATE. Can arbitrary audio reach the speaker?

Step 5h found what Makeblock's published API says does not exist:

    cyberpi.mp3_music_o  (type mp3_music)
        PLAYER_MODE_RAW              <-- a raw PCM mode
        PLAY_STATUS_PLAYING_CONTINUE <-- hints at continuous feeding
        init / deinit
        play_raw_data                <-- arbitrary bytes to the speaker
        play / pause / resume / stop / get_status / set_volume

If play_raw_data() makes a sound, Stage 1 is viable: Rocky can hear
(step 5f) and speak, on unmodified CyberOS, and the whole Stage-2 firmware
branch becomes unnecessary.

THREE TESTS, EASIEST TO HARDEST
  1. a generated 440 Hz tone - proves *server-generated* audio can play, which
     is what Rocky actually needs
  2. an echo of what the microphone just recorded - same byte format both ways,
     so it isolates "can it play" from "is my format right"
  3. a second tone right after the first - shows whether the player can be fed
     repeatedly without a re-init, which is what streaming would need

SAFETY AND RECOVERY
  This one calls init() and deinit(), which the earlier steps deliberately
  avoided. If audio ends up in a bad state, **power-cycle the CyberPi** and it
  comes back - nothing here is persistent.

  Arity is still read off TypeErrors first, so nothing is called blind.

FORMAT
  Matching the microphone: 16 kHz, 8-bit unsigned, mono. Silence is 128.
"""

import math
import time

import cyberpi

SAMPLE_RATE = 16000
TONE_HZ = 440
TONE_SECONDS = 1
VOLUME = 70

# deinit is excluded from the arity probe: a zero-argument call would actually
# run it, and tearing the player down before we have used it helps nobody.
ARITY_PROBE = (
    "init",
    "play_raw_data",
    "play",
    "play_frequency",
    "get_status",
    "get_volume",
    "set_volume",
    "run",
    "pause",
    "resume",
    "stop",
)


def make_tone(seconds, frequency, rate):
    """8-bit unsigned PCM, centred on 128 - the microphone's own format."""
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
                size = len(item)
            except Exception:
                continue
            if best is None or size > len(best):
                best = item
    except Exception:
        return None
    return best


cyberpi.console.clear()
cyberpi.console.println("5k: THE GATE")
print("")
print("=== ROCKY STEP 5K: RAW PLAYBACK ===")

player = cyberpi.mp3_music_o
print("mp3_music_o type: " + type(player).__name__)

# --- constants -------------------------------------------------------------
print("")
print("--- constants ---")
for name in ("PLAYER_MODE_RAW", "PLAYER_MODE_MP3", "PLAY_STATUS_PLAYING", "PLAY_STATUS_PLAYING_CONTINUE", "PLAY_STATUS_STOPPED", "PLAY_STATUS_TO_STOPP"):
    try:
        print("  " + name + " = " + str(getattr(player, name)))
    except Exception as exc:
        print("  " + name + ": " + str(exc))

# --- signatures ------------------------------------------------------------
print("")
print("--- arity (0-arg call; TypeError comes before the body runs) ---")
for name in ARITY_PROBE:
    try:
        method = getattr(player, name)
    except Exception as exc:
        print("  " + name + ": missing (" + str(exc) + ")")
        continue
    try:
        result = method()
        print("  " + name + "(): takes 0 args, returned " + str(result)[:40])
    except TypeError as exc:
        print("  " + name + "(): " + str(exc))
    except Exception as exc:
        print("  " + name + "(): " + type(exc).__name__ + ": " + str(exc))

# --- initialise in raw mode ------------------------------------------------
print("")
print("--- init(PLAYER_MODE_RAW) ---")
initialised = False
try:
    mode = player.PLAYER_MODE_RAW
    try:
        player.init(mode)
        initialised = True
        print("  init(" + str(mode) + ") ok")
    except TypeError as exc:
        print("  init(mode) rejected: " + str(exc))
        # Perhaps it wants (mode, rate) - the obvious second argument.
        try:
            player.init(mode, SAMPLE_RATE)
            initialised = True
            print("  init(mode, " + str(SAMPLE_RATE) + ") ok")
        except Exception as exc2:
            print("  init(mode, rate) also rejected: " + str(exc2))
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

try:
    player.set_volume(VOLUME)
    print("  volume set to " + str(VOLUME))
except Exception as exc:
    print("  set_volume failed: " + str(exc))

# --- TEST 1: a generated tone ---------------------------------------------
print("")
print("--- TEST 1: generated " + str(TONE_HZ) + " Hz tone ---")
cyberpi.console.println("listen: tone?")
tone = make_tone(TONE_SECONDS, TONE_HZ, SAMPLE_RATE)
print("  built " + str(len(tone)) + " bytes")

played = False
try:
    player.play_raw_data(tone)
    played = True
    print("  play_raw_data() returned without error")
except TypeError as exc:
    print("  play_raw_data(data) rejected: " + str(exc))
    # Try the plausible extra arguments before giving up.
    for label, call in (
        ("data, rate", lambda: player.play_raw_data(tone, SAMPLE_RATE)),
        ("data, len", lambda: player.play_raw_data(tone, len(tone))),
    ):
        try:
            call()
            played = True
            print("  play_raw_data(" + label + ") worked")
            break
        except Exception as exc2:
            print("  play_raw_data(" + label + ") failed: " + str(exc2))
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

time.sleep(TONE_SECONDS + 1)
try:
    print("  status after play: " + str(player.get_status()))
except Exception as exc:
    print("  get_status failed: " + str(exc))

if played:
    print("")
    print("  *** DID YOU HEAR A TONE? If yes, THE GATE IS OPEN. ***")
    cyberpi.console.println("hear a tone?")

# --- TEST 2: echo the microphone ------------------------------------------
print("")
print("--- TEST 2: echo a real recording ---")
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
        print("  recorded " + str(len(recorded)) + " bytes; playing it back")
        cyberpi.console.println("hear yourself?")
        try:
            player.play_raw_data(recorded)
            time.sleep(3)
            print("  *** DID YOU HEAR YOURSELF? ***")
        except Exception as exc:
            print("  playback failed: " + type(exc).__name__ + ": " + str(exc))
except Exception as exc:
    cyberpi.led.off()
    print("  failed: " + type(exc).__name__ + ": " + str(exc))

# --- TEST 3: can it be fed twice? -----------------------------------------
print("")
print("--- TEST 3: a second buffer without re-init (streaming shape) ---")
cyberpi.console.println("two tones?")
try:
    second = make_tone(TONE_SECONDS, 660, SAMPLE_RATE)
    player.play_raw_data(second)
    time.sleep(TONE_SECONDS + 1)
    print("  second buffer accepted - repeated feeding looks possible")
    print("  *** DID YOU HEAR A SECOND, HIGHER TONE? ***")
except Exception as exc:
    print("  second play failed: " + type(exc).__name__ + ": " + str(exc))
    print("  a re-init may be needed between buffers")

print("")
print("=== END STEP 5K ===")
print("If you heard sound: capture AND playback both work on stock CyberOS.")
print("If audio is now stuck, power-cycle the CyberPi. Nothing here persists.")
cyberpi.console.println("done")
