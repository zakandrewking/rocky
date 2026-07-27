"""Step 5h - is there a raw playback path?

This is now the only question standing between Rocky and a talking robot on
stock firmware. Capture is proven (16 kHz 8-bit mono, step 5f). If arbitrary
audio can reach the speaker, Stage 1 works and no custom firmware is needed.

Step 5g's unfiltered dir(cyberpi) turned up 175 members. The output-side ones
worth inspecting:

    speaker          SPEAKER          audio
    mp3_music_o      mp3_music_t      speech

Note the naming convention that dump revealed: a trailing `_o` marks the
low-level object - mic_o, wifi_o, gyro_o, nvs_o, ota_o, espnow_o, joystick_o.
There is no `speaker_o` or `audio_o` in the list, which is mildly discouraging,
but `mp3_music_o` exists and decoding MP3 means a PCM path to the speaker
somewhere underneath.

Step 5g's own output was truncated by the console right at this point, which is
why this is a separate, deliberately short program.

SAFETY
  dir() and getattr only. Nothing is called, nothing is played. Step 5 showed
  that poking audio internals can wedge the firmware.

WHAT TO LOOK FOR
  Anything taking or returning bytes: write, play_data, play_buffer, set_data,
  feed, i2s, pcm, raw, stream. An `init`/`deinit` pair would suggest a
  configurable peripheral, the way mic_o has one.
"""

import cyberpi

# Edit this list and re-run to inspect others from step 5g's dump.
TARGETS = ("speaker", "SPEAKER", "mp3_music_o", "mp3_music_t", "speech")

# Names that would mean arbitrary audio can be pushed to the speaker.
INTERESTING = (
    "write",
    "data",
    "buffer",
    "pcm",
    "raw",
    "stream",
    "feed",
    "i2s",
    "dac",
    "init",
    "deinit",
    "sample",
    "rate",
    "wav",
)

cyberpi.console.clear()
cyberpi.console.println("5h: output path?")
print("")
print("=== ROCKY STEP 5H: OUTPUT ===")

found = []

for name in TARGETS:
    print("")
    try:
        obj = getattr(cyberpi, name)
    except Exception as exc:
        print("--- cyberpi." + name + ": unavailable (" + type(exc).__name__ + ") ---")
        continue

    print("--- cyberpi." + name + "  (type " + type(obj).__name__ + ") ---")
    try:
        members = sorted([m for m in dir(obj) if not m.startswith("_")])
    except Exception as exc:
        print("  dir() failed: " + type(exc).__name__ + ": " + str(exc))
        continue

    print("  count: " + str(len(members)))
    for member in members:
        try:
            kind = type(getattr(obj, member)).__name__
        except Exception as exc:
            kind = "ERR " + type(exc).__name__
        # Flag the ones that would matter, so they survive a skim.
        lowered = member.lower()
        mark = ""
        for hint in INTERESTING:
            if hint in lowered:
                mark = "   <<<"
                found.append(name + "." + member)
                break
        print("  " + member + " : " + kind + mark)

print("")
print("--- candidates worth calling next ---")
if found:
    for item in found:
        print("  " + item)
else:
    print("  none - no obvious raw-audio-out member on these objects")

print("")
print("=== END STEP 5H ===")
cyberpi.console.println("hits: " + str(len(found)))
