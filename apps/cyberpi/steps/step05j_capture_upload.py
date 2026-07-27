"""Step 5j - send a real recording to the server and LISTEN to it.

This is the plan's first milestone, minus the return leg:

    CyberOS mic -> network -> server

Everything so far has proved that *bytes* come back from the microphone. Nobody
has confirmed those bytes are audible speech. A buffer of the right length,
with a plausible peak level, could still be noise, a stuck DC offset, or the
wrong channel. The only way to know is to listen to it.

So: record, POST the raw capture to device-api, and let it convert the
Makeblock format into a normal WAV you can play on your computer.

BEFORE RUNNING
  1. pnpm device-api
  2. set WIFI_* and API_HOST below (step 7 and 8 cover the details)

WHAT HAPPENS
  The service decodes the capture, reports its duration, sample rate, sign
  convention and peak level, and writes two files under local-data/cyberpi/:

      capture-<timestamp>.wav   playable
      capture-<timestamp>.raw   the original bytes, kept in case the
                                conversion is wrong and needs redoing

  Then: afplay local-data/cyberpi/capture-*.wav

WHAT TO LISTEN FOR
  Your own voice, intelligibly. 16 kHz 8-bit is telephone quality - grainy but
  clear. If it is buzzing or garbled, the sign convention or the sample rate is
  wrong, and the .raw file lets us fix it without another robot trip.
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"
API_PORT = 8787
API_TOKEN = ""  # only needed once ROCKY_DEVICE_TOKENS is set

RECORD_SECONDS = 3
CHUNK = 1024


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


def payload_of(result):
    """get_recording_data returns [header, data]; return the larger element."""
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


def post_capture(data):
    """Send raw bytes as application/octet-stream. Returns (status, body)."""
    try:
        import usocket as socket
    except ImportError:
        import socket

    address = socket.getaddrinfo(API_HOST, API_PORT)[0][-1]
    sock = socket.socket()
    try:
        sock.settimeout(30)
    except Exception:
        pass

    started = ticks_ms()
    try:
        sock.connect(address)
        lines = [
            "POST /v1/probe/capture HTTP/1.1",
            "Host: %s:%d" % (API_HOST, API_PORT),
            "Connection: close",
            "Content-Type: application/octet-stream",
            "Content-Length: %d" % len(data),
        ]
        if API_TOKEN:
            lines.append("Authorization: Bearer " + API_TOKEN)
        head = ("\r\n".join(lines) + "\r\n\r\n").encode()

        if hasattr(sock, "write"):
            sock.write(head)
        else:
            sock.send(head)

        # Send in chunks: one 50 KB write can overrun the socket buffer.
        sent = 0
        total = len(data)
        while sent < total:
            piece = data[sent : sent + CHUNK]
            if hasattr(sock, "write"):
                sock.write(piece)
            else:
                sock.send(piece)
            sent += len(piece)
            if sent % (CHUNK * 16) == 0:
                cyberpi.console.println("sent " + str(sent // 1024) + "K")

        chunks = []
        while True:
            piece = sock.read(256) if hasattr(sock, "read") else sock.recv(256)
            if not piece:
                break
            chunks.append(piece)
        raw = b"".join(chunks)
    finally:
        try:
            sock.close()
        except Exception:
            pass

    took = elapsed_since(started)
    header, _, body = raw.partition(b"\r\n\r\n")
    status_line = header.decode("utf-8", "ignore").split("\r\n")[0]
    parts = status_line.split(" ")
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return status, body.decode("utf-8", "ignore"), took


cyberpi.console.clear()
cyberpi.console.println("5j: mic -> server")
print("")
print("=== ROCKY STEP 5J: CAPTURE UPLOAD ===")

# --- Wi-Fi -----------------------------------------------------------------
cyberpi.console.println("wifi...")
cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
for _ in range(40):
    if cyberpi.wifi.is_connect():
        break
    time.sleep(0.5)

if not cyberpi.wifi.is_connect():
    cyberpi.console.println("NO WIFI - see step 7")
    print("no Wi-Fi; step 7 has the troubleshooting notes")
else:
    # --- record ------------------------------------------------------------
    mic = cyberpi.mic_o
    print("recording " + str(RECORD_SECONDS) + "s...")
    cyberpi.console.println("SAY SOMETHING")
    cyberpi.console.println("for " + str(RECORD_SECONDS) + " seconds")
    cyberpi.led.on(60, 0, 0)
    try:
        mic.record_with_time(RECORD_SECONDS)
        time.sleep(RECORD_SECONDS + 1)
    except Exception as exc:
        print("record failed: " + type(exc).__name__ + ": " + str(exc))
    cyberpi.led.off()

    # --- read the buffer ---------------------------------------------------
    data = None
    try:
        data = payload_of(mic.get_recording_data(0))
    except Exception as exc:
        print("read failed: " + type(exc).__name__ + ": " + str(exc))

    if data is None or len(data) == 0:
        print("nothing captured")
        cyberpi.console.println("NO AUDIO")
    else:
        print("captured " + str(len(data)) + " bytes")
        print("  = " + str(round(len(data) / 16000.0, 2)) + " s at 16 kHz 8-bit")
        cyberpi.console.println(str(len(data) // 1024) + "K captured")

        # --- upload --------------------------------------------------------
        cyberpi.led.on(0, 0, 60)
        try:
            status, body, took = post_capture(data)
            cyberpi.led.off()
            print("")
            print("upload: status " + str(status) + " in " + str(took) + " ms")
            print("server said: " + body[:300])

            if status == 200:
                kbps = (len(data) * 8.0) / max(took, 1)
                print("effective uplink: " + str(int(kbps)) + " kbps")
                # The mic produces 128 kbps; anything at or above that means
                # audio can be shipped as fast as it is captured.
                print("mic produces 128 kbps: " + ("keeps up" if kbps >= 128 else "SLOWER than realtime"))
                cyberpi.console.println("UPLOADED!")
                cyberpi.console.println("now go listen")
                print("")
                print("Now play it:  afplay local-data/cyberpi/capture-*.wav")
            else:
                cyberpi.console.println("upload failed")
        except Exception as exc:
            cyberpi.led.off()
            print("upload failed: " + type(exc).__name__ + ": " + str(exc))
            cyberpi.console.println("upload error")

print("")
print("=== END STEP 5J ===")
