"""Step 10 - can audio the server generated reach the speaker?

This is the second of the two checks that decide Stage 1, and the more
important one. Step 5 asked whether Rocky can *hear*; this asks whether Rocky
can *speak* in a voice the backend produced.

If this fails, Rocky on CyberOS can never say anything except preset Makeblock
sounds and synthesized tones — no OpenAI voice, no Hume voice, no Rocky. That
alone ends Stage 1, regardless of how good the networking turns out to be.

The step downloads a 600 ms tone from /v1/probe/audio.wav (16 kHz, 16-bit,
mono) and then tries every playback route that might exist, in order of how
likely it is to work:

  1. write it to the filesystem and pass the path to cyberpi.audio.play()
  2. pass the path to cyberpi.audio.play_until()
  3. push the samples through machine.I2S, if step 6 found it

EXPECTED (if CyberOS is as documented)
  - the download succeeds
  - every playback route fails, and you hear nothing

WHAT WOULD CHANGE EVERYTHING
  - a 440 Hz beep. Write down exactly which route produced it.
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"
API_PORT = 8787
WAV_PATH = "/rocky_tone.wav"
POST_RESULTS = True


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


def http(method, path, body=None):
    """Returns (status, raw body bytes, elapsed_ms). Bytes, because this one downloads audio."""
    try:
        import usocket as socket
    except ImportError:
        import socket

    payload = body.encode() if isinstance(body, str) else (body or b"")
    address = socket.getaddrinfo(API_HOST, API_PORT)[0][-1]
    sock = socket.socket()
    try:
        sock.settimeout(15)
    except Exception:
        pass

    started = ticks_ms()
    try:
        sock.connect(address)
        head = "%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (
            method,
            path,
            API_HOST,
            API_PORT,
            len(payload),
        )
        request = head.encode() + payload
        if hasattr(sock, "write"):
            sock.write(request)
        else:
            sock.send(request)

        chunks = []
        while True:
            chunk = sock.read(512) if hasattr(sock, "read") else sock.recv(512)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
    finally:
        try:
            sock.close()
        except Exception:
            pass

    took = elapsed_since(started)
    header, _, response_body = raw.partition(b"\r\n\r\n")
    status_line = header.decode("utf-8", "ignore").split("\r\n")[0]
    parts = status_line.split(" ")
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return status, response_body, took


cyberpi.console.clear()
cyberpi.console.println("Rocky step 10: play WAV")
print("Rocky step 10: can server-generated audio reach the speaker?")
cyberpi.audio.set_vol(80)

cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
for _ in range(40):
    if cyberpi.wifi.is_connect():
        break
    time.sleep(0.5)

worked = None

if not cyberpi.wifi.is_connect():
    cyberpi.console.println("NO WIFI - see step 7")
    print("no Wi-Fi; step 7 has the troubleshooting notes")
else:
    # --- download ----------------------------------------------------------
    status, wav, took = http("GET", "/v1/probe/audio.wav")
    print("download: status " + str(status) + ", " + str(len(wav)) + " bytes in " + str(took) + " ms")
    if len(wav) >= 12:
        print("  header: " + str(wav[0:4]) + " " + str(wav[8:12]) + " (expect RIFF / WAVE)")
    cyberpi.console.println(str(len(wav)) + " bytes")

    if status != 200 or len(wav) < 44:
        cyberpi.console.println("download FAILED")
        print("nothing to play; fix step 8 first")
    else:
        # --- route 1: write to the filesystem, play by path -----------------
        print("")
        print("route 1: write to " + WAV_PATH + " and play by path")
        try:
            with open(WAV_PATH, "wb") as handle:
                handle.write(wav)
            print("  wrote " + str(len(wav)) + " bytes")
            cyberpi.console.println("playing by path...")
            cyberpi.audio.play(WAV_PATH)
            time.sleep(2)
            print("  play() did not raise - DID YOU HEAR A BEEP?")
            worked = "audio.play(path)"
        except Exception as exc:
            print("  failed: " + type(exc).__name__ + ": " + str(exc))

        # --- route 2: the blocking variant ----------------------------------
        print("")
        print("route 2: play_until() with the same path")
        try:
            cyberpi.audio.play_until(WAV_PATH)
            print("  play_until() did not raise - DID YOU HEAR A BEEP?")
            worked = worked or "audio.play_until(path)"
        except Exception as exc:
            print("  failed: " + type(exc).__name__ + ": " + str(exc))

        # --- route 3: straight at the codec ---------------------------------
        print("")
        print("route 3: machine.I2S")
        try:
            import machine

            if not hasattr(machine, "I2S"):
                print("  machine.I2S missing (expected - step 6 said so)")
            else:
                # Skip the 44-byte header; the rest is signed 16-bit LE mono.
                samples = wav[44:]
                i2s = machine.I2S(
                    0,
                    sck=machine.Pin(0),
                    ws=machine.Pin(1),
                    sd=machine.Pin(2),
                    mode=machine.I2S.TX,
                    bits=16,
                    format=machine.I2S.MONO,
                    rate=16000,
                    ibuf=4096,
                )
                i2s.write(samples)
                i2s.deinit()
                print("  *** I2S accepted the samples - DID YOU HEAR A BEEP?")
                print("  *** if yes, the pins above are guesses that happened to work; confirm them")
                worked = worked or "machine.I2S"
        except Exception as exc:
            print("  failed: " + type(exc).__name__ + ": " + str(exc))

        # --- tidy up ---------------------------------------------------------
        try:
            import os

            os.remove(WAV_PATH)
        except Exception:
            pass

    print("")
    if worked:
        print("*** SOMETHING WORKED: " + worked)
        print("*** Only count it if you actually heard a 440 Hz beep.")
        cyberpi.console.println("heard a beep?")
    else:
        print("no route played the audio - this is the gate answering NO")
        cyberpi.console.println("no playback (gate: no)")

    if POST_RESULTS:
        report = (
            '{"probe":"rocky-cyberpi-stage1","step":10,"passed":%d,"failed":%d,'
            '"checks":[{"section":"raw_output","name":"play_downloaded_wav","ok":%s,"detail":"%s"}]}'
            % (
                1 if worked else 0,
                0 if worked else 1,
                "true" if worked else "false",
                (worked or "no route played server-generated audio"),
            )
        )
        try:
            code, _, _ = http("POST", "/v1/probe/report", report)
            print("results posted: status " + str(code))
        except Exception as exc:
            print("could not post results: " + str(exc))

print("Record which route worked, if any, in apps/cyberpi/STEPS.md")
