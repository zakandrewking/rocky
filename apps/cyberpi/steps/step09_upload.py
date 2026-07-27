"""Step 9 - how much audio could the robot actually push per second?

Sends growing payloads to /v1/probe/echo and reports kbps for each.

The number to beat: **384 kbps**. That is 24 kHz, 16-bit, mono PCM - the format
an OpenAI Realtime session expects. If the robot cannot sustain that uplink,
raw streaming is off the table even if step 5 had found a way to capture
samples, and the options narrow to compressed audio or a turn-based loop.

The payload grows because small requests are dominated by connection setup;
only the larger ones show the real ceiling.

(The http helper is copied into each network step on purpose. mBlock uploads a
single file, so steps cannot import from each other.)

EXPECTED
  - throughput climbing as the payload grows, flattening at the ceiling
  - a verdict line comparing that ceiling to 384 kbps

IF IT FAILS
  - errors on the larger payloads: note the size where it breaks; that is the
    per-request limit, and it caps how much audio one request can carry
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"
API_PORT = 8787
POST_RESULTS = True

# 24 kHz * 16 bit * 1 channel
PCM_KBPS = 384
PAYLOAD_SIZES = (1024, 4096, 16384, 65536)


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


cyberpi.console.clear()
cyberpi.console.println("Rocky step 9: uplink")
print("Rocky step 9: uplink throughput")
print("target: " + str(PCM_KBPS) + " kbps for 24 kHz 16-bit mono PCM")

cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
for _ in range(40):
    if cyberpi.wifi.is_connect():
        break
    time.sleep(0.5)

if not cyberpi.wifi.is_connect():
    cyberpi.console.println("NO WIFI - see step 7")
    print("no Wi-Fi; step 7 has the troubleshooting notes")
else:
    best = 0
    results = []
    for size in PAYLOAD_SIZES:
        # Valid JSON, so the service parses it the way a real request would.
        body = '{"pad":"' + ("x" * size) + '"}'
        try:
            status, _, took = http("POST", "/v1/probe/echo", body)
        except Exception as exc:
            print(str(size) + " bytes: FAILED - " + type(exc).__name__ + ": " + str(exc))
            print("  this is the per-request ceiling")
            break

        kbps = (len(body) * 8.0) / max(took, 1)
        results.append((size, took, int(kbps)))
        best = max(best, kbps)
        print(str(size) + " bytes: status " + str(status) + ", " + str(took) + " ms, " + str(int(kbps)) + " kbps")
        cyberpi.console.println(str(size // 1024) + "K: " + str(int(kbps)) + " kbps")
        time.sleep(0.3)

    print("")
    print("best: " + str(int(best)) + " kbps")
    if best >= PCM_KBPS:
        print("verdict: enough for raw 24 kHz PCM uplink")
    elif best >= PCM_KBPS / 4:
        print("verdict: too slow for raw PCM, but fine for compressed or turn-based audio")
    else:
        print("verdict: SLOW - only short turn-based clips are realistic")
    cyberpi.console.println("best " + str(int(best)) + " kbps")

    if POST_RESULTS and results:
        report = (
            '{"probe":"rocky-cyberpi-stage1","step":9,"passed":1,"failed":0,'
            '"checks":[{"section":"http","name":"uplink","ok":%s,"detail":"best %d kbps, samples %s"}]}'
            % ("true" if best >= PCM_KBPS else "false", int(best), str(results))
        )
        code, _, _ = http("POST", "/v1/probe/report", report)
        print("results posted: status " + str(code))

print("Record the best kbps in apps/cyberpi/STEPS.md")
