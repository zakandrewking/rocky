"""Step 11 - does networking keep working while audio is active?

A conversation needs both at once: audio flowing out while more is coming in.
If CyberOS serializes them - by blocking the interpreter during recording, or
starving the network stack during playback - then even a system that passes
every other check cannot hold a realtime conversation.

Three measurements, all against the idle baseline from step 8:

  1. requests while the microphone is recording
  2. requests while a sound is playing
  3. requests immediately after playback ends, to see if there is a recovery
     penalty

Note the API's own shape here: play_until() blocks by design, so anything
running during playback has to use the non-blocking play(). If that turns out
to block too, that is worth knowing and this step will show it as a stall.

EXPECTED (if CyberOS cooperates)
  - all requests return 200
  - latency no worse than roughly 2-3x the idle baseline

WHAT WOULD END STAGE 1
  - requests failing outright while audio is active
  - latency ballooning by 10x or more, meaning the two subsystems fight
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"
API_PORT = 8787
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
    return status, response_body.decode("utf-8", "ignore"), took


def sample(label, count=4):
    """Run some requests and return (all_ok, average_ms)."""
    timings = []
    failures = 0
    for _ in range(count):
        try:
            status, _, took = http("GET", "/v1/health")
            if status != 200:
                failures += 1
            timings.append(took)
        except Exception as exc:
            failures += 1
            print("  " + label + ": request failed - " + type(exc).__name__ + ": " + str(exc))
    average = sum(timings) / len(timings) if timings else 0
    print(label + ": " + str(int(average)) + " ms avg, " + str(failures) + " failures, " + str(timings))
    return failures == 0, average


cyberpi.console.clear()
cyberpi.console.println("Rocky step 11: concurrency")
print("Rocky step 11: networking while audio is active")
cyberpi.audio.set_vol(70)

cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
for _ in range(40):
    if cyberpi.wifi.is_connect():
        break
    time.sleep(0.5)

if not cyberpi.wifi.is_connect():
    cyberpi.console.println("NO WIFI - see step 7")
    print("no Wi-Fi; step 7 has the troubleshooting notes")
else:
    # --- baseline ----------------------------------------------------------
    cyberpi.console.println("baseline...")
    idle_ok, idle_ms = sample("idle    ")

    # --- while recording ---------------------------------------------------
    cyberpi.console.println("while recording...")
    cyberpi.led.on(60, 0, 0)
    cyberpi.audio.record()
    rec_ok, rec_ms = sample("record  ")
    cyberpi.audio.stop_record()
    cyberpi.led.off()

    # --- while playing -----------------------------------------------------
    cyberpi.console.println("while playing...")
    # Non-blocking on purpose: play_until() would block the interpreter and
    # measure nothing.
    cyberpi.audio.play("hello")
    play_ok, play_ms = sample("playback")

    time.sleep(1)

    # --- after playback ----------------------------------------------------
    cyberpi.console.println("after playback...")
    after_ok, after_ms = sample("after   ")

    # --- verdict -----------------------------------------------------------
    print("")
    print("idle " + str(int(idle_ms)) + " ms | recording " + str(int(rec_ms)) + " ms | playback " + str(int(play_ms)) + " ms")

    def ratio(value):
        return (value / idle_ms) if idle_ms > 0 else 0

    stalled = ratio(rec_ms) > 3 or ratio(play_ms) > 3
    lost = not (rec_ok and play_ok and after_ok)

    if lost:
        print("verdict: requests FAILED while audio was active - fatal for a realtime loop")
        cyberpi.console.println("FAIL: requests dropped")
    elif stalled:
        print("verdict: requests survived but stalled badly (%.1fx / %.1fx) - realtime will feel broken" % (ratio(rec_ms), ratio(play_ms)))
        cyberpi.console.println("stalls badly")
    else:
        print("verdict: audio and networking coexist")
        cyberpi.console.println("PASS: coexist")

    if POST_RESULTS:
        report = (
            '{"probe":"rocky-cyberpi-stage1","step":11,"passed":%d,"failed":%d,'
            '"checks":[{"section":"concurrency","name":"network_during_audio","ok":%s,'
            '"detail":"idle %d ms, recording %d ms, playback %d ms, after %d ms"}]}'
            % (
                0 if (lost or stalled) else 1,
                1 if (lost or stalled) else 0,
                "false" if (lost or stalled) else "true",
                int(idle_ms),
                int(rec_ms),
                int(play_ms),
                int(after_ms),
            )
        )
        try:
            code, _, _ = http("POST", "/v1/probe/report", report)
            print("results posted: status " + str(code))
        except Exception as exc:
            print("could not post results: " + str(exc))

print("Record the four averages in apps/cyberpi/STEPS.md")
