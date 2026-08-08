"""Step 5b - the gate questions, readable without a console.

Steps 5 and 6 print about a hundred lines each to the serial console. If
mBlock's serial monitor is showing raw hex, or is missing entirely, that output
is unreadable and those steps are useless.

This program answers the same questions and renders the *findings* on the
CyberPi's own screen, one page at a time. It does not dump member lists - those
do not fit on 128x128 - it reports what they mean.

It also still print()s the full detail, so if you later get a working console
you can re-run this and get everything.

Run this INSTEAD of steps 5 and 6 if your console is unreadable. It covers both.

CONTROLS
  Press button A to advance a page. If the button does not respond, pages
  advance on their own after PAGE_SECONDS. The deck loops, so you can go round
  again to photograph anything you missed.

WHAT TO LOOK FOR
  Page 1 gives the answer. Pages 2-7 are the evidence behind it.
  "CAPTURE: no" and "PLAYBACK: no" together mean CyberOS cannot carry a
  realtime conversation, which is the expected result and a real finding.
"""

import gc
import os
import time

import cyberpi

PAGE_SECONDS = 12
LINE_WIDTH = 20

RAW_HINTS = (
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

MODULES = ("socket", "usocket", "ssl", "ussl", "urequests", "network", "machine", "esp32")


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


def fit(text):
    """The console is about 20 characters wide; longer lines wrap badly."""
    text = str(text)
    return text if len(text) <= LINE_WIDTH else text[: LINE_WIDTH - 1] + ">"


# ---------------------------------------------------------------------------
# Gather findings. Everything is defensive: a probe must never crash.
# ---------------------------------------------------------------------------

print("Rocky step 5b: gate check (screen edition)")
cyberpi.console.clear()
cyberpi.console.println("checking...")

findings = {}

# --- can we get raw microphone samples? ------------------------------------
suspects = []
try:
    for holder_name, holder in (("cyberpi", cyberpi), ("cyberpi.audio", cyberpi.audio)):
        for member in dir(holder):
            if member.startswith("_"):
                continue
            lowered = member.lower()
            for hint in RAW_HINTS:
                if hint in lowered:
                    suspects.append(holder_name + "." + member)
                    break
except Exception as exc:
    print("member scan failed: " + str(exc))
findings["suspects"] = suspects
print("suspects: " + (", ".join(suspects) or "none"))

try:
    audio_members = sorted([m for m in dir(cyberpi.audio) if not m.startswith("_")])
except Exception:
    audio_members = []
findings["audio_member_count"] = len(audio_members)
print("cyberpi.audio members: " + ", ".join(audio_members))

# --- does record() or play() take a path? ----------------------------------
try:
    cyberpi.audio.record("/rocky_probe.wav")
    cyberpi.audio.stop_record()
    findings["record_path"] = True
    print("record(path): ACCEPTED")
except Exception as exc:
    findings["record_path"] = False
    print("record(path): rejected - " + type(exc).__name__ + ": " + str(exc))

try:
    cyberpi.audio.play("/rocky_probe_missing.wav")
    findings["play_path"] = True
    print("play(path): accepted without raising")
except Exception as exc:
    findings["play_path"] = False
    print("play(path): rejected - " + type(exc).__name__ + ": " + str(exc))

# --- record for real, then look for where it went --------------------------
cyberpi.console.println("speak briefly...")
try:
    cyberpi.audio.record()
    time.sleep(2)
    cyberpi.audio.stop_record()
    time.sleep(0.5)
except Exception as exc:
    print("recording failed: " + str(exc))

entries = []


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
        entries.append((full, size, is_dir))
        if is_dir:
            walk(full, depth + 1)


walk("/", 0)
audio_files = [e[0] for e in entries if not e[2] and any(t in e[0].lower() for t in ("wav", "pcm", "record", "audio", "mp3"))]
findings["fs_entries"] = len(entries)
findings["audio_files"] = audio_files
print("filesystem entries: " + str(len(entries)))
for entry in entries:
    print("  " + str(entry))
print("audio-looking files: " + (", ".join(audio_files) or "none"))

# --- how much buffer could we ever hold? -----------------------------------
try:
    gc.collect()
    free = gc.mem_free() if hasattr(gc, "mem_free") else -1
except Exception:
    free = -1
findings["free_heap"] = free
# 24 kHz mono 16-bit is 48000 bytes per second.
findings["pcm_seconds"] = round(free / 48000.0, 2) if free > 0 else 0
print("free heap: " + str(free) + " bytes = " + str(findings["pcm_seconds"]) + " s of 24k PCM")

# --- what does the runtime underneath give us? -----------------------------
available = []
for name in MODULES:
    try:
        __import__(name)
        available.append(name)
    except Exception:
        pass
findings["modules"] = available
print("modules: " + (", ".join(available) or "none"))

has_i2s = False
has_dac = False
try:
    import machine

    has_i2s = hasattr(machine, "I2S")
    has_dac = hasattr(machine, "DAC")
except Exception:
    pass
findings["i2s"] = has_i2s
findings["dac"] = has_dac
print("machine.I2S: " + str(has_i2s) + "  machine.DAC: " + str(has_dac))

# --- the verdict -----------------------------------------------------------
capture = bool(suspects) or findings["record_path"] or bool(audio_files)
playback = has_i2s or has_dac or findings["play_path"]
sockets = ("socket" in available) or ("usocket" in available)
findings["capture"] = capture
findings["playback"] = playback
findings["sockets"] = sockets

print("")
print("GATE: capture=" + str(capture) + " playback=" + str(playback) + " sockets=" + str(sockets))

# ---------------------------------------------------------------------------
# Render it, one page at a time.
# ---------------------------------------------------------------------------

pages = []

if capture and playback and sockets:
    conclusion = "CyberOS can do it"
elif not sockets:
    conclusion = "no net: Stage 2"
else:
    conclusion = "-> Stage 2"

pages.append(
    [
        "== GATE ANSWER ==",
        "CAPTURE: " + ("YES" if capture else "no"),
        "PLAYBACK: " + ("YES" if playback else "no"),
        "SOCKETS: " + ("yes" if sockets else "NO"),
        "",
        conclusion,
    ]
)

pages.append(
    ["== RAW SUSPECTS ==", "count: " + str(len(suspects))]
    + ([fit(s) for s in suspects[:5]] if suspects else ["none found", "(expected)"])
)

pages.append(
    [
        "== PATH ARGS ==",
        "record(path):",
        "  " + ("ACCEPTED!" if findings["record_path"] else "rejected"),
        "play(path):",
        "  " + ("accepted!" if findings["play_path"] else "rejected"),
    ]
)

pages.append(
    ["== FILESYSTEM ==", "entries: " + str(len(entries)), "audio files:"]
    + ([fit(f) for f in audio_files[:4]] if audio_files else ["  none", "  (expected)"])
)

pages.append(
    [
        "== MEMORY ==",
        "free heap:",
        "  " + str(free) + " B",
        "24k PCM buffer:",
        "  " + str(findings["pcm_seconds"]) + " sec",
    ]
)

pages.append(["== MODULES ==", "found: " + str(len(available))] + [fit("  " + m) for m in available[:6]])

pages.append(
    [
        "== RAW OUTPUT ==",
        "machine.I2S:",
        "  " + ("PRESENT!" if has_i2s else "missing"),
        "machine.DAC:",
        "  " + ("PRESENT!" if has_dac else "missing"),
    ]
)

# Does the button work? If not, fall back to timed pages rather than trapping
# the reader on page one forever.
button_works = True
try:
    cyberpi.controller.is_press("a")
except Exception:
    button_works = False
    print("button API unavailable; pages will auto-advance")


def wait_for_next():
    start = ticks_ms()
    while elapsed_since(start) < PAGE_SECONDS * 1000:
        if button_works:
            try:
                if cyberpi.controller.is_press("a"):
                    while cyberpi.controller.is_press("a"):
                        time.sleep(0.05)
                    return
            except Exception:
                pass
        time.sleep(0.05)


while True:
    for number, lines in enumerate(pages):
        cyberpi.console.clear()
        for line in lines:
            cyberpi.console.println(fit(line))
        cyberpi.console.println("")
        cyberpi.console.println("A = next (" + str(number + 1) + "/" + str(len(pages)) + ")")
        wait_for_next()
